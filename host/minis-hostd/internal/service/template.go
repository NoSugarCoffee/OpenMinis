package service

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/config"
)

// hostNamePattern repeats config's rule so a bad name fails here, before it is pasted into TOML.
var hostNamePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,32}$`)

// NewConfigTemplate returns a config.toml that parses as TOML but fails validation with
// "nothing to watch" until the user turns on a mail account or GitHub.
func NewConfigTemplate(hostName, barkKey string) (string, error) {
	if !hostNamePattern.MatchString(hostName) {
		return "", fmt.Errorf("host name %q must be the host's name in Minis: 1 to 32 letters, digits, '-' or '_'", hostName)
	}
	if err := checkBarkKey(barkKey); err != nil {
		return "", err
	}
	return strings.NewReplacer("{{host_name}}", hostName, "{{encryption_key}}", barkKey).Replace(configTemplate), nil
}

func checkBarkKey(key string) error {
	if len(key) != config.BarkKeyLength {
		return fmt.Errorf("bark key must be %d characters, got %d", config.BarkKeyLength, len(key))
	}
	for _, r := range key {
		if !strings.ContainsRune(config.BarkKeyAlphabet, r) {
			return fmt.Errorf("bark key has %q, which is not one of %q", r, config.BarkKeyAlphabet)
		}
	}
	return nil
}

// WriteConfigTemplate creates path with mode 0600 and never replaces an existing file, because
// that file holds the user's passwords and keys.
func WriteConfigTemplate(path, content string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, os.ErrExist) {
		return fmt.Errorf("%s already exists; edit it instead, or move it away to start over: %w", path, err)
	}
	if err != nil {
		return err
	}
	if _, err := file.WriteString(content); err != nil {
		_ = file.Close()
		return fmt.Errorf("writing %s: %w", path, err)
	}
	return file.Close()
}

const configTemplate = `# minis-hostd configuration (~/.minis/hostd/config.toml).
#
# This file holds passwords and keys: keep it mode 0600 (minis-hostd refuses to read it otherwise).
# Turn on at least one [[mail]] account or the [github] section below, fill in the Bark device key,
# then run: minis-hostd doctor --push-test
# A line starting with "#" is off; remove the leading "# " to turn a setting on.

# The host's name exactly as it appears in Minis (Settings > Remote Hosts). Notices link back to
# this host by name.
host_name = "{{host_name}}"

# IANA time zone used for quiet hours and the daily cap. Unset means the system time zone.
# timezone = "Europe/Berlin"

# Quiet hours: during this daily span notices are stored but not pushed. A start later than the
# end wraps past midnight. Remove the section to push at any time.
# [quiet_hours]
# start = "22:00"
# end = "07:30"

# A Gmail account watched over IMAP. Copy the whole block for each further account.
#   name                a label for this account: 1 to 32 letters, digits, '-' or '_', unique
#   address             the Gmail address
#   app_password        a Google app password (Google Account > Security > App passwords),
#                       not your account password
#   gmail_primary_only  true to push only mail Gmail puts in the Primary category
# Each [[mail.allow]] entry lets one sender push; mail from anyone else is only stored.
#   pattern             an address (alice@example.com) or a whole domain (@example.org)
#   require_dmarc       default true: push only when the sender's domain passes DMARC, so a forged
#                       From cannot push; set false for senders whose domain has no DMARC
# [[mail]]
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
# require_dmarc = false

# GitHub notifications, polled with your token.
#   token    a classic personal access token with only the "notifications" scope
#   reasons  notification reasons that push; unset means
#            ["mention", "team_mention", "review_requested", "assign", "ci_activity"]
#   repos    only these repositories push, as "owner/name" or "owner/*"; unset means all
# [github]
# token = "ghp_..."
# repos = ["owner/name", "owner/*"]

# Bark delivers the push to your iPhone, end-to-end encrypted.
#   server          your Bark server; unset means https://api.day.app
#   device_key      the key shown on the Bark app's home screen
#   encryption_key  generated for this host; in the Bark app open Push Encryption, choose
#                   AES256, GCM, noPadding, and type this key exactly
[bark]
# server = "https://api.day.app"
device_key = ""
encryption_key = "{{encryption_key}}"
`
