# Remote Host A1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Minis session bind to any SSH-reachable host so `shell_execute` and the file tools run there, with long commands surviving app suspension.

**Architecture:**
- **Remote layer:** a local Swift package, `src/ios/Packages/MinisRemote` (library `MinisRemote`), holds the routing and script logic as pure
  functions, plus a few actor-isolated services on top of Citadel (SSH exec, SFTP).
- **Tool dispatch:** upstream tool dispatch gains one routing call. Unbound sessions and device
  commands keep today's local path.
- **On the host:** runs are detached with `nohup`, write their state under `~/.minis/runs/<id>/`,
  and are cancelled by walking the process tree.

**Tech Stack:** Swift 6, SwiftUI, XCTest, Citadel 0.9.2 (SwiftNIO SSH), Security.framework Keychain, POSIX `sh` + `awk` on the host.

**Spec:** [`spec.md`](spec.md) · decisions: [`../decisions.md`](../decisions.md)

## Global Constraints

- **Platform:** iOS only, in the fork only. Android is untouched.
- **Code location:**
  - **Remote core** (Tasks 1–8) lives in the local Swift package `src/ios/Packages/MinisRemote`: library target `MinisRemote`, test target `MinisRemoteTests`, `platforms: [.iOS(.v17), .macOS(.v14)]`, Swift 6 language mode.
  - **App glue** (Tasks 9–11) lives under `src/ios/Agent/Remote/` and `src/ios/Views/Remote/`.
  - **No app types in the package.** The package must not import or reference any app type (`OffloadPermissionManager`, `UIApplication`, `AppLogger`, …). Anything app-side is injected through a protocol or a closure that Task 9 wires up.
- **Upstream edits:** every edit to an existing upstream file carries a `// fork(remote-host):` comment on the changed lines.
- **Citadel version:** pinned with `kind = exactVersion; version = 0.9.2;`. `src/ios/Minis.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is committed with every transitive package pinned.
- **Concurrency:** import Citadel with `@preconcurrency import Citadel`. `SSHClient` instances never leave the `SSHConnectionPool` actor.
- **No silent fallback:** a call routed to a host never runs locally. Every failure returns a tool error with a reason and a next step (spec §8).
- **Host requirements:** nothing is installed on the host. Scripts use POSIX `sh`, `awk`, `ps`, `mv`, `find` only. No `set -m`, no `setsid`.
- **Run directory:** `~/.minis/runs/<id>/` with the files `cmd`, `out`, `exit`, `pid`. `exit` holds an integer or `cancelled`.
- **Timeouts and limits:**

  | Setting | Value |
  |---|---|
  | Connect timeout | 10s |
  | Reconnect backoff | 1, 2, 4, 8s, capped by the tool's remaining timeout |
  | Output poll interval | 1s |
  | Default command timeout | 900s |
  | Cancel grace | 5s between `TERM` and `KILL` |
  | Run-directory retention | 7 days |
  | Working-directory-missing launcher exit code | 97 |

- **Keys:** Ed25519, stored as a Keychain generic password with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and not synchronizable.
- **Host-key fingerprint:** format `SHA256:<base64 without padding>`, matching `ssh`.
- **Permissions:** each host has the permission key `remote-host:<name>`. It is set to `.askOnce` when the host is created, because `OffloadPermissionManager.permissionLevel(for:)` returns `.bypass` for an unset key (`src/ios/Agent/Offload/OffloadPermissionManager.swift:165-168`).
- **Local device commands:** the routing set is every name passed to `native_offload_add_handler` in `src/ios`, plus `minis-remote`. Today that is:
  - `apple-alarm`, `apple-bluetooth`, `apple-calendar`, `apple-clipboard`, `apple-device`
  - `apple-healthkit`, `apple-homekit`, `apple-location`, `apple-maps`, `apple-media`
  - `apple-nfc`, `apple-nlp`, `apple-notification`, `apple-open`, `apple-photos`
  - `apple-player`, `apple-reminders`, `apple-speak`, `apple-speech`, `apple-vision`, `apple-weather`
  - `ffmpeg`
  - `minis-browser-use`, `minis-config`, `minis-debug`, `minis-hangtest`, `minis-model-use`
  - `minis-scheduled`, `minis-sessions-cli`

  `OffloadPermissionManager.allCommands` is **not** this set: it lacks `apple-bluetooth`, `apple-nfc`, `ffmpeg` and every `minis-*`.
- **Tests, Tasks 1–8:** XCTest in the package, run on macOS:
  ```
  swift test --package-path src/ios/Packages/MinisRemote --filter <Class>
  ```
  `MinisTests` is hosted inside the app (`TEST_HOST`). The app needs native deps that are not built in this checkout.
- **Integration tests (opt-in):** they read `MINIS_TEST_SSH_HOST`, `MINIS_TEST_SSH_PORT`, `MINIS_TEST_SSH_USER` and `MINIS_TEST_SSH_KEY` (a path to an OpenSSH Ed25519 private key), and call `XCTSkipUnless` when they are unset. The sshd fixture from Task 1 provides those values.
- **Tests, Tasks 9–11:** `xcodebuild test` with `MinisTests`. These need the native deps built first (`BUILDING.md`). That is a gated step: the controller asks the user before installing toolchains.

## Review Focus

1. **Commands containing quotes, `$`, backticks, backslashes, newlines or non-ASCII text** must reach the host byte-for-byte. A model's multi-line heredoc is the common case. Test: Task 2, `testCommandTravelsAsFileUnchanged`.
2. **A run whose output contains invalid UTF-8 split across a poll boundary** must not drop or garble bytes. Test: Task 3, `testSplitMultibyteSequenceAcrossChunksIsPreserved`.
3. **A working directory or path containing spaces or a single quote** must work for `cd`, SFTP and the run directory. Test: Task 2, `testWorkdirWithSpacesAndQuotesIsQuoted`; Task 4, `testRelativePathWithSpacesResolves`.
4. **The host's login shell is `fish` or another non-POSIX shell**: `$SHELL -lc '( . file )'` breaks there. Fall back to `/bin/sh -lc` when `basename $SHELL` is not one of `sh`, `bash`, `zsh`, `dash`, `ksh`, `ash`. Test: Task 2, `testNonPosixLoginShellFallsBackToSh`.
5. **The model passes `target` naming a host that was renamed or deleted** mid-session. The result must be an error naming the configured hosts, never a local run. Test: Task 4, `testUnknownTargetIsErrorListingHosts`.

---

### Task 1: `MinisRemote` package, Citadel dependency, sshd fixture, smoke test

**Files:**
- Create: `src/ios/Packages/MinisRemote/Package.swift`
- Create: `src/ios/Packages/MinisRemote/Package.resolved` (commit it)
- Create: `src/ios/Packages/MinisRemote/Sources/MinisRemote/RemoteHostConfig.swift`
- Create: `src/ios/Packages/MinisRemote/Tests/Fixtures/sshd/Dockerfile` and `src/ios/Packages/MinisRemote/Tests/Fixtures/sshd/up.sh`
- Test: `src/ios/Packages/MinisRemote/Tests/MinisRemoteTests/RemoteSSHSmokeTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct RemoteHostConfig: Codable, Hashable, Sendable {
      public let name: String          // unique, [A-Za-z0-9_-]{1,32}
      public let address: String
      public let port: Int
      public let user: String
      public let keyRef: String        // secret-store account of the private key
      public let pinnedHostKey: String? // OpenSSH public-key line, nil until trusted
  }
  ```
- Produces `Tests/Fixtures/sshd/up.sh`, which:
  1. builds and starts an Alpine + OpenSSH container named `minis-sshtest` on port 2222, with user `dev` and login shell `/bin/bash`;
  2. generates a throwaway Ed25519 key into `Tests/Fixtures/sshd/.key`, which is git-ignored;
  3. prints `export MINIS_TEST_SSH_HOST=127.0.0.1 MINIS_TEST_SSH_PORT=2222 MINIS_TEST_SSH_USER=dev MINIS_TEST_SSH_KEY=<abs path>`.

  `up.sh down` removes the container.

- [ ] **Step 1: Create the package.**
  - **Manifest:** `swift-tools-version: 6.0`, with Citadel `.package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.9.2")`.
  - **Resolve:** run `swift package --package-path src/ios/Packages/MinisRemote resolve`.
  - Expected: `Package.resolved` pins Citadel 0.9.2, plus `swift-nio-ssh` from the fork Citadel names, at an exact revision.
- [ ] **Step 2: Write the opt-in smoke test.**
  - **Test:** `RemoteSSHSmokeTests.testConnectAndEcho`, which calls `XCTSkipUnless` on the four env vars.
  - **Connect:** with `SSHClient.connect(host:port:authenticationMethod: .ed25519(...), hostKeyValidator: .acceptAnything(), reconnect: .never)`, loading the key file with Citadel's OpenSSH Ed25519 parser.
  - **Assert:** run `echo minis-ok`; the output, trimmed, equals `"minis-ok"`.
- [ ] **Step 3: Run the tests with the fixture down.**
  - **Command:** `swift test --package-path src/ios/Packages/MinisRemote`.
  - **Expected:** builds, and the test is SKIPPED. Concurrency warnings caused by Citadel's types are acceptable only behind `@preconcurrency import Citadel`.
- [ ] **Step 4: Run the tests with the fixture up.**
  - **Command:** `eval "$(sh src/ios/Packages/MinisRemote/Tests/Fixtures/sshd/up.sh)"; swift test --package-path src/ios/Packages/MinisRemote`.
  - **Expected:** PASS.
- [ ] **Step 5: Commit** the package files (not `.build/`, not `.key`), with message `feat(remote-host): add MinisRemote package with Citadel and sshd fixture`.

### Task 2: Run scripts (launch, cancel tree, retention)

**Files:**
- Create: `src/ios/Packages/MinisRemote/Sources/MinisRemote/RemoteRunScripts.swift`
- Test: `src/ios/Packages/MinisRemote/Tests/MinisRemoteTests/RemoteRunScriptsTests.swift`, with golden files in `src/ios/Packages/MinisRemote/Tests/MinisRemoteTests/Golden/ (declared as a `.copy("Golden")` test resource)`

**Interfaces:**
- Produces:
  ```swift
  enum RemoteRunScripts {
      static func shellQuote(_ s: String) -> String                       // POSIX single-quote quoting
      static func launch(runId: String, workdir: String, commandBase64: String) -> String
      static func readChunk(runId: String, offset: Int, maxBytes: Int) -> String   // prints bytes from offset
      static func status(runId: String) -> String                          // prints exit content or "running <pid-alive 0|1>"
      static func cancelTree(runId: String, signal: String) -> String      // prints count signalled
      static func writeCancelled(runId: String) -> String
      static let retention: String
  }
  ```

- [ ] **Step 1: Write failing tests.**
  - **Golden scripts:**
    - `testLaunchScriptMatchesGolden` compares against `Golden/launch.sh`.
    - `testCancelTreeMatchesGolden` compares against `Golden/cancel-tree.sh`.
    - `testRetentionIsSevenDays` asserts the script contains `-mtime +7`.
  - **Command content:** `testCommandTravelsAsFileUnchanged`.
    - It uses the command `"cat <<'EOF'\n$HOME \"q\" `x` \\ 中文\nEOF"`.
    - It asserts the launch script contains no raw form of the command, only `commandBase64`, decoded on the host by `base64 -d` (falling back to `base64 -D`, which macOS needs).
  - **Quoting:** `testWorkdirWithSpacesAndQuotesIsQuoted`.
    - It uses the working directory `/home/a b/it's`.
    - It asserts `shellQuote` yields `'/home/a b/it'\''s'`.
  - **Login shell:** `testNonPosixLoginShellFallsBackToSh` asserts the script selects `/bin/sh` unless the basename of `$SHELL` is in `sh bash zsh dash ksh ash`.
  - **Exit-code plumbing:** `testLaunchWritesExitAtomicallyAndUsesSubshell` asserts the exact substrings `( . "$R/cmd" )`, `> "$R/exit.tmp"` and `mv "$R/exit.tmp" "$R/exit"`.
  - **Missing working directory:** `testLaunchExits97WhenWorkdirMissing` asserts the script contains `|| exit 97`.
- [ ] **Step 2: Run them.** Expected: FAIL (symbols missing).
- [ ] **Step 3: Implement `RemoteRunScripts`.**
  - **Launch script order:**
    1. `mkdir -p` the run directory.
    2. `cd` into the working directory, or `exit 97`.
    3. Decode the base64 command into `cmd`.
    4. Pick the shell.
    5. `nohup <shell> -lc '( . "$R/cmd" ); echo $? > "$R/exit.tmp"; mv "$R/exit.tmp" "$R/exit"' </dev/null >"$R/out" 2>&1 &`
    6. `echo $! > "$R/pid"`.
  - **`cancelTree`:** the tree walk proven in spec §10: `ps -A -o pid= -o ppid=` with a fallback to `ps -o pid= -o ppid=`, then a breadth-first walk with `awk`.
  - **`readChunk`:** `tail -c +$((offset+1)) out | head -c maxBytes`.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Run the golden scripts on the test container.** This is the same Alpine container: start a 5-tick run, disconnect, read it, then cancel a `sleep 300 & sleep 300 & wait` run.
  Expected:
  - The first run has an `exit` of `0`.
  - After the cancel, `ps` shows no `sleep 300` process from that run.
- [ ] **Step 6: Commit** with message `feat(remote-host): add detached run scripts with tree cancel`.

### Task 3: Output reader and exit classification

**Files:**
- Create: `src/ios/Packages/MinisRemote/Sources/MinisRemote/RemoteRunState.swift`
- Test: `src/ios/Packages/MinisRemote/Tests/MinisRemoteTests/RemoteRunStateTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum RemoteRunOutcome: Equatable, Sendable { case running, exited(Int32), cancelled, abnormal }
  struct RemoteOutputBuffer: Sendable {
      private(set) var offset: Int
      mutating func append(_ bytes: [UInt8]) -> String   // returns newly decodable text; holds an incomplete UTF-8 tail
  }
  enum RemoteRunState {
      static func classify(statusOutput: String) -> RemoteRunOutcome
      static func truncateForModel(_ text: String, outputPath: String, limit: Int) -> String
  }
  ```

- [ ] **Step 1: Write failing tests.**
  - **`classify`:**
    - `testClassifyExitCode`: `"3"` gives `.exited(3)`.
    - `testClassifyCancelled`: `"cancelled"` gives `.cancelled`.
    - `testClassifyRunning`: `"running 1"` gives `.running`.
    - `testClassifyAbnormal`: `"running 0"` (pid dead, no `exit`) gives `.abnormal`.
  - **`RemoteOutputBuffer`:**
    - `testSplitMultibyteSequenceAcrossChunksIsPreserved`: feed `"中"` as `[0xE4]` then `[0xB8, 0xAD]`. Expect `""`, then `"中"`, and `offset == 3`.
    - `testInvalidUTF8IsReplacedNotDropped`: `[0xFF, 0x41]` gives `"\u{FFFD}A"`.
  - **`truncateForModel`:** `testTruncateKeepsHeadTailAndNamesFile` asserts the result contains the first and last lines and the output path when the text exceeds `limit`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **Truncation limit and head/tail split:** use the same ones as local `shell_execute`. Find them in the existing output-capping code in `AIChatViewModel+ConcurrentTools.swift` and reuse that constant rather than introducing a new one.
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit** with message `feat(remote-host): add run output buffer and outcome classification`.

### Task 4: Routing

**Files:**
- Create: `src/ios/Packages/MinisRemote/Sources/MinisRemote/RemoteRouting.swift`
- Test: `src/ios/Packages/MinisRemote/Tests/MinisRemoteTests/RemoteRoutingTests.swift`

**Interfaces:**
- Consumes: `RemoteHostConfig` (Task 1).
- Produces:
  ```swift
  struct SessionHostBindingValue: Codable, Hashable, Sendable { let hostName: String; let workdir: String }
  enum ToolDestination: Equatable, Sendable { case local, remote(hostName: String) }
  enum RemoteRoutingError: Error, Equatable { case unknownTarget(String, available: [String]) }
  enum RemoteRouting {
      static let localDeviceCommands: Set<String>   // exactly the Global Constraints list
      static func destination(toolName: String, arguments: [String: Any], binding: SessionHostBindingValue?,
                              knownHosts: [String]) throws -> ToolDestination
      static func resolveRemotePath(_ path: String, workdir: String, home: String) -> String
  }
  ```

- [ ] **Step 1: Write failing tests** for the spec §3.2 table, in rule order.
  - **Rule 1, explicit `target`:**
    - `testExplicitLocalTargetWins`
    - `testExplicitHostTargetWins`
    - `testUnknownTargetIsErrorListingHosts`, which expects `unknownTarget("old", available: ["mini"])`
  - **Rule 2, device commands stay local:**
    - `testDeviceCommandStaysLocal`, for each of `apple-calendar list`, `/usr/local/bin/ffmpeg -i x` and `minis-sessions-cli search q`
    - `testCombinedCommandGoesRemote`: `cd x && apple-calendar` gives `.remote`
  - **Rule 3, local paths stay local:** `testVarMinisAndMinisURLPathsStayLocal`, for `file_read` of `/var/minis/skills/a/SKILL.md` and of `minis://workspace/a.txt`.
  - **Rule 4, everything else follows the binding:**
    - `testBoundSessionGoesRemote`
    - `testUnboundSessionIsAlwaysLocal`
  - **Path resolution:**
    - `testRelativePathWithSpacesResolves`: `"src/a b.swift"` against `/home/u/repo` gives `/home/u/repo/src/a b.swift`
    - `testTildeExpands`
    - `testAbsolutePathUnchanged`
  - **Device command list:** `testLocalDeviceCommandsMatchRegisteredHandlers` reads every `native_offload_add_handler("…"` name from the source tree at test time (`#filePath`-relative) and asserts that set plus `minis-remote` equals `localDeviceCommands`. This catches future upstream additions during a sync.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **First token:** take it the way `extractOffloadCommand` does (`OffloadPermissionManager.swift:210-222`), using the basename. Match it against `localDeviceCommands`, not `allCommands`.
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit** with message `feat(remote-host): add tool routing rules`.

### Task 5: Host store, keys and host-key pinning

**Files:**
- Create:
  - `src/ios/Packages/MinisRemote/Sources/MinisRemote/RemoteHostStore.swift`
  - `src/ios/Packages/MinisRemote/Sources/MinisRemote/RemoteKeyStore.swift`
  - `src/ios/Packages/MinisRemote/Sources/MinisRemote/HostKeyFingerprint.swift`
- Test:
  - `src/ios/Packages/MinisRemote/Tests/MinisRemoteTests/HostKeyFingerprintTests.swift`
  - `src/ios/Packages/MinisRemote/Tests/MinisRemoteTests/RemoteHostStoreTests.swift`

**Interfaces:**
- Consumes: `RemoteHostConfig` (Task 1), `SessionHostBindingValue` (Task 4).
- Produces:
  ```swift
  enum HostKeyFingerprint { static func sha256(openSSHPublicKey: String) throws -> String }  // "SHA256:…"
  public protocol RemoteSecretStore: Sendable { func set(_ data: Data, account: String) throws; func get(account: String) throws -> Data?; func delete(account: String) throws }
  public struct KeychainSecretStore: RemoteSecretStore { public init(service: String) }   // real Keychain, used by the app
  public final class InMemorySecretStore: RemoteSecretStore, @unchecked Sendable { public init() } // tests
  @MainActor public final class RemoteHostStore: ObservableObject {
      @Published private(set) var hosts: [RemoteHostConfig]
      init(fileURL: URL, secrets: RemoteSecretStore, onHostAdded: @escaping @MainActor (String) -> Void)  // app passes a closure that sets .askOnce for the given permission key
      func add(_ host: RemoteHostConfig) throws        // calls onHostAdded("remote-host:<name>")
      func remove(name: String)
      func pinHostKey(name: String, openSSHPublicKey: String)
      func binding(sessionId: String) -> SessionHostBindingValue?
      func setBinding(_ value: SessionHostBindingValue?, sessionId: String)
  }
  enum RemoteKeyStore {   // every function takes `store: RemoteSecretStore` as its first parameter
      static func generateEd25519(account: String) throws -> String       // returns OpenSSH public-key line "ssh-ed25519 … minis@<device>"
      static func importOpenSSHPrivateKey(_ pem: String, passphrase: String?, account: String) throws -> String
      static func privateKey(account: String) throws -> Curve25519.Signing.PrivateKey
  }
  ```

- [ ] **Step 1: Write failing tests.**
  - **Fingerprint:** `testFingerprintMatchesSshKeygen`. Take a fixed Ed25519 public-key line and its expected value as printed by `ssh-keygen -lf` (computed once and pasted in), and assert equality.
  - **Store:**
    - `testAddRejectsDuplicateAndInvalidName`
    - `testAddReportsPermissionKey`: after `add`, the `onHostAdded` closure was called exactly once with `"remote-host:mini"`.
    - `testBindingRoundTripsAcrossInstances`
    - `testRemovingHostClearsItsBindings`
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **Persistence:** host configs and bindings go to the JSON file at `fileURL`. The app passes Application Support `remote-hosts.json`; tests pass a temp file. with separate `hosts` and `bindings` keys. Write it atomically.
  - **Keys:** private keys are stored as a Keychain generic password with service `minis.remote-host.key`, using the accessibility from Global Constraints. Follow the add/update pattern at `ProviderConfigStore.swift:3346` for the query shape.
  - **Public-key line:** produced via Citadel/NIOSSH (`String(openSSHPublicKey:)`).
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit** with message `feat(remote-host): add host store, keys and fingerprints`.

### Task 6: Connection pool

**Files:**
- Create: `src/ios/Packages/MinisRemote/Sources/MinisRemote/SSHConnectionPool.swift`
- Test: `src/ios/Packages/MinisRemote/Tests/MinisRemoteTests/SSHConnectionPoolTests.swift`, where `testReconnectAfterDrop` is opt-in and the backoff tests are pure

**Interfaces:**
- Consumes: `RemoteHostStore`, `RemoteKeyStore`, `HostKeyFingerprint`.
- Produces:
  ```swift
  enum RemoteHostError: Error, Equatable {
      case unreachable(host: String), authFailed(host: String), hostKeyMismatch(host: String, presented: String),
           hostKeyUnpinned(host: String, presented: String), notConfigured(host: String)
      var userMessage: String   // spec §8 wording, e.g. "Host `mini` unreachable — is Tailscale on?"
  }
  actor SSHConnectionPool {
      static let shared: SSHConnectionPool
      func exec(host: String, script: String, timeout: Duration) async throws -> String
      func sftp(host: String) async throws -> SFTPClient
      func invalidate(host: String)                         // called on foreground / network change
      static func backoffDelays(remaining: Duration) -> [Duration]   // 1,2,4,8s capped by remaining
  }
  ```

- [ ] **Step 1: Write failing tests.**
  - **Backoff:**
    - `testBackoffDelaysCappedByRemaining`: 10s remaining gives `[1,2,4]`.
    - `testBackoffDelaysFull`: 60s gives `[1,2,4,8]`.
  - **Errors:** `testUserMessagesMatchSpec` covers each `RemoteHostError` case and checks it against the spec §8 text.
  - **Opt-in against the container:**
    - `testUnpinnedHostKeyIsReported` expects `hostKeyUnpinned` with a `SHA256:` fingerprint.
    - `testMismatchedHostKeyIsRejected`.
    - `testReconnectAfterDrop`: restart the container, then the next `exec` succeeds.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **Connections:** one `SSHClient` per host, kept inside the actor.
  - **Host-key validator:** `SSHHostKeyValidator.custom` compares the presented key with `pinnedHostKey`. A nil pin throws `hostKeyUnpinned`; Settings uses that to show the trust prompt.
  - **When to reconnect:** on `onDisconnect`, and lazily on next use.
  - **Retention:** run `RemoteRunScripts.retention` once per new connection, without awaiting it.
  - **App lifecycle:** expose `func invalidateClosed()`, which drops clients that report closed. Task 9 calls it on `UIApplication.willEnterForegroundNotification`; the package has no UIKit dependency.
- [ ] **Step 4: Run them.** Expected: PASS. The opt-in tests pass against the container.
- [ ] **Step 5: Commit** with message `feat(remote-host): add SSH connection pool`.

### Task 7: Remote executor

**Files:**
- Create: `src/ios/Packages/MinisRemote/Sources/MinisRemote/RemoteExecutor.swift`
- Test: `src/ios/Packages/MinisRemote/Tests/MinisRemoteTests/RemoteExecutorTests.swift` (opt-in, against the container)

**Interfaces:**
- Consumes: `SSHConnectionPool`, `RemoteRunScripts`, `RemoteRunState`, `RemoteOutputBuffer`.
- Produces:
  ```swift
  struct RemoteRunHandle: Codable, Sendable { let host: String; let runId: String; var offset: Int
      var outputPath: String { "~/.minis/runs/\(runId)/out" } }
  enum RemoteExecResult: Sendable { case finished(output: String, outcome: RemoteRunOutcome, handle: RemoteRunHandle)
                                    case detached(handle: RemoteRunHandle)
                                    case disconnected(partialOutput: String, handle: RemoteRunHandle) }
  actor RemoteExecutor {
      static let shared: RemoteExecutor
      func run(host: String, workdir: String, command: String, timeout: Duration, detach: Bool,
               onOutput: @Sendable (String) -> Void) async throws -> RemoteExecResult
      func cancel(_ handle: RemoteRunHandle) async throws        // TERM tree, 5s, KILL tree, write cancelled
  }
  ```

- [ ] **Step 1: Write failing opt-in tests.**
  - `testRunReturnsOutputAndExitCode`: `echo a; exit 4` gives `.finished("a\n", .exited(4))`.
  - `testDetachReturnsImmediately`: `sleep 5` with detach gives `.detached` in under 2s.
  - `testTimeoutCancelsTree`: `sleep 300 & sleep 300 & wait` with a 2s timeout gives `.cancelled`, and a follow-up `exec` of `ps -o args` shows no `sleep 300`.
  - `testResumeAfterDropReadsFromOffset`: start a 5-tick run, call `invalidate` mid-run, then confirm all 5 ticks arrive exactly once.
  - `testWorkdirMissingMapsToError`: launcher exit 97 gives an error whose message contains `working directory`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **Run id:** a lowercase UUID prefix of 12 characters.
  - **Polling:** read every 1s by offset. Feed `onOutput` with `RemoteOutputBuffer.append` results.
  - **Losing the connection:** follow `backoffDelays`. If those are exhausted, return `.disconnected`.
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit** with message `feat(remote-host): add remote executor`.

### Task 8: Remote file service

**Files:**
- Create: `src/ios/Packages/MinisRemote/Sources/MinisRemote/RemoteFileService.swift`
- Test: `src/ios/Packages/MinisRemote/Tests/MinisRemoteTests/RemoteFileServiceTests.swift` (pure tests plus opt-in)

**Interfaces:**
- Consumes: `SSHConnectionPool.sftp(host:)`, `RemoteRouting.resolveRemotePath`.
- Produces:
  ```swift
  struct RemoteFileStamp: Equatable, Sendable { let size: UInt64; let mtime: UInt32 }
  enum RemoteFileError: Error, Equatable { case conflict(path: String), binary(path: String), notFound(path: String) }
  actor RemoteFileService {
      static let shared: RemoteFileService
      func read(host: String, path: String, offset: Int?, lines: Int?, direction: String?, maxLength: Int?) async throws -> String
      func write(host: String, path: String, content: String) async throws
      func edit(host: String, path: String, oldString: String, newString: String, replaceAll: Bool) async throws -> String
      func copy(from: RemoteCopyEndpoint, to: RemoteCopyEndpoint) async throws -> UInt64   // bytes
      static func tempName(for path: String, random: String) -> String  // "<dir>/.<base>.minis-tmp-<random>"
  }
  enum RemoteCopyEndpoint: Equatable, Sendable { case local(String), remote(host: String, path: String) }
  ```

- [ ] **Step 1: Write failing tests.**
  - **Pure:** `testTempNameStaysInSameDirectory`.
  - **Opt-in:**
    - `testWriteIsAtomicAndKeepsMode`: `chmod 755` the file, write it, then check its mode is still 755 and no temp file remains.
    - `testEditDetectsConcurrentChange`: read, change the file on the host via `exec`, then `edit` throws `conflict`.
    - `testReadRejectsBinary`.
    - `testEditMatchesLocalSemantics`: the same `oldString` that fails locally because it is not unique fails remotely with the same message.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **Read parameters and edit matching:** port the read-slicing (`offset`, `lines`, `direction`, `max_length`, binary rejection) and edit-matching semantics of `src/ios/Agent/Chat/AIChatViewModel+FileTools.swift` (`executeFileRead` from line 272, `executeFileEdit` from line 626) into public pure helpers, `FileToolLogic`, in the package, with tests that pin each behaviour, error messages included. Task 9 switches the app's local file tools to call `FileToolLogic`, so there is one implementation.
  - **Stamps:** taken from `getAttributes`.
- [ ] **Step 4: Run them.** Expected: PASS. Also run the existing file-tool tests in `MinisTests`; expected: still PASS.
- [ ] **Step 5: Commit** with message `feat(remote-host): add SFTP file service`.

### Task 9: Tool dispatch, tool schema and system prompt

**Files:**
- Modify:
  - `src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift`: the `case "shell_execute"`, `"file_read"`, `"file_write"` and `"file_edit"` branches at lines 373, 600, 620 and 640.
  - `src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift`: four definitions starting at line 40.
  - `src/ios/Agent/Chat/AIChatViewModel.swift`: the system prompt near line 2316.
- Create: `src/ios/Agent/Remote/RemoteToolBridge.swift`, `src/ios/Agent/Remote/RemoteAppWiring.swift`. The wiring:
  - builds `RemoteHostStore` with a `KeychainSecretStore(service: "minis.remote-host.key")`;
  - passes `onHostAdded` as `{ OffloadPermissionManager.shared.setPermissionLevel(.askOnce, for: $0) }`;
  - calls `SSHConnectionPool.shared.invalidateClosed()` on foreground.
- Modify: `src/ios/Minis.xcodeproj/project.pbxproj`:
  - add `XCLocalSwiftPackageReference` `Packages/MinisRemote` and link product `MinisRemote` to the `Minis` target;
  - add `Agent/Remote` and `Views/Remote` as `PBXFileSystemSynchronizedRootGroup` entries, following the `Terminal` group at line 1293.
- Modify: `src/ios/Agent/Chat/AIChatViewModel+FileTools.swift`: local read and edit call `FileToolLogic` (marked).
- **Gate:** this task needs the app to build. Before dispatching, the controller confirms with the user that the native deps and toolchains may be installed.
- Test: `src/ios/MinisTests/Remote/RemoteToolBridgeTests.swift`

**Interfaces:**
- Consumes: `RemoteRouting`, `RemoteExecutor`, `RemoteFileService`, `RemoteHostStore`, `OffloadPermissionManager.checkPermission(for:sessionId:fullCommand:)`.
- Produces:
  ```swift
  enum RemoteToolBridge {
      /// nil means "not remote — take the existing local path".
      static func handle(toolName: String, argsJson: String, sessionId: String?,
                         onOutput: @Sendable (String) -> Void) async -> (output: String, success: Bool)?
      static func formatResult(_ r: RemoteExecResult, limit: Int) -> String   // always starts with "run_id: <id>\noutput: <path>\n"
      static func systemPromptLine(binding: SessionHostBindingValue, os: String) -> String
  }
  ```

- [ ] **Step 1: Write failing tests.**
  - **Result formatting:**
    - `testResultAlwaysStartsWithRunIdAndPath`, for every `RemoteExecResult` case.
    - `testDisconnectedResultSaysMayStillBeRunning`, which checks for the exact phrase `host disconnected; command may still be running`.
  - **System prompt:** `testSystemPromptLineFormat` expects ``You are working on host `mini` (Darwin) in `/Users/x/code`.``
  - **Unbound sessions:** `testHandleReturnsNilForUnboundSession`.
  - **Redaction:** `testRemoteOutputIsRedacted`. Remote shell output passes through
    `EnvVarRedactor.redactIfEnabled` (`src/ios/Shared/EnvVarRedactor.swift:62`), exactly as local
    output does at `AIChatViewModel+ConcurrentTools.swift:594`. With an env var whose value is
    `s3cr3t-value`, an output containing it comes back masked.
  - **Permissions:** `testPermissionDeniedReturnsMessageNotLocalRun`, with the host's permission set to `.notAllowed`. The result contains the denial and `success == false`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement the bridge.**
  - **Edit to each dispatch branch:** add one line at the top:
    ```swift
    if let r = await RemoteToolBridge.handle(...) { /* set toolOutput/success, update block */ break } // fork(remote-host):
    ```
    The existing code below it stays untouched.
  - **Edit to the tool definitions:** add the optional `target` (string) to the four tools, and the optional `detach` (boolean) to `shell_execute`.
    - The `target` description is *"Where to run: 'local' for the on-device Linux, or a configured remote host name. Defaults to the session's bound host if any, else local."*
    - Append both to `propertyOrdering`.
  - **Edit to the system prompt:** append `systemPromptLine` when the session is bound. Also append one sentence: *"Device commands (apple-*, minis-*, ffmpeg) always run on this phone; call them on their own, not combined with host commands."*
- [ ] **Step 4: Run the full `MinisTests` suite.** Expected: PASS, with no change in pre-existing tests.
- [ ] **Step 5: Build for device.** Use the Task 1 Step 2 command. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 6: Commit** with message `feat(remote-host): route shell and file tools to bound hosts`.

### Task 10: `minis-remote` device command

**Files:**
- Create:
  - `src/ios/NativeOffloads/RemoteOffload.h`
  - `src/ios/NativeOffloads/RemoteOffload.m`
  - `src/ios/NativeOffloads/RemoteOffloadBridge.swift`
- Modify:
  - `src/ios/iSH/ISHKernel.m:919`: add `remote_offload_register();` next to `scheduled_offload_register();`.
  - The bridging header, if `ScheduledOffload.h` is listed there.
- Test: `src/ios/MinisTests/Remote/RemoteOffloadBridgeTests.swift`

**Interfaces:**
- Consumes: `RemoteFileService.copy`, `RemoteHostStore`, `SSHConnectionPool`.
- Produces:
  - `@objc RemoteOffloadBridge.copy(src:dst:) -> NSDictionary`, returning `{copied: bytes, from, to}` or `{ok:false, error, message}`.
  - `@objc RemoteOffloadBridge.hosts() -> NSDictionary`, returning `{hosts: [{name, address, reachable}]}`.
  - The guest stub `/usr/local/bin/minis-remote`.

- [ ] **Step 1: Write failing tests.**
  - `testParseEndpoint`:
    - `mini:~/a` gives `.remote("mini","~/a")`.
    - `/var/minis/x` gives `.local`.
    - `C:/x` is invalid.
  - `testCopyRejectsLocalToLocalAndRemoteToRemote`.
  - `testUnknownHostError`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement**, mirroring `ScheduledOffload.m`: help text, `noff_json_error`, `noff_emit_json`, registration via `native_offload_add_handler("minis-remote", …)`, and `noff_ensure_guest_stub`. Use the blocking main-actor helper pattern from `ScheduledOffloadBridge.onMain`.
- [ ] **Step 4: Run the tests.** Expected: PASS. Then re-run `RemoteRoutingTests.testLocalDeviceCommandsMatchRegisteredHandlers`; expected: PASS, now including `minis-remote`.
- [ ] **Step 5: Commit** with message `feat(remote-host): add minis-remote copy command`.

### Task 11: Settings, session sheet and manual acceptance

**Files:**
- Create:
  - `src/ios/Views/Remote/RemoteHostsSettingsView.swift`: the list, plus add/edit, key generation or import, copying the public key, and test connection.
  - `src/ios/Views/Remote/RemoteHostTrustSheet.swift`: shows the `SHA256:` fingerprint with Trust and Cancel buttons.
  - `src/ios/Views/Remote/SessionRemoteHostView.swift`: pick a host and a working directory over SFTP, with recent directories first.
- Modify:
  - `src/ios/Views/ContentView.swift`: in `Section("Agent Runtime")` near line 8157, add a `NavigationLink` "Remote Hosts".
  - `src/ios/Views/Chat/AIChatView.swift`: add `@State showSessionRemoteHost`, a `.sheet` next to `showSessionSkills` near line 1075, and a menu button next to the one that sets `showSessionSkills`. Show the bound host's name as the button label when the session is bound.
- Test: `src/ios/MinisTests/Remote/RemoteHostChecksTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  ```swift
  enum RemoteHostChecks {
      struct Result: Equatable { let label: String; let ok: Bool; let detail: String }
      static let script: String   // prints uname -s, $SHELL, `command -v git` via login shell, ~/.minis writability, one per line
      static func parse(_ output: String) -> [Result]
  }
  ```

- [ ] **Step 1: Write failing tests.**
  - `testParseAllOk`.
  - `testParseMissingGit`: the git check is `ok == false` and its detail mentions the PATH.
  - `testParseUnwritableMinisDir`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement the checks and the three views.**
  - **Strings:** user-facing text goes through `AppLocalized`, following `src/ios/LOCALIZATION_STYLE.md`. Add English keys only. Other locales fall back to English; this is a fork.
- [ ] **Step 4: Run the tests and build for device.** Expected: PASS, then `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Manual acceptance.** Do this on a device, against the Mac mini over Tailscale once it is on the tailnet, and against the Linux container or a VPS. Each item matches spec §9:
  1. A bound session edits a repo file, runs a build and the tests, and `gh auth status` succeeds with the host's login.
  2. A 10-minute command survives backgrounding the app for 5 minutes, and its output resumes.
  3. `detach: true` returns immediately; later `cat …/exit` shows the code.
  4. Stop kills `sleep 600 & sleep 600 & wait` with no process left.
  5. A changed host key blocks the connection with the warning.
  6. `apple-calendar` still runs locally, and `minis-remote cp` works both ways.
  7. Items 1–6 also pass unchanged on the Linux host.

  Record the results, with device, host OS and pass/fail for each item, in the spec's §10 under a new "Acceptance" list.
- [ ] **Step 6: Commit** with message `feat(remote-host): add host settings and session binding UI`.
