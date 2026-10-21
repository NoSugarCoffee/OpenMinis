package cli

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"time"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/notify"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/service"
)

// Setup holds what the setup commands touch on the host; tests swap in a temp home and a fake runner.
type Setup struct {
	Home   string
	GOOS   string
	UID    int
	Runner service.Runner
}

// The setup commands are run by a person in a terminal (or by install.sh), never by the app, so
// they print plain text instead of the JSON line the app reads.
func plain(env Env, lines ...string) int {
	for _, line := range lines {
		fmt.Fprintln(env.Stdout, line)
	}
	return ExitOK
}

func plainFail(env Env, message string) int {
	fmt.Fprintf(env.Stderr, "minis-hostd: %s\n", message)
	return ExitError
}

func runNewConfig(env Env, args []string) int {
	if len(args) != 2 || args[0] != "--host-name" {
		return plainFail(env, "usage: minis-hostd new-config --host-name <name in Minis>")
	}
	paths := service.DefaultPaths(env.Setup.Home)
	text, err := service.NewConfigTemplate(args[1], notify.GenerateKey())
	if err != nil {
		return plainFail(env, err.Error())
	}
	if err := service.WriteConfigTemplate(paths.Config, text); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return plainFail(env, fmt.Sprintf("%s already exists; edit it instead", paths.Config))
		}
		return plainFail(env, err.Error())
	}
	return plain(env, "Wrote "+paths.Config+" (mode 600).")
}

func runInstallService(env Env, args []string) int {
	if len(args) != 0 {
		return plainFail(env, "usage: minis-hostd install-service")
	}
	paths := service.DefaultPaths(env.Setup.Home)
	// Installing a daemon whose config cannot load would only make launchd or systemd restart it
	// every few seconds; refuse until the config is complete.
	if _, err := config.Load(paths.Config); err != nil {
		return plainFail(env, fmt.Sprintf("%v\nFix the config, then run `minis-hostd install-service` again.", err))
	}
	target, err := service.TargetForGOOS(env.Setup.GOOS)
	if err != nil {
		return plainFail(env, err.Error())
	}
	installer := service.Installer{Home: env.Setup.Home, UID: env.Setup.UID, Runner: env.Setup.Runner, Pause: time.Sleep}
	result, err := installer.Install(context.Background(), target, paths)
	if err != nil {
		return plainFail(env, err.Error())
	}
	return plain(env, append([]string{"Installed " + result.UnitPath + "."}, result.Notes...)...)
}

func runUninstallService(env Env, args []string) int {
	if len(args) != 0 {
		return plainFail(env, "usage: minis-hostd uninstall-service")
	}
	target, err := service.TargetForGOOS(env.Setup.GOOS)
	if err != nil {
		return plainFail(env, err.Error())
	}
	installer := service.Installer{Home: env.Setup.Home, UID: env.Setup.UID, Runner: env.Setup.Runner, Pause: time.Sleep}
	result, err := installer.Uninstall(context.Background(), target)
	if err != nil {
		return plainFail(env, err.Error())
	}
	return plain(env, append([]string{"Removed " + result.UnitPath + "."}, result.Notes...)...)
}
