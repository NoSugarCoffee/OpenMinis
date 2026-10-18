// Package service installs minis-hostd as a per-user service: a launchd agent on macOS and a
// systemd user unit on Linux. Rendering is pure; every side effect outside the file system goes
// through a Runner so tests never touch launchctl or systemctl.
package service

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type OS string

const (
	Darwin OS = "darwin"
	Linux  OS = "linux"
)

// Marker is on a line of every file this package writes; a unit without it belongs to someone
// else and is never overwritten or removed.
const Marker = "Managed by minis-hostd."

const (
	launchdLabel = "app.minis.hostd"
	systemdUnit  = "minis-hostd.service"
)

var ErrNotManaged = errors.New("file was not written by minis-hostd")

// Paths are the files on the host (spec §3.1).
type Paths struct {
	Binary   string
	StateDir string
	Config   string
	LogFile  string
}

func DefaultPaths(home string) Paths {
	stateDir := filepath.Join(home, ".minis", "hostd")
	return Paths{
		Binary:   filepath.Join(home, ".minis", "bin", "minis-hostd"),
		StateDir: stateDir,
		Config:   filepath.Join(stateDir, "config.toml"),
		LogFile:  filepath.Join(stateDir, "hostd.log"),
	}
}

func TargetForGOOS(goos string) (OS, error) {
	switch OS(goos) {
	case Darwin, Linux:
		return OS(goos), nil
	default:
		return "", fmt.Errorf("minis-hostd runs as a service on macOS and Linux only, not %s", goos)
	}
}

func UnitPath(target OS, home string) (string, error) {
	switch target {
	case Darwin:
		return filepath.Join(home, "Library", "LaunchAgents", launchdLabel+".plist"), nil
	case Linux:
		return filepath.Join(home, ".config", "systemd", "user", systemdUnit), nil
	default:
		return "", fmt.Errorf("unsupported service target %q", target)
	}
}

type Command struct {
	Name string
	Args []string
}

func (c Command) String() string {
	return strings.Join(append([]string{c.Name}, c.Args...), " ")
}

type Runner interface {
	Run(ctx context.Context, c Command) error
}

// ExitError is a command that ran and exited non-zero, as opposed to one that could not start.
type ExitError struct {
	Command Command
	Code    int
	Output  string
}

func (e *ExitError) Error() string {
	return fmt.Sprintf("`%s` exited with status %d: %s", e.Command, e.Code, strings.TrimSpace(e.Output))
}

type ExecRunner struct{}

func (ExecRunner) Run(ctx context.Context, c Command) error {
	output, err := exec.CommandContext(ctx, c.Name, c.Args...).CombinedOutput()
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return &ExitError{Command: c, Code: exitErr.ExitCode(), Output: string(output)}
	}
	if err != nil {
		return fmt.Errorf("running `%s`: %w", c, err)
	}
	return nil
}

type Installer struct {
	Home   string
	UID    int
	Runner Runner
}

// Result tells the user what happened and what to do next; the CLI decides how to show it.
type Result struct {
	UnitPath string
	Notes    []string
}

// Install writes the unit for target and starts the service, replacing a unit it wrote earlier.
func (in Installer) Install(ctx context.Context, target OS, paths Paths) (Result, error) {
	unitPath, err := UnitPath(target, in.Home)
	if err != nil {
		return Result{}, err
	}
	content, err := render(target, paths)
	if err != nil {
		return Result{}, err
	}
	if info, err := os.Stat(paths.Binary); err != nil {
		return Result{}, fmt.Errorf("the service would run %s: %w", paths.Binary, err)
	} else if info.IsDir() {
		return Result{}, fmt.Errorf("the service would run %s, which is a directory", paths.Binary)
	}
	replacing, err := managedFileExists(unitPath)
	if err != nil {
		return Result{}, err
	}
	if err := os.MkdirAll(paths.StateDir, 0o700); err != nil {
		return Result{}, err
	}
	if err := os.MkdirAll(filepath.Dir(unitPath), 0o755); err != nil {
		return Result{}, err
	}
	if err := os.WriteFile(unitPath, []byte(content), 0o644); err != nil {
		return Result{}, err
	}

	switch target {
	case Darwin:
		return in.loadLaunchd(ctx, unitPath, paths)
	default:
		return in.enableSystemd(ctx, unitPath, replacing)
	}
}

// Uninstall stops the service and removes its unit; it leaves the binary, config and state alone.
func (in Installer) Uninstall(ctx context.Context, target OS) (Result, error) {
	unitPath, err := UnitPath(target, in.Home)
	if err != nil {
		return Result{}, err
	}
	present, err := managedFileExists(unitPath)
	if err != nil {
		return Result{}, err
	}

	switch target {
	case Darwin:
		loaded, err := in.launchdLoaded(ctx)
		if err != nil {
			return Result{}, err
		}
		if loaded {
			if err := in.Runner.Run(ctx, launchctl("bootout", in.serviceTarget())); err != nil {
				return Result{}, err
			}
		}
		if !present && !loaded {
			return notInstalled(unitPath), nil
		}
	default:
		if !present {
			return notInstalled(unitPath), nil
		}
		if err := in.Runner.Run(ctx, systemctl("disable", "--now", systemdUnit)); err != nil {
			return Result{}, err
		}
	}

	if present {
		if err := os.Remove(unitPath); err != nil {
			return Result{}, err
		}
	}
	if target == Linux {
		if err := in.Runner.Run(ctx, systemctl("daemon-reload")); err != nil {
			return Result{}, err
		}
	}
	return Result{UnitPath: unitPath, Notes: []string{
		"minis-hostd is stopped and will not start again. The binary, config and state in ~/.minis are untouched; delete ~/.minis/bin/minis-hostd and ~/.minis/hostd to remove everything.",
	}}, nil
}

func (in Installer) loadLaunchd(ctx context.Context, plistPath string, paths Paths) (Result, error) {
	loaded, err := in.launchdLoaded(ctx)
	if err != nil {
		return Result{}, err
	}
	// bootstrap refuses a label that is already loaded, and a loaded agent keeps its old plist.
	if loaded {
		if err := in.Runner.Run(ctx, launchctl("bootout", in.serviceTarget())); err != nil {
			return Result{}, err
		}
	}
	for _, c := range []Command{
		launchctl("bootstrap", in.domain(), plistPath),
		launchctl("kickstart", "-k", in.serviceTarget()),
	} {
		if err := in.Runner.Run(ctx, c); err != nil {
			return Result{}, err
		}
	}
	return Result{UnitPath: plistPath, Notes: []string{
		"minis-hostd runs now and at every login.",
		"Check it with: launchctl print " + in.serviceTarget(),
		"Its log is " + paths.LogFile,
	}}, nil
}

func (in Installer) enableSystemd(ctx context.Context, unitPath string, replacing bool) (Result, error) {
	commands := []Command{
		systemctl("daemon-reload"),
		systemctl("enable", "--now", systemdUnit),
	}
	// enable --now leaves a running service on the old binary and unit.
	if replacing {
		commands = append(commands, systemctl("restart", systemdUnit))
	}
	for _, c := range commands {
		if err := in.Runner.Run(ctx, c); err != nil {
			return Result{}, err
		}
	}
	return Result{UnitPath: unitPath, Notes: []string{
		"minis-hostd runs now and at every login.",
		"systemd stops user services at logout unless lingering is on; to keep minis-hostd running, run: loginctl enable-linger \"$USER\"",
		"Check it with: systemctl --user status " + systemdUnit,
		"Its log is in the journal: journalctl --user -u " + systemdUnit,
	}}, nil
}

// launchdLoaded treats a non-zero exit of `launchctl print` as "not loaded", but stops when
// launchctl itself cannot run, since every later step would fail the same way.
func (in Installer) launchdLoaded(ctx context.Context) (bool, error) {
	err := in.Runner.Run(ctx, launchctl("print", in.serviceTarget()))
	var exitErr *ExitError
	if errors.As(err, &exitErr) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

func (in Installer) domain() string {
	return fmt.Sprintf("gui/%d", in.UID)
}

func (in Installer) serviceTarget() string {
	return in.domain() + "/" + launchdLabel
}

func launchctl(args ...string) Command {
	return Command{Name: "launchctl", Args: args}
}

func systemctl(args ...string) Command {
	return Command{Name: "systemctl", Args: append([]string{"--user"}, args...)}
}

func render(target OS, paths Paths) (string, error) {
	switch target {
	case Darwin:
		return LaunchdPlist(paths), nil
	case Linux:
		if err := checkSystemdPaths(paths); err != nil {
			return "", err
		}
		return SystemdUnit(paths), nil
	default:
		return "", fmt.Errorf("unsupported service target %q", target)
	}
}

// managedFileExists reports whether path holds a unit this package wrote, and fails on a file
// someone else wrote so it is never replaced or deleted.
func managedFileExists(path string) (bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !strings.Contains(string(data), Marker) {
		return false, fmt.Errorf("%s: %w; move it away or remove it yourself, then try again", path, ErrNotManaged)
	}
	return true, nil
}

func notInstalled(unitPath string) Result {
	return Result{UnitPath: unitPath, Notes: []string{"minis-hostd is not installed as a service; nothing to remove."}}
}
