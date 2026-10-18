package config

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func validText(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "testdata", "config", "valid.toml"))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func writeConfig(t *testing.T, text string, mode os.FileMode) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.toml")
	if err := os.WriteFile(path, []byte(text), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestValidConfigLoads(t *testing.T) {
	cfg, err := Load(writeConfig(t, validText(t), 0o600))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.HostName != "mac-mini" || cfg.Timezone.String() != "Europe/Berlin" {
		t.Errorf("host %q zone %q", cfg.HostName, cfg.Timezone)
	}
	if *cfg.QuietHours != (Window{Start: 22 * 60, End: 7*60 + 30}) {
		t.Errorf("quiet hours %+v", *cfg.QuietHours)
	}
	account := cfg.Mail[0]
	if account.Address != "me@gmail.com" {
		t.Errorf("address %q is not lower-cased", account.Address)
	}
	wantRules := []SenderRule{
		{Pattern: "alice@example.com", RequireDMARC: true},
		{Pattern: "@example.org", RequireDMARC: false},
	}
	for i, want := range wantRules {
		if account.Allow[i] != want {
			t.Errorf("rule %d = %+v, want %+v", i, account.Allow[i], want)
		}
	}
	if strings.Join(cfg.GitHub.Reasons, ",") != strings.Join(DefaultGitHubReasons, ",") {
		t.Errorf("reasons %v", cfg.GitHub.Reasons)
	}
	if cfg.Bark.Server != DefaultBarkServer {
		t.Errorf("server %q", cfg.Bark.Server)
	}
}

func TestReadableByOthersIsRefused(t *testing.T) {
	path := writeConfig(t, validText(t), 0o644)
	_, err := Load(path)
	if err == nil || !strings.Contains(err.Error(), "chmod 600 "+path) {
		t.Fatalf("err = %v", err)
	}
}

func TestInvalidSettingsNameTheField(t *testing.T) {
	cases := []struct {
		name, old, new, field, message string
	}{
		{"unknown key", `timezone = "Europe/Berlin"`, "timezone = \"Europe/Berlin\"\ncolour = \"blue\"", "", "unknown setting colour"},
		{"host name", `host_name = "mac-mini"`, `host_name = "mac mini"`, "host_name", "1 to 32"},
		{"time zone", `timezone = "Europe/Berlin"`, `timezone = "Mars/Olympus"`, "timezone", "IANA"},
		{"quiet start", `start = "22:00"`, `start = "24:00"`, "quiet_hours.start", "22:00"},
		{"quiet equal", `end = "07:30"`, `end = "22:00"`, "quiet_hours", "equal"},
		{"address", `address = "Me@Gmail.com"`, `address = "me"`, "mail[0].address", "not an email address"},
		{"app password", `app_password = "abcd efgh ijkl mnop"`, `app_password = ""`, "mail[0].app_password", "app password"},
		{"rule without at", `pattern = "alice@example.com"`, `pattern = "alice"`, "mail[0].allow[0].pattern", "@example.com"},
		{"rule bare at", `pattern = "alice@example.com"`, `pattern = "@"`, "mail[0].allow[0].pattern", "@example.com"},
		{"repo", `"openclaw/openclaw"`, `"openclaw"`, "github.repos[1]", "owner/name"},
		{"github token", `token = "ghp_example"`, `token = ""`, "github.token", "notifications scope"},
		{"key length", `encryption_key = "jkdxn8hv24xhrzw5nkjm7fwerx8kmr53"`, `encryption_key = "short"`, "bark.encryption_key", "found 5"},
		// The S3 failure: a Cyrillic у in place of a Latin y in the first position.
		{"key look-alike", `encryption_key = "jkdxn8hv24xhrzw5nkjm7fwerx8kmr53"`, `encryption_key = "уkdxn8hv24xhrzw5nkjm7fwerx8kmr53"`, "bark.encryption_key", "character 1"},
		{"key zero", `encryption_key = "jkdxn8hv24xhrzw5nkjm7fwerx8kmr53"`, `encryption_key = "jkdxn8hv24xhrzw5nkjm7fwerx8kmr50"`, "bark.encryption_key", "character 32"},
		{"http server", `device_key = "devicekey"`, "server = \"http://bark.local\"\ndevice_key = \"devicekey\"", "bark.server", "https://"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			text := validText(t)
			if !strings.Contains(text, tc.old) {
				t.Fatalf("fixture lacks %q", tc.old)
			}
			_, err := Parse("config.toml", []byte(strings.Replace(text, tc.old, tc.new, 1)))
			var configErr *Error
			if !errors.As(err, &configErr) {
				t.Fatalf("err = %v, want *Error", err)
			}
			if configErr.Field != tc.field || !strings.Contains(configErr.Message, tc.message) {
				t.Errorf("got field %q message %q, want field %q containing %q",
					configErr.Field, configErr.Message, tc.field, tc.message)
			}
		})
	}
}

func TestNothingToWatchIsRefused(t *testing.T) {
	text := `host_name = "mac-mini"
[bark]
device_key = "devicekey"
encryption_key = "jkdxn8hv24xhrzw5nkjm7fwerx8kmr53"
`
	_, err := Parse("config.toml", []byte(text))
	if err == nil || !strings.Contains(err.Error(), "nothing to watch") {
		t.Fatalf("err = %v", err)
	}
}

func TestEmptyAllowlistIsRefused(t *testing.T) {
	text := `host_name = "mac-mini"
[[mail]]
name = "personal"
address = "me@gmail.com"
app_password = "x"
[bark]
device_key = "devicekey"
encryption_key = "jkdxn8hv24xhrzw5nkjm7fwerx8kmr53"
`
	_, err := Parse("config.toml", []byte(text))
	if err == nil || !strings.Contains(err.Error(), "no mail would ever push") {
		t.Fatalf("err = %v", err)
	}
}
