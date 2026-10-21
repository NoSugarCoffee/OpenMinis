package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/service"
)

func TestRunRefusesGmailPrimaryOnly(t *testing.T) {
	env, _, errOut, home := setupEnv(t, &recordingRunner{})
	paths := service.DefaultPaths(home)
	valid, err := os.ReadFile(filepath.Join("..", "..", "testdata", "config", "valid.toml"))
	if err != nil {
		t.Fatal(err)
	}
	primaryOnly := strings.Replace(string(valid), `app_password = "abcd efgh ijkl mnop"`,
		"app_password = \"abcd efgh ijkl mnop\"\ngmail_primary_only = true", 1)
	if primaryOnly == string(valid) {
		t.Fatal("the fixture no longer has the app_password line this test edits")
	}
	if err := os.MkdirAll(filepath.Dir(paths.Config), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.Config, []byte(primaryOnly), 0o600); err != nil {
		t.Fatal(err)
	}

	status := Run(env, []string{"run"})
	if status != ExitError || !strings.Contains(errOut.String(), "gmail_primary_only = true is not supported yet") ||
		!strings.Contains(errOut.String(), `"personal"`) {
		t.Errorf("status %d stderr %q", status, errOut)
	}
	if _, err := os.Stat(filepath.Join(env.StateDir, databaseName)); !os.IsNotExist(err) {
		t.Errorf("run opened the database before refusing: %v", err)
	}
}
