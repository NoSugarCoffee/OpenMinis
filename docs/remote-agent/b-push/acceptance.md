# B acceptance

Status: host side accepted on the Mac mini (2026-10-19); the app side on the iPhone is pending.
`minis-hostd` runs there as a launchd service watching the user's Gmail and GitHub.

Each item names the evidence. Spec sections are in [`spec.md`](spec.md).

## Host side (done)

| # | Check | Result |
|---|---|---|
| 1 | Mail from an allowed sender reaches the iPhone within 60 s | **Pass.** A test mail produced an encrypted Bark push about 21 s after sending (§13.1), through the real daemon in an isolated home, then again from the service config. |
| 2 | Mail stays unread and untouched | **Pass.** `BODY.PEEK[]` left the message unseen (S1); the IMAP source opens INBOX with `EXAMINE`, and its test server fails on any `STORE`, `COPY`, `MOVE`, `EXPUNGE` or non-peek fetch. |
| 3 | Newsletters and automated mail never push | **Pass in tests** (gate fixtures: `List-Unsubscribe`, `Precedence`, `Auto-Submitted`, noreply). With `pattern = "*"` on the user's account they are still dropped. |
| 4 | A backlog never pushes on install | **Pass.** The first GitHub poll returned 78 unread notifications back to July; all were stored only. The 48-hour limit added afterwards (PR #27) covers kept reasons too. |
| 5 | Bark never receives plaintext | **Pass.** Requests carry only `ciphertext` and `iv`; a fresh IV per push; the key alphabet avoids look-alikes (§7.1). |
| 6 | A GitHub notification is pushed at most once across a restart | **Pass in tests** (`TestCrashBetweenCommitAndSendDoesNotPushTwice`); the service has been restarted three times by launchd with no duplicate. |
| 7 | The same binary runs on macOS and Linux | **Pass.** Static `CGO_ENABLED=0` builds; the CLI contract ran over SSH on macOS and Alpine (S4). |
| 8 | Runs unattended | **Pass.** launchd service since 2026-10-19 09:17; seven hours later both sources `ok`, no warnings in `hostd.log`. |

## App side (pending: the new Minis is not on the iPhone yet)

A free Apple ID cannot use upstream's bundle id or App Group, so the device build comes from
`scripts/ios-personal-device.sh`. Its last run registered the four bundle ids under the user's team,
then stopped because the App Group `group.com.nosugarcoffee.minis` is not registered: command-line
signing does not register App Groups, so it needs one pass in Xcode's Signing & Capabilities (see
the script's header).

| # | Check | Result |
|---|---|---|
| 9 | Tapping a push opens Minis on a read-only session, from the home screen and from a cold start | Pending |
| 10 | The session shows a summary and offers only `file_read`, `read_image`, `memory_get` | Pending (unit tests pass in the Simulator) |
| 11 | "Turn Tools On" asks first and affects that session only | Pending |
| 12 | Settings → Remote Hosts → mac-mini → Notifications shows status and recent events | Pending |
| 13 | A batch push opens one session with all its events | Pending |

Items 9–13 run together with A1's device checklist.
