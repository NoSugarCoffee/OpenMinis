# A1 acceptance

Status: implementation complete and reviewed (package: 269 tests passing against an sshd container; app
builds for device; the 36 app-side Remote tests pass in the iOS Simulator). The device run on
2026-10-21 passed everything it covered (results below); a Linux host and items 8, 15, 17 and 18 are
still to run.

## Before merge

1. **Done: pin upstream's permission key format.** `PermissionKeyDriftTests` (package) fails if
   `OffloadPermissionManager.defaultsKey` stops using `"offloadPermission.\(command)"`.
2. **Done: close the claim/launch race.** The launcher and the probe race for an atomic
   `mkdir "$R/started"`; spec §4.1 describes it.
3. **Done: test the launch-recovery wiring.** `testStopWhileTheLaunchExecIsInFlightLeavesNothingRunning`
   stops `RemoteExecutor.run` while the launch exec is in flight.
4. **Done: fix the app test target.** `MinisTests` builds again. `RemoteToolBridgeTests`,
   `RemoteOffloadBridgeTests` and `RemoteHostSetupTests` (36 tests) pass in the iOS 27 Simulator, using
   the Simulator build support on `build/ios-simulator`; the run caught OSStatus codes shown with digit
   grouping. Device-only behavior (Keychain, backgrounding) stays in the device checklist.
5. **Done: history.** The series is 10 logical commits. It merges into `main`, which is the fork's
   trunk (D7) and already carries the design docs, so no separate `fork` branch is needed.

## Device checklist

Run against the Mac mini over Tailscale and against a Linux host. Record device, host OS and
pass/fail for each item.

1. **Bound session:** it edits a repo file, runs a build and the tests, and `gh auth status` succeeds with the host's login.
2. **Backgrounding:** a 10-minute command survives putting the app in the background for 5 minutes, and its output resumes.
3. **Detach:** `detach: true` returns immediately; a later `cat …/exit` shows the code.
4. **Stop:** Stop kills `sleep 600 & sleep 600 & wait` and leaves no process behind.
5. **Changed host key:**
   - It blocks the connection with the warning.
   - Settings → host → Test Connection shows the red mismatch sheet with the new fingerprint.
   - Trust New Key re-pins it.
6. **Local commands:** `apple-calendar` still runs locally, and `minis-remote cp` works both ways.
7. **Linux:** items 1-6 also pass unchanged on the Linux host.

Also on device:

8. **KeychainSecretStore round-trip:**
   - Generate a key and kill the app; relaunch, and the public key must be unchanged.
   - Import a key encrypted with `ssh-keygen -a 16`.
   - Import a default-rounds (24) encrypted key: the error must show the `-a 16` remedy.
   - Remove the host; its key must be deleted.
9. **Setup flow:**
   - Add a host, copy the install command, and run it on the host.
   - Test Connection: the trust sheet shows the same `SHA256:` value as `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the host.
   - After Trust there are four check rows.
   - The host's OS appears under Connection and in the system prompt line.
10. **Permission prompt for a host:**
    - A new host defaults to Ask Once, and the first tool call in a session prompts.
    - Switching to Not Allowed in Settings → Remote Hosts → Permissions blocks the call. Bypass runs it without asking.
11. **`minis-remote cp` through the guest shell (iSH):** both directions, including a path with a space.
12. **Stop from the card:** stopping a remote run from its card cancels it on the host (exit file `cancelled`) and the result says cancelled.
13. **Sub-agent:** a sub-agent of a bound session runs on the parent's host and directory, with no second permission prompt.
14. **Session binding UI:**
    - The chat "…" menu row reads "Remote Host" when unbound and the host name when bound.
    - The folder browser works, and recent directories are listed first.
    - "This iPhone" unbinds the session.
    - A draft chat bound before its first message keeps the binding after sending.
15. **Corrupt `remote-hosts.json`:**
    - Write garbage to `Application Support/remote-hosts.json`; a tool call returns the Settings → Remote Hosts message.
    - The Settings screen shows the error. Reset leaves `remote-hosts.json.unreadable-<UTC time>` beside it and an empty list.
16. **Address edit after a failed trust:** the pending prompt disappears, and Test Connection shows
    the new endpoint's fingerprint.
17. **Choosing a key file:** its contents are never visible on screen.
18. **Stop during connect:** cancelling while a cold host is still connecting starts nothing on the
    host.

## Device results (2026-10-21)

iPhone 17 on iOS 27 (build from `main` at `8a4c9c8`, paid team) over 4G and Tailscale to the Mac mini
(macOS 27, `light@100.81.208.83`), host added by scan pairing. Model: Claude Haiku 5.5 through
OpenRouter. Driven with iCTRL; screenshots kept out of the repo.

| # | Result |
|---|---|
| 1 | **Pass**, except `gh auth status`. The agent copied `host/minis-hostd` to `/tmp`, edited a Go file, and `go build ./...` and `go test ./internal/pairing/` passed. `gh auth status` failed with "token invalid": gh keeps the token in the login keychain, which an SSH session cannot read. Host fix: `gh auth login --insecure-storage`, or `GH_TOKEN` for the SSH shell. |
| 2 | **Pass.** A 600-second loop kept running on the host through 5 minutes in the background (tick 328 when checked); back in the app the card resumed at tick 420 and the turn ended with `tick 600`, exit 0. Upstream's "Background Task Interrupted" banner showed on return; the remote run was not affected. |
| 3 | **Pass.** `detach: true` returned at once; reading the exit file later gave 0 and "done". |
| 4 | **Pass.** Stop on `sleep 600 & sleep 600 & wait` left no `sleep 600` process on the host. |
| 5 | **Pass**, against a second sshd (user-run, port 2222) whose host key was replaced after trusting it: the tool call was refused with the new fingerprint, Test Connection showed the red mismatch sheet, and Trust New Key re-pinned it. The sheet opens at half height with Trust New Key below the fold; it shows after dragging the sheet up. |
| 6 | **Pass.** `apple-calendar` ran on the iPhone (the iOS Calendar prompt appeared; access left at None). `minis-remote hosts` listed macmini as reachable, and `minis-remote cp` copied a file host → phone and back, intact. |
| 7 | Not run: no Linux host yet. |
| 8 | Not run. The key made at pairing survived reinstalling the app. |
| 9 | **Pass** through scan pairing ([pairing spec](../pairing/spec.md)): the pinned `SHA256:M8TxWVZ9…` matches `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`, there are four check rows, and the OS reads Darwin. Long fingerprints wrap with a hyphen that is not part of the value (`…VM-Tygft…`). |
| 10 | **Pass.** Ask Once prompted on the first call (an unanswered prompt returns "declined or did not answer in time" after about 30 s); Not Allowed blocked the call; Bypass ran without a prompt. |
| 11 | **Pass** for both directions with spaces in the paths (`/tmp/acc dir/from mac.txt`, `/var/minis/shared/acc copy.txt`). |
| 12 | **Pass.** Stopping from the card left the exit file at `cancelled` and the card said cancelled. |
| 13 | **Pass**: the sub-agent ran `hostname` and `pwd` on macmini in the parent's directory. Run under Bypass, so the "no second prompt" part is not shown. |
| 14 | **Pass.** The menu row read "Remote Host" unbound and "macmini" bound; the folder browser listed recent directories first and Go to path worked; a draft chat bound before its first message kept the binding. |
| 15 | Not run. |
| 16 | **Pass.** After changing the port, Test Connection offered the new endpoint's fingerprint for trust. |
| 17 | Not run. |
| 18 | Not run. |

Also seen:

- A Settings link in an agent reply ("Settings → Remote Hosts → macmini") opens the top of Settings,
  not the host page.
