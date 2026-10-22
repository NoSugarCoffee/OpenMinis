package cli

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	goimap "github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/emersion/go-imap/v2/imapserver"
	"github.com/emersion/go-imap/v2/imapserver/imapmemserver"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/notify"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/service"
)

const (
	doctorAddress  = "me@gmail.com"
	doctorPassword = "abcd efgh ijkl mnop"
	doctorToken    = "ghp_doctor"
	doctorBarkKey  = "jkdxn8hv24xhrzw5nkjm7fwerx8kmr53"
	goldenHome     = "/home/me"
	goldenGitHub   = "api.github.com"
)

var doctorNow = time.Date(2026, 10, 19, 10, 0, 0, 0, time.UTC)

// readOnlyGuard fails the test if doctor opens INBOX for writing; hostd must never change the mailbox.
type readOnlyGuard struct {
	imapserver.Session
	mu         *sync.Mutex
	violations *[]string
}

func (s readOnlyGuard) Select(mailbox string, options *goimap.SelectOptions) (*goimap.SelectData, error) {
	if options == nil || !options.ReadOnly {
		s.mu.Lock()
		*s.violations = append(*s.violations, "SELECT "+mailbox+" without read-only")
		s.mu.Unlock()
	}
	return s.Session.Select(mailbox, options)
}

func startIMAP(t *testing.T) func(*imapclient.Options) (*imapclient.Client, error) {
	t.Helper()
	memServer := imapmemserver.New()
	user := imapmemserver.NewUser(doctorAddress, doctorPassword)
	if err := user.Create("INBOX", nil); err != nil {
		t.Fatal(err)
	}
	memServer.AddUser(user)
	var mu sync.Mutex
	var violations []string
	server := imapserver.New(&imapserver.Options{
		NewSession: func(*imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			return readOnlyGuard{Session: memServer.NewSession(), mu: &mu, violations: &violations}, nil, nil
		},
		InsecureAuth: true,
		Caps:         goimap.CapSet{goimap.CapIMAP4rev1: {}},
		Logger:       log.New(io.Discard, "", 0),
	})
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go server.Serve(ln)
	t.Cleanup(func() {
		server.Close()
		mu.Lock()
		defer mu.Unlock()
		if len(violations) > 0 {
			t.Errorf("doctor tried to change the mailbox: %q", violations)
		}
	})
	return func(options *imapclient.Options) (*imapclient.Client, error) {
		return imapclient.DialInsecure(ln.Addr().String(), options)
	}
}

type fakeGitHub struct {
	server *httptest.Server
	status int
	scopes string
	date   time.Time
}

func startGitHub(t *testing.T) *fakeGitHub {
	t.Helper()
	gh := &fakeGitHub{status: http.StatusOK, scopes: "notifications", date: doctorNow}
	gh.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Date", gh.date.Format(http.TimeFormat))
		if r.URL.Path == "/" {
			return
		}
		if r.Method != http.MethodGet || r.URL.Path != "/notifications" || r.URL.Query().Get("per_page") != "1" {
			t.Errorf("unexpected GitHub request %s %s", r.Method, r.URL)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if r.Header.Get("Authorization") != "Bearer "+doctorToken {
			w.WriteHeader(http.StatusUnauthorized)
			io.WriteString(w, `{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest"}`)
			return
		}
		w.Header().Set("X-OAuth-Scopes", gh.scopes)
		w.WriteHeader(gh.status)
		if gh.status == http.StatusUnauthorized {
			io.WriteString(w, `{"message":"Bad credentials"}`)
			return
		}
		io.WriteString(w, "[]")
	}))
	t.Cleanup(gh.server.Close)
	return gh
}

type fakeBark struct {
	server *httptest.Server
	mu     sync.Mutex
	forms  []url.Values
}

func startBark(t *testing.T) *fakeBark {
	t.Helper()
	b := &fakeBark{}
	b.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Error(err)
		}
		if r.URL.Path != "/devicekey" {
			t.Errorf("bark path %q", r.URL.Path)
		}
		b.mu.Lock()
		b.forms = append(b.forms, r.PostForm)
		b.mu.Unlock()
		io.WriteString(w, `{"code":200,"message":"success"}`)
	}))
	t.Cleanup(b.server.Close)
	return b
}

func (b *fakeBark) received() []url.Values {
	b.mu.Lock()
	defer b.mu.Unlock()
	return slices.Clone(b.forms)
}

type doctorRig struct {
	env    Env
	out    *bytes.Buffer
	errOut *bytes.Buffer
	home   string
	github *fakeGitHub
	bark   *fakeBark
	deps   doctorDeps
}

func doctorConfig(password, barkServer string) string {
	return fmt.Sprintf(`host_name = "mac-mini"
timezone = "Europe/Berlin"

[[mail]]
name = "personal"
address = "%s"
app_password = "%s"

[[mail.allow]]
pattern = "alice@example.com"

[github]
token = "%s"

[bark]
server = "%s"
device_key = "devicekey"
encryption_key = "%s"
`, doctorAddress, password, doctorToken, barkServer, doctorBarkKey)
}

func newDoctorRig(t *testing.T, password string) *doctorRig {
	t.Helper()
	home := t.TempDir()
	gh := startGitHub(t)
	bark := startBark(t)
	var out, errOut bytes.Buffer
	rig := &doctorRig{
		env: Env{
			Version: "1.2.3", Stdout: &out, Stderr: &errOut, StateDir: filepath.Join(home, ".minis", "hostd"),
			Now: func() time.Time { return doctorNow }, Setup: Setup{Home: home},
		},
		out: &out, errOut: &errOut, home: home, github: gh, bark: bark,
		// httptest's TLS servers share one certificate, so the GitHub server's client trusts Bark too.
		deps: doctorDeps{Client: gh.server.Client(), GitHubBaseURL: gh.server.URL, DialIMAP: startIMAP(t), CheckTimeout: 5 * time.Second, NewNotifier: newNotifier},
	}
	rig.writeConfig(t, doctorConfig(password, bark.server.URL), 0o600)
	return rig
}

func (r *doctorRig) writeConfig(t *testing.T, text string, mode os.FileMode) {
	t.Helper()
	path := service.DefaultPaths(r.home).Config
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func (r *doctorRig) run(args ...string) (int, string) {
	r.out.Reset()
	r.errOut.Reset()
	status := runDoctor(r.env, args, r.deps)
	stdout := strings.ReplaceAll(r.out.String(), r.home, goldenHome)
	return status, strings.ReplaceAll(stdout, strings.TrimPrefix(r.github.server.URL, "https://"), goldenGitHub)
}

func decodeDoctor(t *testing.T, stdout string) doctorOutput {
	t.Helper()
	if strings.Count(stdout, "\n") != 1 {
		t.Fatalf("stdout is not one line: %q", stdout)
	}
	var decoded doctorOutput
	if err := json.Unmarshal([]byte(stdout), &decoded); err != nil {
		t.Fatalf("%v: %q", err, stdout)
	}
	return decoded
}

func findCheck(t *testing.T, checks []doctorCheck, name string) doctorCheck {
	t.Helper()
	for _, c := range checks {
		if c.Name == name {
			return c
		}
	}
	t.Fatalf("no %s check in %+v", name, checks)
	return doctorCheck{}
}

func TestDoctorAllOKMatchesGolden(t *testing.T) {
	rig := newDoctorRig(t, doctorPassword)
	status, stdout := rig.run("--push-test", "--json")
	if status != ExitOK {
		t.Fatalf("status %d stdout %s", status, stdout)
	}
	checkGolden(t, "doctor.json", stdout)
	if rig.errOut.Len() != 0 {
		t.Errorf("stderr %q on success", rig.errOut)
	}
}

func TestDoctorPushTestSendsOneEncryptedNotice(t *testing.T) {
	rig := newDoctorRig(t, doctorPassword)
	if status, stdout := rig.run("--json", "--push-test"); status != ExitOK {
		t.Fatalf("status %d stdout %s", status, stdout)
	}
	forms := rig.bark.received()
	if len(forms) != 1 {
		t.Fatalf("bark got %d requests, want 1", len(forms))
	}
	keys := slices.Sorted(func(yield func(string) bool) {
		for k := range forms[0] {
			if !yield(k) {
				return
			}
		}
	})
	if !slices.Equal(keys, []string{"ciphertext", "iv"}) {
		t.Fatalf("bark form fields %v, want only ciphertext and iv", keys)
	}
	sealed, err := base64.StdEncoding.DecodeString(forms[0].Get("ciphertext"))
	if err != nil {
		t.Fatal(err)
	}
	block, err := aes.NewCipher([]byte(doctorBarkKey))
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := gcm.Open(nil, []byte(forms[0].Get("iv")), sealed, nil)
	if err != nil {
		t.Fatal(err)
	}
	var notice struct {
		Title string `json:"title"`
		Body  string `json:"body"`
	}
	if err := json.Unmarshal(plaintext, &notice); err != nil {
		t.Fatal(err)
	}
	wantBody := "Test push from mac-mini: if you can read this, the Bark key matches."
	if notice.Title != "minis-hostd doctor" || notice.Body != wantBody {
		t.Errorf("notice %+v", notice)
	}
}

func TestDoctorWithoutPushTestSendsNothing(t *testing.T) {
	rig := newDoctorRig(t, doctorPassword)
	status, stdout := rig.run("--json")
	if status != ExitOK {
		t.Fatalf("status %d stdout %s", status, stdout)
	}
	if n := len(rig.bark.received()); n != 0 {
		t.Errorf("bark got %d requests without --push-test", n)
	}
	names := []string{}
	for _, c := range decodeDoctor(t, stdout).Checks {
		names = append(names, c.Name)
	}
	if want := []string{"config", "timezone", "clock", "mail:personal", "github"}; !slices.Equal(names, want) {
		t.Errorf("checks %v, want %v", names, want)
	}
}

func TestDoctorRejectedAppPassword(t *testing.T) {
	rig := newDoctorRig(t, "wrong password")
	status, stdout := rig.run("--json")
	if status != ExitError {
		t.Fatalf("status %d, want %d", status, ExitError)
	}
	mail := findCheck(t, decodeDoctor(t, stdout).Checks, "mail:personal")
	want := "Gmail rejected the app password for me@gmail.com; create a new one at https://myaccount.google.com/apppasswords"
	if mail.OK || mail.Detail != want {
		t.Errorf("mail check %+v", mail)
	}
	if strings.Contains(stdout, `"error"`) {
		t.Errorf("a failing check must not print the error object: %s", stdout)
	}
}

func TestDoctorGitHubRejectsTheToken(t *testing.T) {
	rig := newDoctorRig(t, doctorPassword)
	rig.github.status = http.StatusUnauthorized
	status, stdout := rig.run("--json")
	gh := findCheck(t, decodeDoctor(t, stdout).Checks, "github")
	if status != ExitError || gh.OK || !strings.Contains(gh.Detail, "401: Bad credentials") ||
		!strings.Contains(gh.Detail, "github.com/settings/tokens") {
		t.Errorf("status %d github check %+v", status, gh)
	}
}

func TestDoctorGitHubMissingScopes(t *testing.T) {
	rig := newDoctorRig(t, doctorPassword)
	rig.github.scopes = "read:user, gist"
	status, stdout := rig.run("--json")
	gh := findCheck(t, decodeDoctor(t, stdout).Checks, "github")
	if status != ExitError || gh.OK || !strings.Contains(gh.Detail, "read:user, gist") ||
		!strings.Contains(gh.Detail, "notifications scope") {
		t.Errorf("status %d github check %+v", status, gh)
	}
}

func TestDoctorGitHubRepoScopeIsEnough(t *testing.T) {
	rig := newDoctorRig(t, doctorPassword)
	rig.github.scopes = "repo"
	status, stdout := rig.run("--json")
	gh := findCheck(t, decodeDoctor(t, stdout).Checks, "github")
	if status != ExitOK || !gh.OK || !strings.Contains(gh.Detail, "more than hostd needs") {
		t.Errorf("status %d github check %+v", status, gh)
	}
}

func TestDoctorDetectsClockSkew(t *testing.T) {
	rig := newDoctorRig(t, doctorPassword)
	rig.github.date = doctorNow.Add(-5*time.Minute - 3*time.Second)
	status, stdout := rig.run("--json")
	clock := findCheck(t, decodeDoctor(t, stdout).Checks, "clock")
	if status != ExitError || clock.OK || !strings.Contains(clock.Detail, "5m3s ahead of api.github.com") {
		t.Errorf("status %d clock check %+v", status, clock)
	}

	rig.github.date = doctorNow.Add(90 * time.Second)
	status, stdout = rig.run("--json")
	clock = findCheck(t, decodeDoctor(t, stdout).Checks, "clock")
	if status != ExitOK || !clock.OK || !strings.Contains(clock.Detail, "1m30s behind") {
		t.Errorf("within tolerance: status %d clock check %+v", status, clock)
	}
}

func TestDoctorMissingConfigIsOneFailingCheck(t *testing.T) {
	rig := newDoctorRig(t, doctorPassword)
	if err := os.Remove(service.DefaultPaths(rig.home).Config); err != nil {
		t.Fatal(err)
	}
	status, stdout := rig.run("--json")
	checks := decodeDoctor(t, stdout).Checks
	if status != ExitError || len(checks) != 1 || checks[0].Name != "config" || checks[0].OK ||
		!strings.Contains(checks[0].Detail, "minis-hostd new-config --host-name") {
		t.Errorf("status %d checks %+v", status, checks)
	}
}

func TestDoctorConfigErrorsNameTheProblem(t *testing.T) {
	rig := newDoctorRig(t, doctorPassword)
	rig.writeConfig(t, doctorConfig(doctorPassword, rig.bark.server.URL), 0o644)
	_, stdout := rig.run("--json")
	if checks := decodeDoctor(t, stdout).Checks; len(checks) != 1 || !strings.Contains(checks[0].Detail, "chmod 600") {
		t.Errorf("mode 644: checks %+v", checks)
	}

	rig.writeConfig(t, strings.Replace(doctorConfig(doctorPassword, rig.bark.server.URL), `device_key = "devicekey"`, `device_key = ""`, 1), 0o600)
	_, stdout = rig.run("--json")
	if checks := decodeDoctor(t, stdout).Checks; len(checks) != 1 || !strings.Contains(checks[0].Detail, "bark.device_key") {
		t.Errorf("empty device key: checks %+v", checks)
	}
}

func TestDoctorPlainTextChecklist(t *testing.T) {
	rig := newDoctorRig(t, "wrong password")
	status, stdout := rig.run()
	want := strings.Join([]string{
		"✓ config — /home/me/.minis/hostd/config.toml loads (mode 600)",
		"✓ timezone — Europe/Berlin (from config.toml)",
		"✓ clock — within 2 minutes of api.github.com (0s off)",
		"✗ mail:personal — Gmail rejected the app password for me@gmail.com; create a new one at https://myaccount.google.com/apppasswords",
		"✓ github — token accepted; scopes: notifications",
		"1 of 5 checks failed.",
	}, "\n") + "\n"
	if status != ExitError || stdout != want {
		t.Errorf("status %d stdout:\n%s\nwant:\n%s", status, stdout, want)
	}
}

func TestDoctorBadArgsAreBadRequests(t *testing.T) {
	rig := newDoctorRig(t, doctorPassword)
	for _, args := range [][]string{
		{"--json", "--json"},
		{"--push-test", "--push-test", "--json"},
		{"--verbose", "--json"},
		{"extra", "--json"},
	} {
		status, stdout := rig.run(args...)
		if status != ExitError || !strings.Contains(stdout, `"code":"bad_request"`) {
			t.Errorf("%v: status %d stdout %q", args, status, stdout)
		}
	}
	if status, stdout, _ := run("doctor", "--bogus", "--json"); status != ExitError || !strings.Contains(stdout, `"bad_request"`) {
		t.Errorf("dispatcher: status %d stdout %q", status, stdout)
	}
}

func TestSystemZoneName(t *testing.T) {
	cases := []struct {
		tz, link, want string
		ok             bool
	}{
		{":Asia/Shanghai", "", "Asia/Shanghai", true},
		{"", "/var/db/timezone/zoneinfo/Europe/Berlin", "Europe/Berlin", true},
		{"", "/usr/share/zoneinfo/America/New_York", "America/New_York", true},
		{"Not/AZone", "", "", false},
		{"", "", "", false},
	}
	for _, c := range cases {
		if got, ok := systemZoneName(c.tz, c.link); got != c.want || ok != c.ok {
			t.Errorf("systemZoneName(%q, %q) = %q, %v; want %q, %v", c.tz, c.link, got, ok, c.want, c.ok)
		}
	}
}

func useAPNs(t *testing.T, rig *doctorRig, register bool) *httptest.Server {
	t.Helper()
	stateDir := rig.env.StateDir
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "AuthKey_ABC123DEFG.p8"),
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	text := doctorConfig(doctorPassword, rig.bark.server.URL)
	text = text[:strings.Index(text, "[bark]")] + "[apns]\nkey_file = \"AuthKey_ABC123DEFG.p8\"\nkey_id = \"ABC123DEFG\"\nteam_id = \"28ZGY8C268\"\n"
	rig.writeConfig(t, text, 0o600)
	if register {
		device, err := notify.NewDevice(deviceToken, "com.example.pico", notify.Development, doctorNow)
		if err != nil {
			t.Fatal(err)
		}
		if err := notify.SaveRegistrations(filepath.Join(stateDir, notify.RegistrationFile), notify.Registrations{Active: &device}); err != nil {
			t.Fatal(err)
		}
	}
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/3/device/"+deviceToken {
			t.Errorf("path %s", r.URL.Path)
		}
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	t.Cleanup(server.Close)
	rig.deps.NewNotifier = func(env Env, cfg config.Config, _ *http.Client) (notify.Notifier, error) {
		notifier, err := newNotifier(env, cfg, server.Client())
		if apns, ok := notifier.(*notify.APNs); ok {
			apns.Endpoints[notify.Development] = server.URL
		}
		return notifier, err
	}
	return server
}

func TestDoctorChecksTheAPNsSetupAndPushTests(t *testing.T) {
	rig := newDoctorRig(t, doctorPassword)
	useAPNs(t, rig, true)
	status, stdout := rig.run("--push-test", "--json")
	checks := decodeDoctor(t, stdout).Checks
	if status != ExitOK {
		t.Fatalf("status %d: %+v", status, checks)
	}
	if c := findCheck(t, checks, "apns"); !strings.Contains(c.Detail, "com.example.pico registered") {
		t.Errorf("apns %+v", c)
	}
	if c := findCheck(t, checks, "push"); !strings.Contains(c.Detail, "APNs accepted") {
		t.Errorf("push %+v", c)
	}
}

func TestDoctorAPNsWithoutARegistrationSaysHowToRegister(t *testing.T) {
	rig := newDoctorRig(t, doctorPassword)
	useAPNs(t, rig, false)
	status, stdout := rig.run("--json")
	if c := findCheck(t, decodeDoctor(t, stdout).Checks, "apns"); status != ExitError || c.OK || !strings.Contains(c.Detail, "Send to This iPhone") {
		t.Errorf("status %d apns %+v", status, c)
	}
}
