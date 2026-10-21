package service

import (
	"context"
	"encoding/xml"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func golden(t *testing.T, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "testdata", "service", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestLaunchdPlistMatchesGolden(t *testing.T) {
	got := LaunchdPlist(DefaultPaths("/Users/me & you"))
	if want := golden(t, "app.minis.hostd.plist"); got != want {
		t.Errorf("plist differs from golden:\n%s", got)
	}
}

func TestLaunchdPlistIsWellFormedXML(t *testing.T) {
	decoder := xml.NewDecoder(strings.NewReader(LaunchdPlist(DefaultPaths("/Users/a<b>&\"c'"))))
	decoder.Strict = true
	var texts []string
	for {
		token, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if data, ok := token.(xml.CharData); ok {
			if text := strings.TrimSpace(string(data)); text != "" {
				texts = append(texts, text)
			}
		}
	}
	if !contains(texts, "/Users/a<b>&\"c'/.minis/bin/minis-hostd") {
		t.Errorf("escaped binary path did not round-trip: %q", texts)
	}
}

func TestSystemdUnitMatchesGolden(t *testing.T) {
	got := SystemdUnit(DefaultPaths("/home/me"))
	if want := golden(t, "minis-hostd.service"); got != want {
		t.Errorf("unit differs from golden:\n%s", got)
	}
}

func TestTargetForGOOS(t *testing.T) {
	for goos, want := range map[string]OS{"darwin": Darwin, "linux": Linux} {
		got, err := TargetForGOOS(goos)
		if err != nil || got != want {
			t.Errorf("%s: got %q, %v", goos, got, err)
		}
	}
	if _, err := TargetForGOOS("windows"); err == nil {
		t.Error("windows accepted")
	}
}

type fakeRunner struct {
	commands []Command
	results  map[string]error
	// queued results are returned first, one per call, before falling back to results.
	queued map[string][]error
}

func (r *fakeRunner) Run(_ context.Context, c Command) error {
	r.commands = append(r.commands, c)
	if next := r.queued[c.String()]; len(next) > 0 {
		r.queued[c.String()] = next[1:]
		return next[0]
	}
	return r.results[c.String()]
}

func newHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	paths := DefaultPaths(home)
	if err := os.MkdirAll(filepath.Dir(paths.Binary), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.Binary, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return home
}

func newInstaller(home string, runner *fakeRunner) Installer {
	return Installer{Home: home, UID: 501, Runner: runner, Pause: func(time.Duration) {}}
}

func notLoaded() error { return &ExitError{Code: 113, Output: "Could not find service"} }

func cmds(lines ...string) []string { return lines }

func commandLines(commands []Command) []string {
	lines := make([]string, len(commands))
	for i, c := range commands {
		lines[i] = c.String()
	}
	return lines
}

const probe = "launchctl print gui/501/app.minis.hostd"

func TestInstallDarwinWritesPlistAndLoadsIt(t *testing.T) {
	home := newHome(t)
	runner := &fakeRunner{results: map[string]error{probe: notLoaded()}}
	result, err := newInstaller(home, runner).Install(context.Background(), Darwin, DefaultPaths(home))
	if err != nil {
		t.Fatal(err)
	}
	plistPath := filepath.Join(home, "Library", "LaunchAgents", "app.minis.hostd.plist")
	if result.UnitPath != plistPath {
		t.Errorf("unit path %q", result.UnitPath)
	}
	data, err := os.ReadFile(plistPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != LaunchdPlist(DefaultPaths(home)) {
		t.Error("written plist differs from the rendered one")
	}
	want := cmds(
		probe,
		"launchctl bootstrap gui/501 "+plistPath,
		"launchctl kickstart -k gui/501/app.minis.hostd",
	)
	if got := commandLines(runner.commands); !reflect.DeepEqual(got, want) {
		t.Errorf("commands\n got %q\nwant %q", got, want)
	}
	if info, err := os.Stat(DefaultPaths(home).StateDir); err != nil || info.Mode().Perm() != 0o700 {
		t.Errorf("state dir: %v %v", info, err)
	}
	if len(result.Notes) == 0 {
		t.Error("no next steps")
	}
}

func TestInstallDarwinReloadsALoadedService(t *testing.T) {
	home := newHome(t)
	runner := &fakeRunner{results: map[string]error{}}
	_, err := newInstaller(home, runner).Install(context.Background(), Darwin, DefaultPaths(home))
	if err != nil {
		t.Fatal(err)
	}
	plistPath := filepath.Join(home, "Library", "LaunchAgents", "app.minis.hostd.plist")
	want := cmds(
		probe,
		"launchctl bootout gui/501/app.minis.hostd",
		"launchctl bootstrap gui/501 "+plistPath,
		"launchctl kickstart -k gui/501/app.minis.hostd",
	)
	if got := commandLines(runner.commands); !reflect.DeepEqual(got, want) {
		t.Errorf("commands\n got %q\nwant %q", got, want)
	}
}

func TestInstallDarwinRetriesBootstrapWhileTheOldJobIsStillGoing(t *testing.T) {
	home := newHome(t)
	plistPath := filepath.Join(home, "Library", "LaunchAgents", "app.minis.hostd.plist")
	bootstrap := "launchctl bootstrap gui/501 " + plistPath
	ioError := &ExitError{Code: 5, Output: "Bootstrap failed: 5: Input/output error"}
	runner := &fakeRunner{results: map[string]error{}, queued: map[string][]error{bootstrap: {ioError, ioError}}}
	if _, err := newInstaller(home, runner).Install(context.Background(), Darwin, DefaultPaths(home)); err != nil {
		t.Fatal(err)
	}
	want := cmds(
		probe,
		"launchctl bootout gui/501/app.minis.hostd",
		bootstrap, bootstrap, bootstrap,
		"launchctl kickstart -k gui/501/app.minis.hostd",
	)
	if got := commandLines(runner.commands); !reflect.DeepEqual(got, want) {
		t.Errorf("commands\n got %q\nwant %q", got, want)
	}
}

func TestInstallDarwinGivesUpOnAPersistentBootstrapError(t *testing.T) {
	home := newHome(t)
	plistPath := filepath.Join(home, "Library", "LaunchAgents", "app.minis.hostd.plist")
	ioError := &ExitError{Code: 5, Output: "Bootstrap failed: 5: Input/output error"}
	runner := &fakeRunner{results: map[string]error{"launchctl bootstrap gui/501 " + plistPath: ioError}}
	_, err := newInstaller(home, runner).Install(context.Background(), Darwin, DefaultPaths(home))
	if !errors.Is(err, ioError) {
		t.Fatalf("err = %v", err)
	}
	if got := len(runner.commands); got != 2+bootoutSettleAttempts {
		t.Errorf("ran %d commands, want %d", got, 2+bootoutSettleAttempts)
	}
}

func TestInstallDarwinStopsWhenLaunchctlCannotRun(t *testing.T) {
	home := newHome(t)
	runner := &fakeRunner{results: map[string]error{probe: exec.ErrNotFound}}
	_, err := newInstaller(home, runner).Install(context.Background(), Darwin, DefaultPaths(home))
	if !errors.Is(err, exec.ErrNotFound) {
		t.Fatalf("err = %v", err)
	}
	if len(runner.commands) != 1 {
		t.Errorf("kept going after the probe failed: %q", commandLines(runner.commands))
	}
}

func TestInstallLinuxWritesUnitAndEnablesIt(t *testing.T) {
	home := newHome(t)
	runner := &fakeRunner{}
	result, err := newInstaller(home, runner).Install(context.Background(), Linux, DefaultPaths(home))
	if err != nil {
		t.Fatal(err)
	}
	unitPath := filepath.Join(home, ".config", "systemd", "user", "minis-hostd.service")
	data, err := os.ReadFile(unitPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != SystemdUnit(DefaultPaths(home)) {
		t.Error("written unit differs from the rendered one")
	}
	want := cmds(
		"systemctl --user daemon-reload",
		"systemctl --user enable --now minis-hostd.service",
	)
	if got := commandLines(runner.commands); !reflect.DeepEqual(got, want) {
		t.Errorf("commands\n got %q\nwant %q", got, want)
	}
	if !strings.Contains(strings.Join(result.Notes, "\n"), "loginctl enable-linger") {
		t.Errorf("no linger hint in %q", result.Notes)
	}
}

func TestReinstallLinuxRestartsTheService(t *testing.T) {
	home := newHome(t)
	installer := newInstaller(home, &fakeRunner{})
	if _, err := installer.Install(context.Background(), Linux, DefaultPaths(home)); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{}
	if _, err := newInstaller(home, runner).Install(context.Background(), Linux, DefaultPaths(home)); err != nil {
		t.Fatal(err)
	}
	want := cmds(
		"systemctl --user daemon-reload",
		"systemctl --user enable --now minis-hostd.service",
		"systemctl --user restart minis-hostd.service",
	)
	if got := commandLines(runner.commands); !reflect.DeepEqual(got, want) {
		t.Errorf("commands\n got %q\nwant %q", got, want)
	}
}

func TestInstallLinuxRejectsPathsSystemdWouldReinterpret(t *testing.T) {
	home := newHome(t)
	paths := DefaultPaths(home)
	paths.Binary = filepath.Join(home, "100%", "minis-hostd")
	runner := &fakeRunner{}
	if _, err := newInstaller(home, runner).Install(context.Background(), Linux, paths); err == nil {
		t.Fatal("accepted a path with %")
	}
	if len(runner.commands) != 0 {
		t.Error("ran commands")
	}
}

func TestInstallRefusesAMissingBinary(t *testing.T) {
	home := t.TempDir()
	runner := &fakeRunner{}
	_, err := newInstaller(home, runner).Install(context.Background(), Linux, DefaultPaths(home))
	if err == nil || !strings.Contains(err.Error(), "minis-hostd") {
		t.Fatalf("err = %v", err)
	}
}

func writeForeignUnit(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("[Service]\nExecStart=/usr/bin/true\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestInstallRefusesToOverwriteAFileItDidNotWrite(t *testing.T) {
	for _, target := range []OS{Darwin, Linux} {
		home := newHome(t)
		path, err := UnitPath(target, home)
		if err != nil {
			t.Fatal(err)
		}
		writeForeignUnit(t, path)
		runner := &fakeRunner{}
		_, err = newInstaller(home, runner).Install(context.Background(), target, DefaultPaths(home))
		if !errors.Is(err, ErrNotManaged) {
			t.Errorf("%s: err = %v", target, err)
		}
		if len(runner.commands) != 0 {
			t.Errorf("%s: ran %q", target, commandLines(runner.commands))
		}
		if data, _ := os.ReadFile(path); !strings.HasPrefix(string(data), "[Service]") {
			t.Errorf("%s: foreign file was changed", target)
		}
	}
}

func TestUninstallDarwinUnloadsAndRemovesThePlist(t *testing.T) {
	home := newHome(t)
	if _, err := newInstaller(home, &fakeRunner{results: map[string]error{probe: notLoaded()}}).
		Install(context.Background(), Darwin, DefaultPaths(home)); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{}
	result, err := newInstaller(home, runner).Uninstall(context.Background(), Darwin)
	if err != nil {
		t.Fatal(err)
	}
	want := cmds(probe, "launchctl bootout gui/501/app.minis.hostd")
	if got := commandLines(runner.commands); !reflect.DeepEqual(got, want) {
		t.Errorf("commands\n got %q\nwant %q", got, want)
	}
	if _, err := os.Stat(result.UnitPath); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("plist still there: %v", err)
	}
}

func TestUninstallLinuxDisablesAndRemovesTheUnit(t *testing.T) {
	home := newHome(t)
	if _, err := newInstaller(home, &fakeRunner{}).Install(context.Background(), Linux, DefaultPaths(home)); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{}
	result, err := newInstaller(home, runner).Uninstall(context.Background(), Linux)
	if err != nil {
		t.Fatal(err)
	}
	want := cmds(
		"systemctl --user disable --now minis-hostd.service",
		"systemctl --user daemon-reload",
	)
	if got := commandLines(runner.commands); !reflect.DeepEqual(got, want) {
		t.Errorf("commands\n got %q\nwant %q", got, want)
	}
	if _, err := os.Stat(result.UnitPath); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("unit still there: %v", err)
	}
}

func TestUninstallLeavesAFileItDidNotWrite(t *testing.T) {
	for _, target := range []OS{Darwin, Linux} {
		home := newHome(t)
		path, err := UnitPath(target, home)
		if err != nil {
			t.Fatal(err)
		}
		writeForeignUnit(t, path)
		runner := &fakeRunner{}
		_, err = newInstaller(home, runner).Uninstall(context.Background(), target)
		if !errors.Is(err, ErrNotManaged) {
			t.Errorf("%s: err = %v", target, err)
		}
		if len(runner.commands) != 0 {
			t.Errorf("%s: ran %q", target, commandLines(runner.commands))
		}
		if _, err := os.Stat(path); err != nil {
			t.Errorf("%s: foreign file removed: %v", target, err)
		}
	}
}

func TestUninstallWithNothingInstalledSaysSo(t *testing.T) {
	home := t.TempDir()
	runner := &fakeRunner{results: map[string]error{probe: notLoaded()}}
	result, err := newInstaller(home, runner).Uninstall(context.Background(), Darwin)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Notes) != 1 || !strings.Contains(result.Notes[0], "not installed") {
		t.Errorf("notes %q", result.Notes)
	}
}

func TestExecRunnerReportsExitStatusAndOutput(t *testing.T) {
	err := ExecRunner{}.Run(context.Background(), Command{Name: "sh", Args: []string{"-c", "echo nope >&2; exit 3"}})
	var exitErr *ExitError
	if !errors.As(err, &exitErr) || exitErr.Code != 3 || !strings.Contains(exitErr.Output, "nope") {
		t.Fatalf("err = %#v", err)
	}
	if err := (ExecRunner{}).Run(context.Background(), Command{Name: "true"}); err != nil {
		t.Fatal(err)
	}
	err = ExecRunner{}.Run(context.Background(), Command{Name: "minis-hostd-no-such-command"})
	if err == nil || errors.As(err, &exitErr) {
		t.Fatalf("missing command gave %#v", err)
	}
}

func TestScriptsParseAsPOSIXShell(t *testing.T) {
	for _, script := range []string{"release.sh", "install.sh"} {
		output, err := exec.Command("sh", "-n", filepath.Join("..", "..", "scripts", script)).CombinedOutput()
		if err != nil {
			t.Errorf("%s: %v\n%s", script, err, output)
		}
	}
}

func contains(values []string, want string) bool {
	for _, v := range values {
		if v == want {
			return true
		}
	}
	return false
}
