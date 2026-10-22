package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/notify"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/service"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/source/github"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/source/imap"
)

const usageDoctor = "minis-hostd doctor [--push-test] [--json]"

const (
	doctorCheckTimeout = 15 * time.Second
	maxClockSkew       = 2 * time.Minute
	githubAPIVersion   = "2022-11-28"
	githubErrorLimit   = 4 << 10
	appPasswordsURL    = "https://myaccount.google.com/apppasswords"
	newGitHubTokenURL  = "https://github.com/settings/tokens/new?scopes=notifications"
	pushTestTitle      = "minis-hostd doctor"
)

// doctorDeps holds everything doctor reaches over the network, so tests point it at local servers.
type doctorDeps struct {
	Client        *http.Client
	GitHubBaseURL string
	DialIMAP      imap.Dialer
	CheckTimeout  time.Duration
	NewNotifier   func(Env, config.Config, *http.Client) (notify.Notifier, error)
}

func productionDoctorDeps() doctorDeps {
	return doctorDeps{
		Client:        newHTTPClient(),
		GitHubBaseURL: github.DefaultBaseURL,
		DialIMAP:      imap.DialGmail,
		CheckTimeout:  doctorCheckTimeout,
		NewNotifier:   newNotifier,
	}
}

type doctorCheck struct {
	Name   string `json:"name"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail"`
}

type doctorOutput struct {
	SchemaVersion int           `json:"schemaVersion"`
	Checks        []doctorCheck `json:"checks"`
}

type doctorOptions struct {
	PushTest bool
	JSON     bool
}

func parseDoctorArgs(args []string) (doctorOptions, error) {
	var options doctorOptions
	for _, arg := range args {
		switch {
		case arg == "--json" && !options.JSON:
			options.JSON = true
		case arg == "--push-test" && !options.PushTest:
			options.PushTest = true
		default:
			return doctorOptions{}, badRequest(usageDoctor)
		}
	}
	return options, nil
}

// runDoctor exits 2 with the full checklist when any check fails, not with the error object: the
// caller needs to know which checks passed, and the error object stays for usage errors.
func runDoctor(env Env, args []string, deps doctorDeps) int {
	options, err := parseDoctorArgs(args)
	if err != nil {
		return failWith(env, err)
	}
	checks := doctorChecks(env, deps, options.PushTest)
	status := ExitOK
	if slices.ContainsFunc(checks, func(c doctorCheck) bool { return !c.OK }) {
		status = ExitError
	}
	if options.JSON {
		if emit(env, doctorOutput{SchemaVersion: SchemaVersion, Checks: checks}) != ExitOK {
			return ExitError
		}
		return status
	}
	printChecklist(env.Stdout, checks)
	return status
}

func printChecklist(w io.Writer, checks []doctorCheck) {
	failed := 0
	for _, c := range checks {
		mark := "✓"
		if !c.OK {
			mark = "✗"
			failed++
		}
		fmt.Fprintf(w, "%s %s — %s\n", mark, c.Name, c.Detail)
	}
	if failed == 0 {
		fmt.Fprintf(w, "All %d checks passed.\n", len(checks))
		return
	}
	fmt.Fprintf(w, "%d of %d checks failed.\n", failed, len(checks))
}

func doctorChecks(env Env, deps doctorDeps, pushTest bool) []doctorCheck {
	path := service.DefaultPaths(env.Setup.Home).Config
	cfg, configCheck := checkConfig(path)
	if !configCheck.OK {
		return []doctorCheck{configCheck}
	}
	checks := []doctorCheck{configCheck, checkTimezone(cfg.Timezone), withTimeout(deps, func(ctx context.Context) doctorCheck {
		return checkClock(ctx, deps, env.Now())
	})}
	for _, account := range cfg.Mail {
		checks = append(checks, withTimeout(deps, func(ctx context.Context) doctorCheck {
			return checkMail(ctx, deps, account)
		}))
	}
	if cfg.GitHub != nil {
		checks = append(checks, withTimeout(deps, func(ctx context.Context) doctorCheck {
			return checkGitHub(ctx, deps, cfg.GitHub.Token)
		}))
	}
	if cfg.APNs != nil {
		checks = append(checks, checkAPNsSetup(env, cfg))
	}
	if pushTest {
		checks = append(checks, withTimeout(deps, func(ctx context.Context) doctorCheck {
			return checkPush(ctx, env, deps, cfg)
		}))
	}
	return checks
}

func withTimeout(deps doctorDeps, check func(ctx context.Context) doctorCheck) doctorCheck {
	ctx, cancel := context.WithTimeout(context.Background(), deps.CheckTimeout)
	defer cancel()
	return check(ctx)
}

func checkConfig(path string) (config.Config, doctorCheck) {
	if _, err := os.Stat(path); errors.Is(err, fs.ErrNotExist) {
		return config.Config{}, doctorCheck{Name: "config", Detail: fmt.Sprintf(
			"%s does not exist; run `minis-hostd new-config --host-name <name in Minis>` and fill it in", path)}
	}
	cfg, err := config.Load(path)
	if err != nil {
		return config.Config{}, doctorCheck{Name: "config", Detail: err.Error()}
	}
	return cfg, doctorCheck{Name: "config", OK: true, Detail: path + " loads (mode 600)"}
}

func checkTimezone(location *time.Location) doctorCheck {
	if location != time.Local {
		return doctorCheck{Name: "timezone", OK: true, Detail: location.String() + " (from config.toml)"}
	}
	link, _ := os.Readlink("/etc/localtime") // a missing or regular file just means no name to read from it
	name, ok := systemZoneName(os.Getenv("TZ"), link)
	if !ok {
		return doctorCheck{Name: "timezone", Detail: "the system time zone has no IANA name; " +
			"set timezone (for example \"Europe/Berlin\") in config.toml so quiet hours use the right zone"}
	}
	return doctorCheck{Name: "timezone", OK: true, Detail: name + " (system time zone; set timezone in config.toml to pin it)"}
}

// systemZoneName follows Go's own lookup for time.Local: TZ wins when set, else /etc/localtime.
func systemZoneName(tz, localtimeLink string) (string, bool) {
	if tz != "" {
		tz = strings.TrimPrefix(tz, ":")
		if _, err := time.LoadLocation(tz); err != nil {
			return "", false
		}
		return tz, true
	}
	if _, name, found := strings.Cut(localtimeLink, "zoneinfo/"); found && name != "" {
		return name, true
	}
	return "", false
}

// checkClock compares against an HTTP Date header because hostd may run where NTP is blocked, and
// a wrong clock breaks quiet hours, the 48-hour freshness rule and TLS.
func checkClock(ctx context.Context, deps doctorDeps, now time.Time) doctorCheck {
	target, err := url.Parse(deps.GitHubBaseURL)
	if err != nil {
		return doctorCheck{Name: "clock", Detail: fmt.Sprintf("cannot parse %q: %v", deps.GitHubBaseURL, err)}
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodHead, target.String(), nil)
	if err != nil {
		return doctorCheck{Name: "clock", Detail: err.Error()}
	}
	response, err := deps.Client.Do(request)
	if err != nil {
		return doctorCheck{Name: "clock", Detail: fmt.Sprintf("cannot reach %s to compare the clock: %v", target.Host, err)}
	}
	response.Body.Close()
	date, err := http.ParseTime(response.Header.Get("Date"))
	if err != nil {
		return doctorCheck{Name: "clock", Detail: fmt.Sprintf("%s sent no usable Date header (%q)", target.Host, response.Header.Get("Date"))}
	}
	skew := now.Sub(date).Round(time.Second)
	direction, magnitude := "ahead of", skew
	if skew < 0 {
		direction, magnitude = "behind", -skew
	}
	if magnitude > maxClockSkew {
		return doctorCheck{Name: "clock", Detail: fmt.Sprintf(
			"the clock is %s %s %s; turn on network time (timedatectl set-ntp true on Linux, "+
				"System Settings → General → Date & Time on macOS)", magnitude, direction, target.Host)}
	}
	detail := fmt.Sprintf("within 2 minutes of %s (0s off)", target.Host)
	if magnitude > 0 {
		detail = fmt.Sprintf("within 2 minutes of %s (%s %s)", target.Host, magnitude, strings.TrimSuffix(direction, " of"))
	}
	return doctorCheck{Name: "clock", OK: true, Detail: detail}
}

func checkMail(ctx context.Context, deps doctorDeps, account config.MailAccount) doctorCheck {
	name := "mail:" + account.Name
	src, err := imap.New(account, deps.DialIMAP, imap.ProductionTiming(), imap.SleepContext)
	if err != nil {
		return doctorCheck{Name: name, Detail: err.Error()}
	}
	result, err := src.Probe(ctx)
	switch {
	case errors.Is(err, imap.ErrLoginRejected):
		return doctorCheck{Name: name, Detail: fmt.Sprintf(
			"Gmail rejected the app password for %s; create a new one at %s", account.Address, appPasswordsURL)}
	case errors.Is(err, imap.ErrIdleUnsupported):
		return doctorCheck{Name: name, Detail: fmt.Sprintf(
			"logged in as %s, but the server does not support IDLE, which hostd needs to see new mail", account.Address)}
	case err != nil:
		return doctorCheck{Name: name, Detail: fmt.Sprintf("cannot check %s with Gmail: %v", account.Address, err)}
	}
	return doctorCheck{Name: name, OK: true, Detail: fmt.Sprintf(
		"logged in as %s; IDLE supported; INBOX has %d messages", account.Address, result.Messages)}
}

func checkGitHub(ctx context.Context, deps doctorDeps, token string) doctorCheck {
	endpoint := strings.TrimSuffix(deps.GitHubBaseURL, "/") + "/notifications?per_page=1"
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return doctorCheck{Name: "github", Detail: err.Error()}
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", githubAPIVersion)
	response, err := deps.Client.Do(request)
	if err != nil {
		return doctorCheck{Name: "github", Detail: fmt.Sprintf("cannot reach GitHub: %v", err)}
	}
	defer response.Body.Close()
	switch {
	case response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden:
		return doctorCheck{Name: "github", Detail: fmt.Sprintf(
			"GitHub rejected the token (%d: %s); create a classic token with the notifications scope at %s",
			response.StatusCode, githubMessage(response.Body), newGitHubTokenURL)}
	case response.StatusCode != http.StatusOK:
		return doctorCheck{Name: "github", Detail: fmt.Sprintf(
			"GitHub answered %d: %s", response.StatusCode, githubMessage(response.Body))}
	}
	return scopeCheck(response.Header.Get("X-OAuth-Scopes"))
}

func scopeCheck(header string) doctorCheck {
	var scopes []string
	for scope := range strings.SplitSeq(header, ",") {
		if trimmed := strings.TrimSpace(scope); trimmed != "" {
			scopes = append(scopes, trimmed)
		}
	}
	listed := strings.Join(scopes, ", ")
	switch {
	case slices.Contains(scopes, "notifications") && !slices.Contains(scopes, "repo"):
		return doctorCheck{Name: "github", OK: true, Detail: "token accepted; scopes: " + listed}
	case slices.Contains(scopes, "repo"):
		return doctorCheck{Name: "github", OK: true, Detail: "token accepted; scopes: " + listed +
			" (repo grants more than hostd needs; a token with only notifications is enough)"}
	case len(scopes) == 0:
		return doctorCheck{Name: "github", Detail: "the token has no classic scopes; " +
			"the notifications API needs the notifications scope; create a classic token at " + newGitHubTokenURL}
	default:
		return doctorCheck{Name: "github", Detail: fmt.Sprintf(
			"the token's scopes are %s; the notifications API needs the notifications scope; create a classic token at %s",
			listed, newGitHubTokenURL)}
	}
}

func githubMessage(body io.Reader) string {
	raw, err := io.ReadAll(io.LimitReader(body, githubErrorLimit))
	if err != nil {
		return fmt.Sprintf("(reading the response failed: %v)", err)
	}
	var parsed struct {
		Message string `json:"message"`
	}
	if json.Unmarshal(raw, &parsed) == nil && parsed.Message != "" {
		return parsed.Message
	}
	return strings.TrimSpace(string(raw))
}

func checkPush(ctx context.Context, env Env, deps doctorDeps, cfg config.Config) doctorCheck {
	notifier, err := deps.NewNotifier(env, cfg, deps.Client)
	if err != nil {
		return doctorCheck{Name: "push", Detail: err.Error()}
	}
	channel, matches, fix, success := "Bark", "the Bark key matches", "check bark.device_key and bark.server",
		"Bark accepted the test push; check the phone. If it shows \"Decryption Failed\", the key saved in Bark differs from bark.encryption_key in config.toml"
	if cfg.APNs != nil {
		channel, matches, fix, success = "APNs", "Pico decrypted it", "see the reason above",
			"APNs accepted the test push; check the phone. If it says Pico could not decrypt it, tap Send to This iPhone again"
	}
	notice := notify.Notice{
		Title: pushTestTitle,
		Body:  fmt.Sprintf("Test push from %s: if you can read this, %s.", cfg.HostName, matches),
	}
	err = notifier.Send(ctx, notice)
	switch {
	case errors.Is(err, notify.ErrMaybeDelivered):
		return doctorCheck{Name: "push", Detail: fmt.Sprintf(
			"the test push may have been sent but %s's reply was lost (%v); check the phone", channel, err)}
	case err != nil:
		return doctorCheck{Name: "push", Detail: fmt.Sprintf("%s did not accept the test push (%v); %s", channel, err, fix)}
	}
	return doctorCheck{Name: "push", OK: true, Detail: success}
}

// checkAPNsSetup runs without --push-test: it reads the key and the registration but sends nothing.
func checkAPNsSetup(env Env, cfg config.Config) doctorCheck {
	if _, err := notify.LoadAPNsKey(cfg.APNs.KeyFile); err != nil {
		return doctorCheck{Name: "apns", Detail: err.Error()}
	}
	device, err := notify.ActiveDevice(registrationPath(env))
	if err != nil {
		return doctorCheck{Name: "apns", Detail: err.Error()}
	}
	return doctorCheck{Name: "apns", OK: true, Detail: fmt.Sprintf("key %s loads; %s registered %s (%s)",
		cfg.APNs.KeyID, device.Topic, device.RegisteredAt.Format(time.RFC3339), device.Environment)}
}
