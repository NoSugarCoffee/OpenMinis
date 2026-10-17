# Remote host A1 — native SSH remote execution

Date: 2026-10-16. Status: spec approved 2026-10-16; verification done (§10); implementation plan next.
Scope: iOS only, fork only (never upstreamed). Android is deferred.

Part of [`../README.md`](../README.md); decisions are in [`../decisions.md`](../decisions.md).
Implementation plan: [`plan.md`](plan.md).

## 1. Goal and context

The user needs an always-on real computer the agent can work on. The on-device iSH sandbox is
x86-emulated, slow, has none of the user's logged-in state, and dies when iOS suspends the app.

Sub-project A delivers that computer in three milestones:

| Milestone | Content |
|---|---|
| **A1 (this spec)** | SSH connection, binding a session to a host, background runs with reconnect, SFTP file tools, device commands kept local |
| A2 | Browser login state through CDP to the user's everyday Chrome, screenshot → `read_image`, a screen-operation skill for macOS and Linux |
| A3 | In-app VNC viewer tunnelled over SSH, "take over / hand back", an operation lock that pauses the agent |

Sub-project B (`minis-hostd`, email and GitHub push) builds on A1.

**Use cases in priority order** (from the user): (a) coding in git repos on the host, (b) long
scripts and tasks, (d) using the host's network and environment, (c) administering the host.

**Success for A1**: in a session bound to the user's Mac mini (over Tailscale), the agent edits
code, runs builds and tests that outlive app suspension, and uses the host's logged-in CLIs
(`gh`, git credentials). The same app works unchanged against a Linux host.

## 2. Principles

- **Host-agnostic.** A host is anything reachable over SSH with POSIX `sh`. Nothing is installed
  on the host for A1, and nothing may depend on macOS-only behaviour.
- **Never fall back silently.** A command meant for the host is never run locally. Every failure is
  reported with a reason and a next step.
- **The brain stays in Minis.** The agent loop and model keys stay on the phone; the host executes.
- **Fork hygiene.** New code lives in `src/ios/Agent/Remote/`. Edits to upstream files are limited
  to the three integration points in §3.3 and marked `// fork(remote-host):`.

## 3. Architecture

### 3.1 Components

```
Minis (iOS)
 ├─ RemoteHostStore      host configs: name, address, port, user, key ref, pinned host key
 ├─ SSHConnectionPool    one long-lived connection per host; reconnect on foreground/network change
 ├─ RemoteExecutor       background runs: start → run id; attach by run id; read by offset; cancel
 ├─ RemoteFileService    SFTP read / atomic write / edit with conflict check
 ├─ SessionHostBinding   session → (host, working directory); chat-header chip to switch
 └─ minis-remote         new device command: cp between local and host, hosts list

Host: sshd + POSIX sh only
 ~/.minis/runs/<id>/{cmd, out, exit, pid}
```

Every unit is a small type with one job. Decision logic (routing, path resolution, script
generation, exit-status classification, conflict detection) is written as pure functions, so it can
be tested without a network.

### 3.2 Routing

When a session is bound to a host, each `shell_execute`, `file_read`, `file_write` and
`file_edit` call is routed by the first matching rule:

| # | Condition | Destination |
|---|---|---|
| 1 | The call carries an explicit `target` (`"local"` or a host name) | That target |
| 2 | `shell_execute` whose first token is a registered device command (`OffloadPermissionManager.extractOffloadCommand`, `Agent/Offload/OffloadPermissionManager.swift:210`) | Local iSH |
| 3 | A file path starting with `/var/minis/` or `minis://` | Local |
| 4 | Anything else | The bound host |

Unbound sessions behave exactly as today. A `target` naming an unknown host is an error, not a
fallback.

Device commands combined with host commands in one line (`cd x && apple-calendar …`) are routed
by their first token, so this example goes to the host and fails there with "command not found".
The system prompt tells the model that the bound host is the default for shell_execute and the
file tools, to leave `target` unset for host work and set `target: "local"` only for the phone's
own `/var/minis` files, and to call device commands on their own. In a bound chat the
`shell_execute` description also says commands run on the host, not in iSH.

### 3.3 Integration points in upstream files

1. **Tool dispatch** (`Agent/Chat/AIChatViewModel+ConcurrentTools.swift`, the `shell_execute` and
   `file_*` cases): one routing call before execution. Remote calls go to `RemoteExecutor` /
   `RemoteFileService`; local calls take the existing path unchanged.
2. **Tool definitions and system prompt** (`Agent/Chat/AIChatViewModel+ToolDefinitions.swift`,
   `AIChatViewModel.swift`):
   - **New parameters:** the optional `target` on the four tools, and the optional `detach` on
     `shell_execute`.
   - **Prompt line:** when a session is bound, one prompt line: "You are working on host
     `<name>` (`<os>`) in `<workdir>`".
3. **UI entry points**: a "Remote hosts" row in Settings and the host chip in the chat header.

## 4. Background runs (long tasks)

### 4.1 Start

One SSH exec per run:

```sh
mkdir -p ~/.minis/runs/$ID && cd "$WORKDIR" || exit 97
printf '%s' "$CMD" > ~/.minis/runs/$ID/cmd
nohup "$SHELL" -lc '( . ~/.minis/runs/'"$ID"'/cmd ); echo $? > ~/.minis/runs/'"$ID"'/exit.tmp; mv ~/.minis/runs/'"$ID"'/exit.tmp ~/.minis/runs/'"$ID"'/exit' \
  </dev/null >~/.minis/runs/$ID/out 2>&1 &
echo $! > ~/.minis/runs/$ID/pid
```

- **No process groups.** `set -m` cannot be relied on: busybox `sh` refuses job control without a
  tty (verified, §10), and macOS has no `setsid`. Cancel walks the process tree instead (§4.5).
- **Survives disconnect:** verified on Linux, both when the SSH session closes normally and when
  the client is killed mid-run (§10).
- **Login shell:** `$SHELL -lc` loads the user's profile, so Homebrew and similar PATH entries
  resolve. A non-interactive SSH session would not load them.
- **Subshell:** the command is sourced inside a subshell `( … )`, so an `exit` in the user's command
  ends only the subshell and the exit code is still recorded.
- **Atomic exit code:** it is written to a temp file and then renamed.
- **No stdin:** stdin is `/dev/null`, so interactive prompts fail immediately. The tool
  description says interactive work belongs in the terminal.
- **Unconfirmed launch:** when the launch exec's reply is lost (stop, timeout, dropped connection),
  one probe of the run directory decides: if `pid` exists the run is followed, or cancelled when the
  user stopped it; otherwise the probe writes `cancelled` to `exit`, and the launcher refuses to start
  a run whose `exit` already exists (exit 95), so a call reported as not run never starts later. A
  probe that cannot reach the host returns the run id as "may still be running". A stop that lands
  while connecting sends nothing.
- The exact script is produced by a pure function and pinned by golden tests. The quoting above is
  illustrative; the implementation must survive commands containing quotes, `$` and newlines,
  which is why the command travels as a file.

### 4.2 Output and completion

- **Polling:** the executor reads `out` by byte offset about once a second over the pooled
  connection, and appends the new output to the live tool card.
- **Completion:** a run finishes when `exit` exists. Its content is an integer exit code or
  `cancelled`.
- **Abnormal termination:** if `exit` is missing and the pid is no longer alive, the run is
  reported as "terminated abnormally", for example after a host reboot.
- **Output limits and redaction:** the same as local `shell_execute`. A truncated result keeps the
  head and tail and names the full output file on the host. Env-var values are redacted.

### 4.3 Timeout and detach

- **Default:** wait for completion. On `timeout` (default 900s, as today), cancel the run as in §4.5.
- **`detach: true`:** return immediately with `run_id`, the output path and the exit path. The
  agent checks progress later with ordinary `shell_execute` calls (`tail`, `cat …/exit`). No
  status tool is added.

### 4.4 Suspension and relaunch

- **Every result starts with the run:** each remote result, including partial ones, begins with
  `run_id` and the output path, so the information persists in the chat history.
- **App suspended:** on return to the foreground, the pool reconnects and the executor resumes
  reading from the stored offset. The host process was never interrupted.
- **App killed:** after relaunch, the run id in the history lets the user or the agent recover the
  output from the host.

### 4.5 Cancel

The stop button, or a timeout, triggers this sequence:
1. Collect the run's process tree from `ps -A -o pid= -o ppid=` (falling back to `ps -o pid= -o ppid=`
   on busybox) by walking children from the recorded pid, save the pids to `~/.minis/runs/<id>/tree`,
   and send `TERM` to every process.
2. After 5s, send `KILL` to the union of the saved pids that still appear in `ps` and a fresh walk
   from the recorded pid (it may have spawned new children). The saved set is needed because a
   process that ignored `TERM` can outlive its parent and is then reparented to init, where a fresh
   walk no longer finds it.
3. Write `cancelled` to `exit`, creating the run directory first if the launch has not made it yet.

The tree walk is a POSIX `sh` + `awk` snippet produced by a pure function and pinned by golden
tests. Known limit: a process that daemonises itself (double fork, reparented to init) leaves the
tree and is not cancelled. The tool result says so when a cancel reports surviving output.

### 4.6 Retention

On each new connection, run directories older than 7 days are deleted:
`find ~/.minis/runs -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} +`.

## 5. Files

### 5.1 Path resolution on the host

- **Relative paths** resolve against the session's working directory.
- **`~`** expands to the SFTP home (`realpath(".")` at connect).
- **Absolute paths** are taken as is.

### 5.2 Operations

| Tool | Remote behaviour |
|---|---|
| `file_read` | SFTP read with the same parameters and limits as local: `offset`, `lines`, `direction`, `max_length`, binary rejection |
| `file_write` | Write to `<path>.minis-tmp-<random>` in the same directory, then rename over the target, keeping the original permission bits. A disconnect never leaves a half-written file |
| `file_edit` | Read and record size + mtime → apply the replacement locally with the same matching rules as local `file_edit` → re-stat before writing. A changed size or mtime returns a conflict error asking the model to re-read. On success, write atomically as for `file_write` |

Local-only side effects (skill reload on `SKILL.md`, file snapshots, the @-mention index) apply only
to local paths.

### 5.3 `minis-remote` device command

`minis-remote` is a new registered device command, run natively in the app over SFTP and gated
like other device commands:

```
minis-remote cp <src> <dst>     # either side may be <host>:<path>; the other a local /var/minis path
minis-remote hosts              # list configured hosts with reachability
```

It moves chat attachments to the host and build artefacts back to the device. A2 will reuse it to
pull screenshots for `read_image`.

## 6. Permissions

- Each host is a permission entry `remote-host:<name>`, Ask Once by default.
- The first remote call in a session asks once; the grant lasts for that session.
- The user can set Bypass or Not Allowed per host.
- There is no per-command confirmation, because coding issues dozens of commands.
- A2's browser and screen control rely on host-side switches (Chrome remote debugging, which the
  user toggles), because the app cannot see inside host shell commands. Real per-action gating
  arrives with the trust core (v3).

## 7. Setup flow

Settings → Remote hosts → Add:

1. **Host details:** name, address (for example the Tailscale name `mini`), port (default 22), user.
2. **Key:**
   - **Generate:** an Ed25519 key stored in the Keychain with
     `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. It is not synced through iCloud Keychain
     and never leaves the device.
   - **Import:** an existing private key instead.
   - **Public key:** shown with Copy, plus the one-liner
     `echo '<pubkey> minis@<device>' >> ~/.ssh/authorized_keys`.
3. **Test connection:**
   - **Host key:** the first connect shows the SHA256 host-key fingerprint in `ssh` format; it is
     stored only after the user confirms.
   - **Checks:** `uname -s`, the login shell, that `git` resolves through the login shell's PATH,
     and that `~/.minis` is writable. Each result is shown separately.
4. **Bind a session:** in a chat, tap the header chip, pick a host, then a working directory
   (browsed over SFTP, with recent directories listed first).

Multiple hosts are allowed. A session is bound to at most one host at a time.

## 8. Error handling

| Situation | Behaviour |
|---|---|
| Unreachable (10s connect timeout) | Error: "Host `mini` unreachable — is Tailscale on?" Never runs locally |
| Authentication failure | Error with a link to the host's public key screen |
| Host key mismatch | Connection refused; re-trust only from Settings after showing the new fingerprint |
| Disconnect during a run | Reconnect with backoff 1/2/4/8s, capped by the tool's remaining timeout. The command keeps running on the host. If reconnecting fails, return the partial output, the `run_id` and "host disconnected; command may still be running" |
| Process gone without `exit` | "Terminated abnormally" with the output tail |
| Edit conflict | §5.2 conflict error |
| `cd` into the working directory fails | Exit 97 mapped to "working directory `<path>` not found on `<host>`" |

## 9. Testing

The project uses XCTest under `src/ios/MinisTests/`. Work test-first.

**Unit tests** (pure functions, no network):

- Routing table (§3.2), including unknown `target` and unbound sessions.
- Path resolution: relative, `~`, absolute, `/var/minis`, `minis://`, explicit `target`.
- Start-script generation against golden files, including commands with quotes, `$`, backslashes
  and newlines.
- Offset-based output reading across chunk boundaries and reconnects.
- Exit-status classification: code, `cancelled`, abnormal.
- Process-tree cancel script: golden output, and a parser test over sample `ps` tables from macOS
  and busybox.
- Edit conflict detection; atomic-write temp naming.
- Retention command; host-key fingerprint formatting.

**Integration tests** (opt-in): run only when `MINIS_TEST_SSH_HOST` (and the related key and user
variables) is set, and are skipped otherwise. Against the local macOS sshd and a Linux openssh
container, each test runs start → drop the connection → reconnect → read → cancel, and checks
that no process from the run's tree is left.

**Manual acceptance:**

1. On the user's Mac mini over Tailscale, a bound session clones or opens a repo, edits a file,
   runs a build and the tests, and uses `gh` with the host's login.
2. A 10-minute command survives backgrounding the app for 5 minutes; on return the output
   resumes from where it stopped.
3. `detach: true` returns immediately, and later `cat` calls show progress and the exit code.
4. The stop button kills a command that spawns children (for example `sleep 600 & sleep 600 & wait`)
   and leaves no process behind.
5. A host-key change blocks the connection with the warning.
6. `apple-calendar` in a bound session still runs locally; `minis-remote cp` moves a file both ways.
7. All of the above pass unchanged against a Linux host (a VPS or a Linux container on the Mac mini).

## 10. Verification results (2026-10-16)

1. **SSH library: Citadel** (`orlandos-nl/Citadel`, MIT, latest tag 0.9.2), on SwiftNIO SSH.
   - **Supported, per its source:**
     - exec channels (`executeCommandStream`, `withExec`)
     - an SFTP client with `rename`, `getAttributes`, `setAttributes` and `remove`
     - Ed25519 authentication and OpenSSH private-key import, including encrypted keys via bcrypt
     - a custom host-key validator (`SSHHostKeyValidator.custom`)
     - direct-tcpip channels (`createDirectTCPIPChannel`, needed by A3)
   - **Platforms:** iOS 17+ and macOS 14+. The app targets iOS 26.2.
   - **Risks and how the plan handles them:**
     - **Third-party NIO SSH fork.** Citadel depends on a fork of NIO SSH, `Joannis/swift-nio-ssh`
       (Apache-2.0, a fork of Apple's). `MinisRemote/Package.swift` pins Citadel, the fork, BigInt
       and ColorizeSwift exactly, because the app build ignores the package's `Package.resolved`
       (decisions.md D11).
     - **`SSHClient` is not `Sendable`.** Under the app's Swift 6 language mode, every `SSHClient`
       is owned by the `SSHConnectionPool` actor and never crosses isolation domains; Citadel is
       imported with `@preconcurrency`.
     - **Not yet built for iOS.** The plan's first task adds the package, builds it for an iOS
       target, and connects to a test host before anything else is written.
   - **Alternatives rejected:**
     - Apple's `swift-nio-ssh` alone has no SFTP, so we would have to write an SFTP client.
     - libssh2 wrappers such as NMSSH are unmaintained and Objective-C.
2. **Detached runs.**
   - **Tested:** against an Alpine Linux container running OpenSSH (busybox `sh`, bash login
     shell) and locally on macOS (zsh login shell).
   - **What works:**
     - A run started over SSH keeps running after the session closes, and after the client is
       killed with `-9`.
     - An `exit` inside the user's command is recorded correctly, thanks to the subshell.
     - The exit code is written atomically.
   - **What failed:** `set -m` failed under busybox `sh` ("can't access tty; job control turned
     off"), so the job stayed in the launcher's process group and group cancel did nothing. The
     design now cancels by process tree (§4.5), which killed every process of a run on both Linux
     and macOS in the same test.
   - **Still to confirm:** the same tests on the Mac mini's own `sshd` over Tailscale. This
     machine has Remote Login off, and turning it on needs admin rights. It is part of manual
     acceptance.
3. **The Mac mini joins the tailnet.** It is not on it yet (the tailnet lists only the laptop and
   the iPhone). This blocks manual acceptance only, not implementation; the Linux container serves
   as the test host until then.

## 11. Out of scope for A1

- Browser login state, screenshots and screen control (A2).
- The VNC viewer and take-over (A3).
- `minis-hostd`, email and GitHub push (sub-project B).
- Password authentication, SSH agent forwarding and jump hosts.
- Android.

## 12. Known limitations

- **Bindings are per device.** A session's host binding lives in the device's `remote-hosts.json`,
  next to the host list and keys, which do not sync either. A chat synced to another device opens
  there unbound, so its shell and file calls run locally on that phone until the user binds it
  again. Whether bindings should travel with the chat needs a product decision.
