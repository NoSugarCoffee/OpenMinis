// Package config loads and validates ~/.minis/hostd/config.toml.
package config

import (
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/BurntSushi/toml"
)

// BarkKeyAlphabet leaves out 0, o, 1, l and i: the key is typed into the Bark app by hand, and in
// spike S3 a hand-typed key picked up look-alike characters that Bark accepted and then failed on.
const BarkKeyAlphabet = "abcdefghjkmnpqrstuvwxyz23456789"

const BarkKeyLength = 32

const DefaultBarkServer = "https://api.day.app"

// AnySender as an allow pattern admits every sender that passes the other mail rules.
const AnySender = "*"

// DefaultGitHubReasons are the notification reasons that push unless the config names others.
var DefaultGitHubReasons = []string{"mention", "team_mention", "review_requested", "assign", "ci_activity"}

type Config struct {
	HostName   string
	Timezone   *time.Location
	QuietHours *Window
	Mail       []MailAccount
	GitHub     *GitHubSource
	Bark       Bark
}

type MailAccount struct {
	Name             string
	Address          string
	AppPassword      string
	GmailPrimaryOnly bool
	Allow            []SenderRule
}

// SenderRule matches an exact address ("alice@example.com"), a whole domain ("@example.com"), or any
// sender ("*"). Automated mail is dropped before the allowlist, so "*" still never pushes newsletters.
type SenderRule struct {
	Pattern      string
	RequireDMARC bool
}

type GitHubSource struct {
	Token   string
	Reasons []string
	Repos   []string
}

type Bark struct {
	Server        string
	DeviceKey     string
	EncryptionKey string
}

// Window is a daily span in minutes after local midnight; Start > End wraps past midnight.
type Window struct {
	Start int
	End   int
}

// Error names the setting that is wrong so the user can find it in the file.
type Error struct {
	Path    string
	Field   string
	Message string
}

func (e *Error) Error() string {
	if e.Field == "" {
		return fmt.Sprintf("%s: %s", e.Path, e.Message)
	}
	return fmt.Sprintf("%s: %s: %s", e.Path, e.Field, e.Message)
}

type fileConfig struct {
	HostName   string      `toml:"host_name"`
	Timezone   string      `toml:"timezone"`
	QuietHours *fileWindow `toml:"quiet_hours"`
	Mail       []fileMail  `toml:"mail"`
	GitHub     *fileGitHub `toml:"github"`
	Bark       *fileBark   `toml:"bark"`
}

type fileWindow struct {
	Start string `toml:"start"`
	End   string `toml:"end"`
}

type fileMail struct {
	Name             string       `toml:"name"`
	Address          string       `toml:"address"`
	AppPassword      string       `toml:"app_password"`
	GmailPrimaryOnly bool         `toml:"gmail_primary_only"`
	Allow            []fileSender `toml:"allow"`
}

type fileSender struct {
	Pattern      string `toml:"pattern"`
	RequireDMARC *bool  `toml:"require_dmarc"`
}

type fileGitHub struct {
	Token   string   `toml:"token"`
	Reasons []string `toml:"reasons"`
	Repos   []string `toml:"repos"`
}

type fileBark struct {
	Server        string `toml:"server"`
	DeviceKey     string `toml:"device_key"`
	EncryptionKey string `toml:"encryption_key"`
}

var (
	hostNamePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,32}$`)
	clockPattern    = regexp.MustCompile(`^([01][0-9]|2[0-3]):([0-5][0-9])$`)
	repoPattern     = regexp.MustCompile(`^[A-Za-z0-9_.-]+/([A-Za-z0-9_.-]+|\*)$`)
	reasonPattern   = regexp.MustCompile(`^[a-z_]+$`)
)

// Load reads the file, refusing one that other users can read because it holds the IMAP app
// password, the GitHub token and the Bark encryption key.
func Load(path string) (Config, error) {
	info, err := os.Stat(path)
	if err != nil {
		return Config{}, &Error{Path: path, Message: err.Error()}
	}
	if info.Mode().Perm()&0o077 != 0 {
		return Config{}, &Error{Path: path, Message: fmt.Sprintf(
			"mode is %#o but the file holds passwords and keys; run `chmod 600 %s`", info.Mode().Perm(), path)}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, &Error{Path: path, Message: err.Error()}
	}
	return Parse(path, data)
}

// Parse validates the TOML text; path is used only in error messages.
func Parse(path string, data []byte) (Config, error) {
	var raw fileConfig
	meta, err := toml.Decode(string(data), &raw)
	if err != nil {
		return Config{}, &Error{Path: path, Message: err.Error()}
	}
	if undecoded := meta.Undecoded(); len(undecoded) > 0 {
		keys := make([]string, len(undecoded))
		for i, key := range undecoded {
			keys[i] = key.String()
		}
		return Config{}, &Error{Path: path, Message: "unknown setting " + strings.Join(keys, ", ")}
	}
	return validate(path, raw)
}

func validate(path string, raw fileConfig) (Config, error) {
	fail := func(field, format string, args ...any) (Config, error) {
		return Config{}, &Error{Path: path, Field: field, Message: fmt.Sprintf(format, args...)}
	}

	if !hostNamePattern.MatchString(raw.HostName) {
		return fail("host_name", "must be the host's name in Minis: 1 to 32 letters, digits, '-' or '_'")
	}

	location := time.Local
	if raw.Timezone != "" {
		loaded, err := time.LoadLocation(raw.Timezone)
		if err != nil {
			return fail("timezone", "%q is not an IANA time zone such as Europe/Berlin", raw.Timezone)
		}
		location = loaded
	}

	var quiet *Window
	if raw.QuietHours != nil {
		start, ok := minutesOfDay(raw.QuietHours.Start)
		if !ok {
			return fail("quiet_hours.start", "%q is not a time such as 22:00", raw.QuietHours.Start)
		}
		end, ok := minutesOfDay(raw.QuietHours.End)
		if !ok {
			return fail("quiet_hours.end", "%q is not a time such as 07:30", raw.QuietHours.End)
		}
		if start == end {
			return fail("quiet_hours", "start and end are equal; remove the section to turn quiet hours off")
		}
		quiet = &Window{Start: start, End: end}
	}

	mail := make([]MailAccount, 0, len(raw.Mail))
	names := map[string]bool{}
	for i, account := range raw.Mail {
		field := fmt.Sprintf("mail[%d]", i)
		if !hostNamePattern.MatchString(account.Name) {
			return fail(field+".name", "must be 1 to 32 letters, digits, '-' or '_'")
		}
		if names[account.Name] {
			return fail(field+".name", "%q is used by another mail account", account.Name)
		}
		names[account.Name] = true
		if !isAddress(account.Address) {
			return fail(field+".address", "%q is not an email address", account.Address)
		}
		if account.AppPassword == "" {
			return fail(field+".app_password", "is empty; create a Google app password for %s", account.Address)
		}
		if len(account.Allow) == 0 {
			return fail(field+".allow", "is empty, so no mail would ever push; add [[%s.allow]] entries", field)
		}
		rules := make([]SenderRule, 0, len(account.Allow))
		for j, sender := range account.Allow {
			pattern := strings.ToLower(strings.TrimSpace(sender.Pattern))
			if pattern != AnySender && !isAddress(pattern) && !isDomainRule(pattern) {
				return fail(fmt.Sprintf("%s.allow[%d].pattern", field, j),
					"%q must be an address (alice@example.com), a domain (@example.com) or * for anyone", sender.Pattern)
			}
			requireDMARC := true
			if sender.RequireDMARC != nil {
				requireDMARC = *sender.RequireDMARC
			}
			rules = append(rules, SenderRule{Pattern: pattern, RequireDMARC: requireDMARC})
		}
		mail = append(mail, MailAccount{
			Name:             account.Name,
			Address:          strings.ToLower(account.Address),
			AppPassword:      account.AppPassword,
			GmailPrimaryOnly: account.GmailPrimaryOnly,
			Allow:            rules,
		})
	}

	var github *GitHubSource
	if raw.GitHub != nil {
		if raw.GitHub.Token == "" {
			return fail("github.token", "is empty; create a classic token with only the notifications scope")
		}
		reasons := raw.GitHub.Reasons
		if len(reasons) == 0 {
			reasons = DefaultGitHubReasons
		}
		for i, reason := range reasons {
			if !reasonPattern.MatchString(reason) {
				return fail(fmt.Sprintf("github.reasons[%d]", i), "%q is not a GitHub notification reason", reason)
			}
		}
		for i, repo := range raw.GitHub.Repos {
			if !repoPattern.MatchString(repo) {
				return fail(fmt.Sprintf("github.repos[%d]", i), "%q must be owner/name or owner/*", repo)
			}
		}
		github = &GitHubSource{Token: raw.GitHub.Token, Reasons: reasons, Repos: raw.GitHub.Repos}
	}

	if len(mail) == 0 && github == nil {
		return fail("", "nothing to watch: add a [[mail]] account or a [github] section")
	}

	if raw.Bark == nil {
		return fail("bark", "is missing; add the device key and encryption key from the Bark app")
	}
	server := raw.Bark.Server
	if server == "" {
		server = DefaultBarkServer
	}
	if !strings.HasPrefix(server, "https://") {
		return fail("bark.server", "%q must be an https:// URL", server)
	}
	if raw.Bark.DeviceKey == "" {
		return fail("bark.device_key", "is empty; copy it from the Bark app's home screen")
	}
	if position, ok := badKeyPosition(raw.Bark.EncryptionKey); !ok {
		if position == 0 {
			return fail("bark.encryption_key", "must be %d characters, found %d",
				BarkKeyLength, len([]rune(raw.Bark.EncryptionKey)))
		}
		return fail("bark.encryption_key",
			"character %d is not one of %q; generate a new key with `minis-hostd doctor`", position, BarkKeyAlphabet)
	}

	return Config{
		HostName:   raw.HostName,
		Timezone:   location,
		QuietHours: quiet,
		Mail:       mail,
		GitHub:     github,
		Bark: Bark{
			Server:        strings.TrimRight(server, "/"),
			DeviceKey:     raw.Bark.DeviceKey,
			EncryptionKey: raw.Bark.EncryptionKey,
		},
	}, nil
}

func minutesOfDay(clock string) (int, bool) {
	match := clockPattern.FindStringSubmatch(clock)
	if match == nil {
		return 0, false
	}
	hours := int(match[1][0]-'0')*10 + int(match[1][1]-'0')
	minutes := int(match[2][0]-'0')*10 + int(match[2][1]-'0')
	return hours*60 + minutes, true
}

func isAddress(s string) bool {
	local, domain, found := strings.Cut(s, "@")
	return found && local != "" && isDomain(domain)
}

func isDomainRule(s string) bool {
	return strings.HasPrefix(s, "@") && isDomain(s[1:])
}

func isDomain(s string) bool {
	return s != "" && strings.Contains(s, ".") && !strings.ContainsAny(s, "@ ") &&
		!strings.HasPrefix(s, ".") && !strings.HasSuffix(s, ".")
}

// badKeyPosition returns the 1-based position of the first character outside the alphabet, or 0
// with ok false when the length is wrong. Positions count characters, not bytes, because that is
// what the user sees in the Bark app.
func badKeyPosition(key string) (int, bool) {
	runes := []rune(key)
	if len(runes) != BarkKeyLength {
		return 0, false
	}
	for i, r := range runes {
		if !strings.ContainsRune(BarkKeyAlphabet, r) {
			return i + 1, false
		}
	}
	return 0, true
}
