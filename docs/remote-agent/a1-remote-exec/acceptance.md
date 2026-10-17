# A1 acceptance

Status: implementation complete and reviewed (package: 260 tests passing against an sshd container; app
builds for device). **Nothing below has run on a device yet.** The app's `MinisTests` target does not
build at the base commit (upstream: `MinisTests/Standalone/` scripts and `ContextPolicy.swift`), so the
app-side tests are compiled only.

## Before merge

1. **Pin upstream's permission key format.** Add a `#filePath` test, in the style of
   `FileToolDriftTests`, that fails if `Agent/Offload/OffloadPermissionManager.swift` stops using
   `"offloadPermission.\(command)"`. A silent rename would reset every host's stored level to Ask Once.
2. **Close the claim/launch race.** Make claim and launch exclusive with an atomic
   `mkdir "$R/started"`. Otherwise, reword spec §4 ("a call reported as not run never starts later")
   and record the window there.
3. **Test the launch-recovery wiring.** Add a fixture test that drives `RemoteExecutor.run` into
   `recoverUnconfirmedLaunch`, cancelling while the launch exec is in flight.
4. **Fix the app test target.** It needs the upstream `MinisTests` build fix, then a device run of
   `RemoteToolBridgeTests`, `RemoteOffloadBridgeTests` and `RemoteHostSetupTests`.
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
