# minis-hostd

A small daemon that runs on a host you reach from Minis over SSH. It watches Gmail (IMAP) and
GitHub notifications, keeps the events that matter in a local store, and sends an end-to-end
encrypted push through [Bark](https://github.com/Finb/Bark). Tapping the push opens the event in
Minis, which reads it from the host over SSH. The design is in
[`docs/remote-agent/b-push/spec.md`](../../docs/remote-agent/b-push/spec.md).

One static binary runs on macOS and Linux, arm64 and amd64.

## Pair with Minis

To add this computer in Minis without copying keys, run on it, as the user Minis should log in as:

```sh
curl -fsSL https://raw.githubusercontent.com/NoSugarCoffee/OpenMinis/main/host/minis-hostd/scripts/install.sh \
  | sh -s -- --pair --version <version>
```

This installs only the binary, then runs `minis-hostd pair`, which prints a QR code. In Minis, open
Settings > Remote Hosts > Add Host and scan it. With the binary already installed, run
`~/.minis/bin/minis-hostd pair [--name <name>] [--ssh-port <port>]` directly.

The code carries the computer's SSH host key, so Minis trusts it without asking you to compare a
fingerprint, and a one-time secret. Minis uses the secret to send the phone's public key to a
pairing port that `pair` opens for at most 5 minutes and one phone; `pair` then adds the key to
`~/.ssh/authorized_keys`. It needs Remote Login (macOS) or sshd (Linux) on, an Ed25519 host key in
`/etc/ssh/ssh_host_ed25519_key.pub`, and a Tailscale or private network address. The protocol is
in [`docs/remote-agent/pairing/spec.md`](../../docs/remote-agent/pairing/spec.md).

## Install

Minis shows the install command under Settings > Remote Hosts > *host* > Notifications. It looks
like this; run it on the host as the user who owns the SSH login Minis uses:

```sh
curl -fsSL https://raw.githubusercontent.com/NoSugarCoffee/OpenMinis/main/host/minis-hostd/scripts/install.sh \
  | sh -s -- --host-name mac-mini --version 0.1.0
```

`--host-name` must match the host's name in Minis. The script:

1. picks the release asset for `uname -s` / `uname -m`, downloads it and `SHA256SUMS` from the
   GitHub release `hostd-v<version>`, and stops if the checksum does not match;
2. installs the binary to `~/.minis/bin/minis-hostd`;
3. runs `minis-hostd new-config --host-name <name>` when `~/.minis/hostd/config.toml` does not
   exist yet, which writes a commented template (mode 0600) with a freshly generated Bark
   encryption key;
4. runs `minis-hostd install-service`.

Running it again with a newer `--version` upgrades the binary, keeps the config and restarts the
service.

Then:

1. Edit `~/.minis/hostd/config.toml` (see below).
2. In the Bark app, open Push Encryption, choose AES256, GCM, noPadding, and type the
   `encryption_key` from the config exactly.
3. Run `~/.minis/bin/minis-hostd doctor --push-test`. It checks the logins, the clock and the time
   zone, and sends an encrypted test push to your iPhone.

On Linux, systemd stops user services when you log out. To keep minis-hostd running, enable
lingering once: `loginctl enable-linger "$USER"`.

## Configuration

`~/.minis/hostd/config.toml` holds passwords and keys, so minis-hostd refuses to read it unless
its mode is 0600. The template documents every field; in short:

| Setting | Meaning |
|---|---|
| `host_name` | The host's name in Minis; notices link back to it. 1 to 32 letters, digits, `-`, `_`. |
| `timezone` | IANA zone for quiet hours and the daily cap, such as `Europe/Berlin`. Default: the system zone. |
| `[quiet_hours]` `start`, `end` | `HH:MM`. Notices in this span are stored but not pushed. Start after end wraps past midnight. |
| `[[mail]]` `name` | A label for the account, unique. |
| `[[mail]]` `address`, `app_password` | The Gmail address and a Google app password (not the account password). |
| `[[mail]]` `gmail_primary_only` | `true` pushes only mail in Gmail's Primary category. |
| `[[mail.allow]]` `pattern` | A sender allowed to push: `alice@example.com` or a whole domain `@example.org`. Other mail is only stored. |
| `[[mail.allow]]` `require_dmarc` | Default `true`: the sender's domain must pass DMARC, so a forged From cannot push. |
| `[github]` `token` | A classic token with only the `notifications` scope. |
| `[github]` `reasons` | Notification reasons that push. Default: `mention`, `team_mention`, `review_requested`, `assign`, `ci_activity`. |
| `[github]` `repos` | Only these repositories push: `owner/name` or `owner/*`. Default: all. |
| `[bark]` `server` | Your Bark server. Default: `https://api.day.app`. |
| `[bark]` `device_key` | The key on the Bark app's home screen. |
| `[bark]` `encryption_key` | 32 characters from `abcdefghjkmnpqrstuvwxyz23456789`, entered in Bark as above. |

At least one `[[mail]]` account or the `[github]` section is required; until one is turned on,
minis-hostd reports "nothing to watch".

## Files

| Path | What |
|---|---|
| `~/.minis/bin/minis-hostd` | The binary. |
| `~/.minis/hostd/config.toml` | Configuration, mode 0600. |
| `~/.minis/hostd/state.db` | SQLite store: cursors, events, the push outbox, the heartbeat. |
| `~/.minis/hostd/hostd.log` | Daemon output on macOS. On Linux it goes to the journal: `journalctl --user -u minis-hostd`. |
| `~/Library/LaunchAgents/app.minis.hostd.plist` | The launchd agent (macOS). |
| `~/.config/systemd/user/minis-hostd.service` | The systemd user unit (Linux). |

`install-service` and `uninstall-service` only touch a unit file that carries the line
`Managed by minis-hostd.`; they refuse to overwrite or remove one you wrote yourself.

Check the service with `launchctl print gui/$(id -u)/app.minis.hostd` on macOS or
`systemctl --user status minis-hostd` on Linux.

## Uninstall

```sh
~/.minis/bin/minis-hostd uninstall-service
rm -rf ~/.minis/bin/minis-hostd ~/.minis/hostd
```

The first command stops the service and removes its unit file; the second removes the binary, the
config and the stored events.

## Building a release

```sh
host/minis-hostd/scripts/release.sh 0.1.0
```

This builds the four targets with `CGO_ENABLED=0` into `host/minis-hostd/dist/` as
`minis-hostd-<version>-<os>-<arch>` and writes `dist/SHA256SUMS`. Upload all five files to a GitHub
release tagged `hostd-v<version>`. Set `GO=/path/to/go` if `go` is not on `PATH`.
