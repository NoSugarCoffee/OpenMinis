package main

import (
	"os"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/cli"
)

// version is set at release time with -ldflags "-X main.version=<tag>".
var version = "dev"

func main() {
	os.Exit(cli.Run(cli.Env{Version: version, Stdout: os.Stdout, Stderr: os.Stderr}, os.Args[1:]))
}
