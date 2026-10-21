# B acceptance

Status: host side accepted on the Mac mini (2026-10-19); app side checked on the iPhone (2026-10-21/22): 9–12 pass; 13 passes for the app, with a batch written by hand.
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

## App side (2026-10-21)

Pico (the fork, D22) on the iPhone 17, built by `scripts/ios-personal-device.sh` under the paid
team, next to an upstream Minis 1.15; minis-hostd 0.2.1 on the Mac mini. The `pico://host-event`
links were first opened with iCTRL's `open_url`, the link a Bark push carries. On 2026-10-22 real Bark
pushes were tapped: the events behind them were written into `state.db` by hand (key `mock:…`,
reason `mock_for_acceptance`, sender `mock@example.invalid`) and sent by the running daemon through
its outbox. Mail sent from the watched Gmail account to itself does not serve: Gmail adds no sender
authentication result to it, so the gate stores it with `sender_unauthenticated` and pushes nothing,
as designed.

| # | Check | Result |
|---|---|---|
| 9 | Tapping a push opens Minis on a read-only session, from the home screen and from a cold start | **Pass.** The link opens the session from a cold start and with the app running, and a tap on a real Bark push (held by Sleep Focus, in Notification Center) opened Bark, which asked once to open Pico, then a read-only session with the summary; the event was acked. Before D22 the `minis://` link opened upstream Minis. Two bugs found and fixed: each open made two sessions (#45), and the name hostd used differed from the app's (#43). On some cold starts the session got no model ("No model configured"): the provider store replaces its whole config when its database loads, dropping a binding made just before. Fixed in #48, which makes the opener wait for that load; two cold-start push taps afterwards both opened with Claude Haiku 5.5 and a summary. |
| 10 | The session shows a summary and offers only `file_read`, `read_image`, `memory_get` | **Pass.** Summary with the PR link and what needs action; asked for its tools, the model listed exactly those three. |
| 11 | "Turn Tools On" asks first and affects that session only | **Pass.** A confirmation explains the risk; afterwards that session listed `shell_execute`, `file_write`, `browser_use` and the rest, and another event session still offered Turn Tools On. |
| 12 | Settings → Remote Hosts → mac-mini → Notifications shows status and recent events | **Pass.** Running, `github` and `mail:personal` green, recent events with their push decision. |
| 13 | A batch push opens one session with all its events | **Pass** for the app: a tap on the "3 new: 3 mail" push opened one session, "3 events from macmini", summarising all three. The batch was written by hand, so hostd's own batching is not shown here (it is covered by the pacing tests). |
