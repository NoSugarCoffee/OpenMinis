package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/cli"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/service"
)

// version is set at release time with -ldflags "-X main.version=<tag>".
var version = "dev"

func main() {
	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "minis-hostd: cannot find the home directory: %v\n", err)
		os.Exit(cli.ExitError)
	}
	os.Exit(cli.Run(cli.Env{
		Version:  version,
		Stdout:   os.Stdout,
		Stderr:   os.Stderr,
		StateDir: filepath.Join(home, ".minis", "hostd"),
		Now:      time.Now,
		Setup:    cli.Setup{Home: home, GOOS: runtime.GOOS, UID: os.Getuid(), Runner: service.ExecRunner{}},
	}, os.Args[1:]))
}
