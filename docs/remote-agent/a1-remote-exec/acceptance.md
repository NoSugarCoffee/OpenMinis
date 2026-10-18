# A1 acceptance

Status: implementation complete and reviewed (package: 269 tests passing against an sshd container; app
builds for device; the 36 app-side Remote tests pass in the iOS Simulator). **Nothing below has run on
a device yet.**

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
5. **History.** Squash the series into logical commits and retarget the PR to the `fork` branch. Some
   early commits carry a "Claude Sonnet 5.5" trailer.

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
