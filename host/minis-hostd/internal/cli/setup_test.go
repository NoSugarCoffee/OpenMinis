package cli

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/service"
)

type recordingRunner struct{ commands []string }

func (r *recordingRunner) Run(_ context.Context, c service.Command) error {
	r.commands = append(r.commands, c.String())
	return nil
}

func setupEnv(t *testing.T, runner *recordingRunner) (Env, *bytes.Buffer, *bytes.Buffer, string) {
	t.Helper()
	home := t.TempDir()
	var out, errOut bytes.Buffer
	env := Env{
		Version: "1.2.3", Stdout: &out, Stderr: &errOut,
		StateDir: filepath.Join(home, ".minis", "hostd"), Now: func() time.Time { return time.Unix(0, 0) },
		Setup: Setup{Home: home, GOOS: "linux", UID: 501, Runner: runner},
	}
	return env, &out, &errOut, home
}

func TestNewConfigWritesTemplateOnce(t *testing.T) {
	env, out, errOut, home := setupEnv(t, &recordingRunner{})
	if status := Run(env, []string{"new-config", "--host-name", "mac-mini"}); status != ExitOK {
		t.Fatalf("status %d stderr %q", status, errOut)
	}
	path := filepath.Join(home, ".minis", "hostd", "config.toml")
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("config %v %v", info, err)
	}
	if !strings.Contains(out.String(), path) || strings.HasPrefix(out.String(), "{") {
		t.Errorf("stdout %q should be plain text naming the file", out)
	}
	errOut.Reset()
	if status := Run(env, []string{"new-config", "--host-name", "mac-mini"}); status != ExitError ||
		!strings.Contains(errOut.String(), "already exists") {
		t.Errorf("second run: status %d stderr %q", status, errOut)
	}
}

func TestInstallServiceRefusesAnIncompleteConfig(t *testing.T) {
	runner := &recordingRunner{}
	env, _, errOut, _ := setupEnv(t, runner)
	if status := Run(env, []string{"new-config", "--host-name", "mac-mini"}); status != ExitOK {
		t.Fatal(errOut)
	}
	status := Run(env, []string{"install-service"})
	if status != ExitError || !strings.Contains(errOut.String(), "nothing to watch") ||
		!strings.Contains(errOut.String(), "install-service` again") {
		t.Fatalf("status %d stderr %q", status, errOut)
	}
	if len(runner.commands) != 0 {
		t.Errorf("ran %v despite the bad config", runner.commands)
	}
}

func TestInstallServiceWithAValidConfig(t *testing.T) {
	runner := &recordingRunner{}
	env, out, errOut, home := setupEnv(t, runner)
	paths := service.DefaultPaths(home)
	if err := os.MkdirAll(filepath.Dir(paths.Config), 0o700); err != nil {
		t.Fatal(err)
	}
	valid, err := os.ReadFile(filepath.Join("..", "..", "testdata", "config", "valid.toml"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.Config, valid, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(paths.Binary), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.Binary, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if status := Run(env, []string{"install-service"}); status != ExitOK {
		t.Fatalf("status %d stderr %q", status, errOut)
	}
	if !strings.Contains(out.String(), "minis-hostd.service") || len(runner.commands) == 0 {
		t.Errorf("stdout %q commands %v", out, runner.commands)
	}
}
