package service

import (
	"encoding/xml"
	"strings"
)

func LaunchdPlist(p Paths) string {
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- ` + Marker + " Written by `minis-hostd install-service`, removed by `minis-hostd uninstall-service`. -->" + `
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>` + launchdLabel + `</string>
	<key>ProgramArguments</key>
	<array>
		<string>` + xmlText(p.Binary) + `</string>
		<string>run</string>
	</array>
	<key>WorkingDirectory</key>
	<string>` + xmlText(p.StateDir) + `</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>` + xmlText(p.LogFile) + `</string>
	<key>StandardErrorPath</key>
	<string>` + xmlText(p.LogFile) + `</string>
</dict>
</plist>
`
}

func xmlText(s string) string {
	var b strings.Builder
	// EscapeText only fails when the writer does; a strings.Builder never does.
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}
