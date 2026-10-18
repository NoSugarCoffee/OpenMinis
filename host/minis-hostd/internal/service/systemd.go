package service

import (
	"fmt"
	"strings"
)

func SystemdUnit(p Paths) string {
	return "# " + Marker + " Written by `minis-hostd install-service`, removed by `minis-hostd uninstall-service`.\n" +
		`[Unit]
Description=minis-hostd: pushes mail and GitHub notices to Minis

[Service]
Type=simple
ExecStart=` + p.Binary + ` run
WorkingDirectory=` + p.StateDir + `
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
`
}

// systemdSpecial are characters systemd would treat as specifiers, quoting, escapes or word
// breaks in ExecStart; rejecting them is simpler and safer than escaping for a home directory
// that practically never contains them.
const systemdSpecial = "%$\"'\\ \t\n;"

func checkSystemdPaths(p Paths) error {
	for _, path := range []string{p.Binary, p.StateDir} {
		if strings.ContainsAny(path, systemdSpecial) {
			return fmt.Errorf("%q contains a space or one of %q, which a systemd unit cannot hold unescaped", path, systemdSpecial)
		}
	}
	return nil
}
