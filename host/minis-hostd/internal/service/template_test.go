package service

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/notify"
)

func newTemplate(t *testing.T) string {
	t.Helper()
	text, err := NewConfigTemplate("mac-mini", notify.GenerateKey())
	if err != nil {
		t.Fatal(err)
	}
	return text
}

// uncomment turns an exact commented block of the template into live settings, failing when the
// template no longer carries that block.
func uncomment(t *testing.T, text, block string) string {
	t.Helper()
	if strings.Count(text, block) != 1 {
		t.Fatalf("template does not contain exactly one copy of\n%s", block)
	}
	lines := strings.Split(block, "\n")
	for i, line := range lines {
		lines[i] = strings.TrimPrefix(strings.TrimPrefix(line, "#"), " ")
	}
	return strings.Replace(text, block, strings.Join(lines, "\n"), 1)
}

func replaceOnce(t *testing.T, text, old, replacement string) string {
	t.Helper()
	if strings.Count(text, old) != 1 {
		t.Fatalf("template does not contain exactly one %q", old)
	}
	return strings.Replace(text, old, replacement, 1)
}

func TestTemplateAsWrittenAsksForSomethingToWatch(t *testing.T) {
	_, err := config.Parse("config.toml", []byte(newTemplate(t)))
	if err == nil || !strings.Contains(err.Error(), "nothing to watch") {
		t.Fatalf("err = %v", err)
	}
}

func TestTemplateParsesOnceFilledIn(t *testing.T) {
	text := newTemplate(t)
	text = uncomment(t, text, `# timezone = "Europe/Berlin"`)
	text = uncomment(t, text, `# [quiet_hours]
# start = "22:00"
# end = "07:30"`)
	text = uncomment(t, text, `# [[mail]]
# name = "personal"
# address = "you@gmail.com"
# app_password = "abcd efgh ijkl mnop"
# gmail_primary_only = true
#
# [[mail.allow]]
# pattern = "alice@example.com"
#
# [[mail.allow]]
# pattern = "@example.org"
# require_dmarc = false`)
	text = uncomment(t, text, `# [github]
# token = "ghp_..."
# repos = ["owner/name", "owner/*"]`)
	text = replaceOnce(t, text, `device_key = ""`, `device_key = "abcdef"`)

	cfg, err := config.Parse("config.toml", []byte(text))
	if err != nil {
		t.Fatalf("%v\n%s", err, text)
	}
	if cfg.HostName != "mac-mini" || len(cfg.Mail) != 1 || len(cfg.Mail[0].Allow) != 2 ||
		cfg.GitHub == nil || cfg.QuietHours == nil || cfg.Bark.Server != config.DefaultBarkServer {
		t.Errorf("parsed %+v", cfg)
	}
}

func TestTemplateWithOnlyGitHubParses(t *testing.T) {
	text := uncomment(t, newTemplate(t), `# [github]
# token = "ghp_..."
# repos = ["owner/name", "owner/*"]`)
	_, err := config.Parse("config.toml", []byte(text))
	if err == nil || !strings.Contains(err.Error(), "bark.device_key") {
		t.Fatalf("an empty device key should be the next thing to fix, got %v", err)
	}
}

func TestTemplateRejectsBadInput(t *testing.T) {
	if _, err := NewConfigTemplate("my host", notify.GenerateKey()); err == nil {
		t.Error("accepted a host name with a space")
	}
	if _, err := NewConfigTemplate(`a"b`, notify.GenerateKey()); err == nil {
		t.Error("accepted a host name with a quote")
	}
	if _, err := NewConfigTemplate("mac-mini", "short"); err == nil {
		t.Error("accepted a short key")
	}
	if _, err := NewConfigTemplate("mac-mini", strings.Repeat("0", config.BarkKeyLength)); err == nil {
		t.Error("accepted a key outside the alphabet")
	}
}

func TestWriteConfigTemplateCreatesA0600File(t *testing.T) {
	path := filepath.Join(t.TempDir(), "minis", "hostd", "config.toml")
	if err := WriteConfigTemplate(path, "host_name = \"x\"\n"); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("file mode %#o", info.Mode().Perm())
	}
	dir, err := os.Stat(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if dir.Mode().Perm() != 0o700 {
		t.Errorf("dir mode %#o", dir.Mode().Perm())
	}
}

func TestWriteConfigTemplateRefusesToOverwrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.toml")
	if err := os.WriteFile(path, []byte("mine"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := WriteConfigTemplate(path, "template")
	if !errors.Is(err, os.ErrExist) {
		t.Fatalf("err = %v", err)
	}
	if data, _ := os.ReadFile(path); string(data) != "mine" {
		t.Errorf("config overwritten: %q", data)
	}
}

func TestDefaultConfigPath(t *testing.T) {
	if got := DefaultPaths("/home/me").Config; got != "/home/me/.minis/hostd/config.toml" {
		t.Errorf("config path %q", got)
	}
}
