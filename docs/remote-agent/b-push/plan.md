# Proactive Push (B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mail from allowlisted senders and GitHub activity that needs the user reach the iPhone as
encrypted Bark notifications; tapping one opens the event, or a batch of events, in Minis as
untrusted content in a read-only session.

**Architecture:**
- **Host:** `minis-hostd`, one static Go binary. Sources (IMAP, GitHub) produce candidates, a pure
  gate and a pure pacing function decide, SQLite stores events and an outbox, and a Bark notifier
  drains the outbox. A JSON CLI is the only interface the app uses.
- **App:** a `pico://host-event` route (`minis://` before D22) handled at the app root fetches events over A1's SSH
  connection and opens a session whose tools are limited by a per-session policy.

**Tech Stack:** Go 1.26, `github.com/emersion/go-imap/v2` v2.0.0-beta.8, `github.com/emersion/go-message`
v0.18.2, `modernc.org/sqlite` v1.60.1, `github.com/BurntSushi/toml` v1.6.0, `github.com/oklog/ulid/v2`
v2.1.2; Swift 6, SwiftUI, XCTest, the A1 `MinisRemote` package.

**Spec:** [`spec.md`](spec.md) · decisions: [`../decisions.md`](../decisions.md)

## Global Constraints

- **Platform:** the host runs macOS or Linux, arm64 or amd64. The app side is iOS only, in the fork
  only.
- **Code location:**
  - **hostd** (Tasks 1–10) is the Go module `host/minis-hostd/` (module path
    `github.com/NoSugarCoffee/OpenMinis/host/minis-hostd`). Packages under `internal/`: `config`,
    `store`, `gate`, `pacing`, `notify`, `source/github`, `source/imap`, `daemon`, `cli`, `service`.
    `main.go` only dispatches to `cli`.
  - **Contract types** (Task 11) live in `src/ios/Packages/MinisRemote`, next to A1.
  - **App glue** (Tasks 12–13) lives under `src/ios/Agent/HostEvents/` and `src/ios/Views/Remote/`.
- **Builds:** `CGO_ENABLED=0` always, so one source tree cross-builds to the four targets. No
  dependency outside the Tech Stack list without a decision entry.
- **Pure functions:** the gate, pacing, cursor rules, `Authentication-Results` parsing, poll
  scheduling, notice text and the CLI encoding take plain values (including `now time.Time`) and
  return values. Nothing in them reads the clock, the network or the database.
- **Never mutate a source:** IMAP fetches use `BODY.PEEK[]` only; no `STORE`, `COPY`, `MOVE` or
  `EXPUNGE` is ever sent. The GitHub client sends `GET` only.
- **Upstream edits:** every edit to an existing upstream file carries a `// fork(remote-host):`
  comment on the changed lines. B adds the four integration points of spec §3.3 and nothing else.
- **No silent fallback:** a failed source stops with a recorded reason (spec §11); the app shows
  every failure with a next step.
- **Settings:**

  | Setting | Value |
  |---|---|
  | IMAP `IDLE` re-issue | 9 min (adjust after S1) |
  | IMAP reconcile | every 15 min and on every (re)connect |
  | IMAP reconnect backoff | 5 s doubling to 5 min |
  | Message fetch cap / event body cap | 1 MiB / 64 KiB |
  | Message-ID ring | 1,000 per account |
  | Freshness limit | 48 h of IMAP internal date |
  | GitHub poll interval | `max(X-Poll-Interval, 60 s)` |
  | Login-failure retry (IMAP, GitHub) | 30 min |
  | Coalescing hold | 2 min after each push |
  | Daily cap | 30 notices per local day |
  | Bark retry on HTTP error | backoff up to 1 h |
  | Heartbeat stamp | 60 s |
  | Retention | 30 days, pruned daily |
  | Notice text limit | 120 characters |
  | Bark key | 32 characters from `abcdefghjkmnpqrstuvwxyz23456789` |
  | Bark IV | 12 random characters per push |

- **Files on the host:** `~/.minis/bin/minis-hostd`, `~/.minis/hostd/config.toml` (mode 0600,
  refused otherwise), `~/.minis/hostd/state.db`.
- **CLI contract:** every output is one JSON line with `"schemaVersion": 1`; errors exit 2 with
  `{schemaVersion, error: {code, message}}`. Golden files live in
  `host/minis-hostd/testdata/contract/` and are read by both test suites.
- **Tests:**
  - Go: `go test ./...` from `host/minis-hostd/`, with Go from Nix (`nix shell nixpkgs#go`).
    Integration tests use in-process servers only (`imapmemserver`, `httptest`) and need no network.
  - Package: `swift test --package-path src/ios/Packages/MinisRemote --filter <Class>`.
  - App: `xcodebuild test` with `MinisTests` on the iOS Simulator (BUILDING.md), plus one
    Simulator UI test in Task 12.
- **Dependency risk:** go-imap v2 is still beta. Pin the exact version; if a blocking bug appears,
  record it and decide between patching via `replace` and falling back to go-imap v1 before
  working around it.

## Review Focus

1. **At most one notification per notice**, across a crash between commit and send and across a
   restart during a hold. Test: Task 8, `TestCrashBetweenCommitAndSendDoesNotPushTwice`; Task 4,
   `TestOpenBatchSurvivesRestart`.
2. **Mail stays unread and untouched.** Test: Task 7, `TestFetchUsesPeekAndNeverStores` (the fake
   server fails the test on any `STORE`, `COPY`, `MOVE`, `EXPUNGE` or non-`PEEK` body fetch).
3. **A forged sender does not push.** Only the topmost `Authentication-Results` header whose
   authserv-id is `mx.google.com` counts; a forged header lower down, a second `From`, or a stale
   message is stored only. Test: Task 3, `TestForgedAuthResultsBelowGmailsIsIgnored`.
4. **No IV is ever reused** with one Bark key, and the encrypted payload is exactly what Bark's
   CryptoSwift decrypts. Test: Task 5, `TestEachSendDrawsANewIV` and
   `TestCiphertextMatchesBarkReferenceVector`.
5. **Event content never gains tools.** The read-only session exposes only `file_read`,
   `read_image` and `memory_get`, and dispatch refuses any other tool even if the model names it.
   Test: Task 12, `testReadOnlyPolicyFiltersDefinitions` and `testDispatchRefusesExcludedTool`.
6. **Quiet hours across midnight and DST changes.** Test: Task 4, `TestQuietHoursWrapAndDST`.

---

### Task 1: Module, config and CLI skeleton

**Files:**
- Create: `host/minis-hostd/go.mod`, `go.sum`, `main.go`
- Create: `host/minis-hostd/internal/config/config.go`, `config_test.go`
- Create: `host/minis-hostd/internal/cli/cli.go`, `cli_test.go`
- Create: `host/minis-hostd/testdata/config/valid.toml`, `testdata/config/*.invalid.toml`
- Modify: `.gitignore` (add `host/minis-hostd/dist/`)

**Interfaces:**
- Produces:
  ```go
  type Config struct {
      HostName   string        // the name the app gave this host; used in minis:// links
      Mail       []MailAccount // Gmail only in B
      GitHub     *GitHubSource
      Bark       Bark
      QuietHours *Window       // nil = none
      Timezone   string        // IANA name; empty = host local
  }
  type MailAccount struct {
      Name, Address, AppPassword string
      Allow                      []SenderRule // exact address or "@domain"
      GmailPrimaryOnly           bool
  }
  type SenderRule struct{ Pattern string; RequireDMARC bool } // RequireDMARC defaults to true
  type GitHubSource struct{ Token string; Reasons, Repos []string }
  type Bark struct{ Server, DeviceKey, EncryptionKey string }
  func Load(path string) (Config, error) // refuses mode != 0600, unknown keys, bad key alphabet
  ```
- Produces the CLI dispatcher with commands `run`, `events`, `batches`, `status`, `doctor`,
  `install-service`, `version`; unknown input exits 2 with `bad_request`.

- [ ] **Step 1: Create the module** with the pinned dependencies from the Tech Stack.
- [ ] **Step 2: Write config tests first:** valid file loads; mode 0644 is refused with a message
  naming `chmod 600`; an unknown key is refused; a Bark key with a character outside the alphabet
  or of the wrong length is refused naming the bad position; a sender rule without `@` and without
  a local part is refused.
- [ ] **Step 3: Implement `Load`** and the dispatcher; `version` prints `{schemaVersion, version}`.
- [ ] **Step 4: Run** `go test ./...` (PASS) and `go vet ./...` (clean).
- [ ] **Step 5: Commit** `feat(hostd): add minis-hostd module, config and CLI skeleton`.

### Task 2: Store

**Files:**
- Create: `host/minis-hostd/internal/store/{schema.sql,store.go,store_test.go}`

**Interfaces:**
- Produces a `Store` over `modernc.org/sqlite` with WAL mode and these operations:
  ```go
  func Open(path string, readOnly bool) (*Store, error)
  func (s *Store) Cursor(account string) (Cursor, bool, error)
  // RecordEvent inserts the event (unique key), advances the cursor and applies the pacing
  // decision (enqueue notice or join batch) in one transaction. A duplicate key is a no-op.
  func (s *Store) RecordEvent(e Event, cur *Cursor, d pacing.Decision) (inserted bool, err error)
  func (s *Store) CloseDueBatches(now time.Time) ([]Batch, error) // also enqueues their notices
  func (s *Store) PendingNotices(limit int) ([]Notice, error)
  func (s *Store) MarkNotice(key string, st NoticeState, lastErr string) error
  func (s *Store) ListEvents(limit int, before string) ([]Event, error)
  func (s *Store) GetEvent(id string) (Event, error)   // ErrNotFound
  func (s *Store) GetBatch(id string) (Batch, error)   // with its events, oldest first
  func (s *Store) Ack(ids []string, now time.Time) error
  func (s *Store) Prune(now time.Time) error           // 30 days
  func (s *Store) Stamp(source string, ok bool, detail string, now time.Time) error
  ```
- Tables as spec §6, plus `schema_version`.

- [ ] **Step 1: Tests first:** duplicate event key is a no-op and does not move the cursor twice;
  `RecordEvent` rolls back fully when the notice insert fails; a notice key is unique; a read-only
  store refuses writes; `Prune` keeps cursors and drops 31-day-old events, outbox rows and ring
  entries; `GetEvent` of an unknown id returns `ErrNotFound`.
- [ ] **Step 2: Implement** the schema and operations.
- [ ] **Step 3: Run** `go test ./internal/store/` (PASS).
- [ ] **Step 4: Commit** `feat(hostd): add SQLite store`.

### Task 3: Gate

**Files:**
- Create: `host/minis-hostd/internal/gate/{mail.go,github.go,authresults.go,gate_test.go}`
- Create: `host/minis-hostd/testdata/mail/*.eml` (real-shaped headers: Gmail-received DMARC pass,
  fail, none, forged lower header, two `From`, newsletter with `List-Unsubscribe`, noreply,
  `Auto-Submitted: auto-replied`)

**Interfaces:**
- Produces:
  ```go
  type Decision struct{ Action Action; Reason string } // Push, StoreOnly, Drop
  func Mail(m MailCandidate, rules []config.SenderRule, now time.Time) Decision
  func GitHub(n GitHubCandidate, src config.GitHubSource) Decision
  func DMARCFromGmail(headers []string) (pass bool, found bool) // topmost mx.google.com header only
  ```
- Mail order exactly as spec §5.1: malformed sender → too old → automated → allowlist → DMARC.

- [ ] **Step 1: Tests first,** one per `.eml` fixture and rule, including
  `TestForgedAuthResultsBelowGmailsIsIgnored`, `TestReplyToNeverMatchesAllowlist`,
  `TestDomainRuleMatchesSubdomainOnlyWhenWritten` (decide: `@example.com` does not match
  `a.example.com`), and `TestRequireDMARCFalseAdmitsWithoutAuth`.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run** `go test ./internal/gate/` (PASS).
- [ ] **Step 4: Commit** `feat(hostd): add the push gate`.

### Task 4: Pacing

**Files:**
- Create: `host/minis-hostd/internal/pacing/{pacing.go,quiet.go,pacing_test.go}`

**Interfaces:**
- Produces:
  ```go
  type State struct {
      LastPushAt   time.Time
      OpenBatchID  string    // "" = none
      BatchFlushAt time.Time
      PushesToday  int
      Day          string    // local date of PushesToday
      CapNoticeSent bool
  }
  type Decision struct{ Kind Kind; BatchFlushAt time.Time } // SendNow, JoinBatch, StoreCapped, SendCapNotice
  func Decide(s State, now time.Time, quiet *config.Window, loc *time.Location) Decision
  func NoticeText(events []EventSummary) (title, body string) // single or batch, 120-char limit
  ```

- [ ] **Step 1: Tests first:** lone event after quiet spell → `SendNow`; second event within 2 min
  → `JoinBatch` with flush at last push + 2 min; batch of one closes as a single notice; quiet
  hours `22:00–07:30` hold events and flush at 07:30 the next day; `TestQuietHoursWrapAndDST`
  across both DST changes in `Europe/Berlin` and a no-DST zone; 31st notice → one
  `SendCapNotice`, then `StoreCapped`; day rollover resets the count; `TestOpenBatchSurvivesRestart`
  (with Task 2's store); batch text lists distinct senders and repos in arrival order.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run** `go test ./internal/pacing/ ./internal/store/` (PASS).
- [ ] **Step 4: Commit** `feat(hostd): coalesce pushes, quiet hours and daily cap`.

### Task 5: Bark notifier

**Files:**
- Create: `host/minis-hostd/internal/notify/{notifier.go,bark.go,bark_test.go}`
- Create: `host/minis-hostd/testdata/bark/reference.json` (key, IV, plaintext and the ciphertext
  produced by CryptoSwift 1.8.4 during S3)

**Interfaces:**
- Produces:
  ```go
  type Notice struct{ Title, Body, URL string }
  type Notifier interface{ Send(ctx context.Context, n Notice) error }
  var ErrMaybeDelivered = errors.New("notifier: request may have been delivered")
  type Bark struct{ Server, DeviceKey, Key string; Client *http.Client; NewIV func() string }
  func GenerateKey() string // alphabet and length from Global Constraints
  ```
- HTTP status ≥ 400 returns a plain error (retryable); a timeout or a connection lost after the
  request was written returns `ErrMaybeDelivered` (not retried).

- [ ] **Step 1: Tests first:** `TestCiphertextMatchesBarkReferenceVector` (fixed IV via `NewIV`);
  `TestEachSendDrawsANewIV` over 1,000 sends; form fields are `ciphertext` and `iv` only, so no
  plaintext reaches the server (`httptest` asserts the body); 500 → retryable error; server closing
  after reading the body → `ErrMaybeDelivered`; `GenerateKey` uses only the alphabet.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run** `go test ./internal/notify/` (PASS).
- [ ] **Step 4: Commit** `feat(hostd): add encrypted Bark notifier`.

### Task 6: GitHub source

**Files:**
- Create: `host/minis-hostd/internal/source/github/{github.go,schedule.go,github_test.go}`
- Create: `host/minis-hostd/testdata/github/*.json` (notification payloads per reason)

**Interfaces:**
- Produces:
  ```go
  func NextPoll(prev time.Time, pollIntervalHeader string, rateReset string, status int) time.Time // pure
  func ToCandidate(n APINotification) gate.GitHubCandidate // html_url derived from the API URL
  type Source struct{ Token string; BaseURL string; Client *http.Client }
  func (s *Source) Poll(ctx context.Context, ifModifiedSince string) (cands []gate.GitHubCandidate, lastModified, pollInterval string, err error)
  ```
- Facts from S2: the API accepts a classic token with `notifications`; `304` costs no rate limit;
  `X-Poll-Interval` was 60.

- [ ] **Step 1: Tests first:** `If-Modified-Since` sent from the stored `Last-Modified`; `304` → no
  candidates and unchanged cursor; `X-Poll-Interval: 120` → next poll 120 s later, `30` → 60 s;
  403 with `X-RateLimit-Remaining: 0` → wait until reset; 401 → `ErrUnauthorized` with GitHub's
  message; event key `gh:<threadId>:<updatedAt>`; `html_url` derived for PullRequest, Issue and
  CheckSuite subjects; only `GET` is ever sent.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run** `go test ./internal/source/github/` (PASS).
- [ ] **Step 4: Commit** `feat(hostd): poll GitHub notifications`.

### Task 7: IMAP source (blocked on S1)

Start only after S1 has recorded Gmail's `IDLE` lifetime, the `Authentication-Results` shape and
`X-GM-RAW` behaviour in spec §4.1.

**Files:**
- Create: `host/minis-hostd/internal/source/imap/{cursor.go,imap.go,parse.go,imap_test.go}`

**Interfaces:**
- Produces:
  ```go
  type Cursor struct{ UIDValidity, LastSeenUID uint32 }
  // Pure: what to do with a mailbox state given the stored cursor.
  func Plan(stored *Cursor, uidValidity, uidNext uint32) (fetchFrom uint32, newCursor Cursor, reset bool)
  func Parse(raw []byte, internalDate time.Time) (gate.MailCandidate, error) // body ≤ 64 KiB, text/plain or HTML→text
  type Source struct{ Account config.MailAccount; Dial func(ctx context.Context) (*imapclient.Client, error) }
  func (s *Source) Run(ctx context.Context, emit func(gate.MailCandidate, Cursor) error) error
  ```

- [ ] **Step 1: Tests first:** first run baselines at `UIDNEXT-1` and emits nothing; same
  `UIDVALIDITY` resumes and emits mail received while offline; changed `UIDVALIDITY` rebaselines
  and reports `source_reset`; `TestFetchUsesPeekAndNeverStores`; IDLE notification triggers an
  immediate sweep; dropped connection reconnects with backoff and reconciles; unparseable message
  is recorded `parse_failed` once; a duplicate `Message-ID` is dropped; a 2 MiB message is
  truncated with `truncated: true`; HTML-only mail yields text.
- [ ] **Step 2: Implement** with go-imap v2 against `imapmemserver` in tests.
- [ ] **Step 3: Run** `go test ./internal/source/imap/` (PASS).
- [ ] **Step 4: Commit** `feat(hostd): watch Gmail over IMAP`.

### Task 8: Daemon

**Files:**
- Create: `host/minis-hostd/internal/daemon/{daemon.go,daemon_test.go}`

**Interfaces:**
- `func Run(ctx context.Context, cfg config.Config, st *store.Store, n notify.Notifier, clock func() time.Time) error`
- One goroutine per source, one outbox drainer, one batch closer (ticks every 5 s), one heartbeat,
  one daily pruner. Store writes are serialised through one goroutine.

- [ ] **Step 1: Tests first,** with fake sources, a fake clock and a recording notifier:
  `TestCrashBetweenCommitAndSendDoesNotPushTwice` (stop after commit, restart, exactly one send);
  `ErrMaybeDelivered` is marked sent-uncertain and never resent; HTTP 500 is retried until 1 h
  then marked failed; a source returning `ErrUnauthorized` stops, stamps its reason and retries
  after 30 min while the other source keeps running; heartbeat stamps every 60 s; SIGTERM drains
  in-flight sends and exits 0; a locked or corrupt database exits non-zero.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run** `go test -race ./internal/daemon/` (PASS).
- [ ] **Step 4: Commit** `feat(hostd): run sources, outbox and batches as a daemon`.

### Task 9: CLI contract

**Files:**
- Modify: `host/minis-hostd/internal/cli/cli.go`
- Create: `host/minis-hostd/internal/cli/{events.go,status.go,doctor.go,contract_test.go}`
- Create: `host/minis-hostd/testdata/contract/*.json` (one golden file per command and error code)

- [ ] **Step 1: Tests first:** each command's stdout equals its golden file byte for byte (fixed
  clock, fixed ids); errors exit 2 with the error golden file and a human line on stderr; the CLI
  opens the store read-only except `events ack`; `doctor` reports each check (IMAP login and
  `IDLE` capability, GitHub token scopes from `X-OAuth-Scopes`, clock skew against an HTTP `Date`,
  timezone, config mode) and `--push-test` sends one encrypted notice.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run** `go test ./internal/cli/` (PASS).
- [ ] **Step 4: Commit** `feat(hostd): add the events, batches, status and doctor commands`.

### Task 10: Service install, release build, install script

**Files:**
- Create: `host/minis-hostd/internal/service/{launchd.go,systemd.go,service_test.go}`
- Create: `host/minis-hostd/scripts/release.sh` (builds the four targets into `dist/` with SHA-256 sums)
- Create: `host/minis-hostd/scripts/install.sh` (downloads the release for `uname -s`/`uname -m`,
  verifies the sum, installs to `~/.minis/bin/`, writes a 0600 config template with the host name
  and a generated Bark key, runs `install-service`)
- Create: `host/minis-hostd/README.md`

- [ ] **Step 1: Tests first:** rendered launchd plist and systemd unit match golden files;
  `install-service` refuses to overwrite a unit it did not write.
- [ ] **Step 2: Implement;** `release.sh` output runs `version` on macOS and in the A1 sshd
  container (as in S4).
- [ ] **Step 3: Manual check on this Mac:** install, `doctor --push-test` reaches the iPhone,
  `launchctl print gui/$(id -u)/app.minis.hostd` shows it running; uninstall leaves nothing behind.
- [ ] **Step 4: Commit** `feat(hostd): install as a service and publish release builds`.

### Task 11: Contract types and `HostEventClient` in MinisRemote

**Files:**
- Create: `src/ios/Packages/MinisRemote/Sources/MinisRemote/HostEvents.swift`
- Modify: `src/ios/Packages/MinisRemote/Sources/MinisRemote/RemoteExecutor.swift` (expose a public
  control-exec entry; today `control(host:script:)` is internal)
- Test: `src/ios/Packages/MinisRemote/Tests/MinisRemoteTests/HostEventContractTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct HostEvent: Codable, Equatable, Sendable { … }   // fields of spec §8
  public struct HostEventBatch: Codable, Equatable, Sendable { public let id: String; public let events: [HostEvent] }
  public enum HostEventLink: Equatable { case event(host: String, id: String), batch(host: String, id: String) }
  public enum HostEventLinks { public static func parse(_ url: URL) -> HostEventLink? }
  public enum HostEventError: Error, Equatable { case notInstalled(host: String), server(code: String, message: String), schemaMismatch(found: Int), undecodable(String) }
  public struct HostEventClient: Sendable {
      public func event(host: String, id: String) async throws -> HostEvent
      public func batch(host: String, id: String) async throws -> HostEventBatch
      public func ack(host: String, ids: [String]) async throws
      public func status(host: String) async throws -> HostdStatus
  }
  ```
- Calls run `"$HOME/.minis/bin/minis-hostd" … --json` through the control path; exit 0 decodes,
  exit 2 maps to `.server`, exit 127 to `.notInstalled` (spec §9.4).

- [ ] **Step 1: Tests first:** every file in `host/minis-hostd/testdata/contract/` decodes (path via
  `#filePath`); `schemaVersion` 2 → `.schemaMismatch(2)`; link parsing accepts both forms and
  rejects other hosts' paths, empty ids and extra segments; event ids are shell-quoted in the
  command (`RemoteRunScripts.shellQuote`).
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run** `swift test --package-path src/ios/Packages/MinisRemote --filter HostEvent`
  (PASS) and the whole package (no regressions in the 269 A1 tests).
- [ ] **Step 4: Commit** `feat(remote-host): add host event contract and client`.

### Task 12: Opening events, read-only policy

**Files:**
- Create: `src/ios/Agent/HostEvents/{HostEventOpener.swift,SessionToolPolicy.swift,HostEventPrompt.swift}`
- Create: `src/ios/Views/Remote/ReadOnlySessionBanner.swift`
- Modify (upstream, marked): `src/ios/Shared/DeepLinkRouter.swift`,
  `src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift`,
  `src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift`,
  `src/ios/Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift` (a `.hostEvent` origin, since no
  existing case fits: `.cli`, `.shortcut`, `.job`)
- Test: `src/ios/MinisTests/HostEvents/{HostEventOpenerTests,SessionToolPolicyTests}.swift`
- Test: `src/ios/MinisUITests/HostEventLinkUITests.swift`

**Interfaces:**
- `SessionToolPolicy`: a fork-owned JSON store in Application Support keyed by session id, with
  `readOnly(sessionId:) -> Bool` and `clear(sessionId:)`; allowed tools `file_read`, `read_image`,
  `memory_get`.
- `HostEventOpener.open(_ link: HostEventLink)` runs from the app root (spec §9.1, S3).

- [ ] **Step 1: Tests first:** `testReadOnlyPolicyFiltersDefinitions`;
  `testDispatchRefusesExcludedTool` (a `shell_execute` call in a read-only session returns a tool
  error and never reaches A1 routing or iSH); the prompt wraps each event as untrusted data and
  ends with the fixed request; an unknown host shows the Settings message; `.notInstalled` shows the
  Notifications-screen message; ack is sent with every id after the session exists; "Turn tools on"
  clears the policy for that session only.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: UI test in the Simulator:** with a fake client injected, `xcrun simctl openurl` a
  `pico://host-event/<host>/batch/<id>` link while the app sits on the welcome screen and again on
  a cold start; assert the banner and one session.
- [ ] **Step 4: Run** `MinisTests` (Remote and HostEvents classes) and the UI test (PASS).
- [ ] **Step 5: Commit** `feat(remote-host): open host events in a read-only session`.

### Task 13: Settings → Remote Hosts → host → Notifications

**Files:**
- Create: `src/ios/Views/Remote/HostNotificationsView.swift`
- Modify: the A1 host detail view in `src/ios/Views/Remote/` (fork-owned) to link to it
- Modify: `src/ios/Views/Remote/RemoteHost.xcstrings`
- Test: `src/ios/MinisTests/HostEvents/HostNotificationsModelTests.swift`

- [ ] **Step 1: Tests first** for the view model: install command quotes the host name and pins the
  release URL and SHA-256; status maps running / stale heartbeat ("Not running since …") / not
  installed; recent events list opens through `HostEventOpener`; test push surfaces `doctor`'s
  failing check verbatim.
- [ ] **Step 2: Implement;** every string goes through the catalog (numbers interpolated as
  `String`, as in A1).
- [ ] **Step 3: Run** `MinisTests` (PASS); check the screen in the Simulator at the largest
  Dynamic Type size.
- [ ] **Step 4: Commit** `feat(remote-host): add the Notifications screen`.

### Task 14: Acceptance

**Files:**
- Create: `docs/remote-agent/b-push/acceptance.md`

- [ ] **Step 1:** Write the checklist from spec §1 and `scope.md` Acceptance: allowlisted mail within
  60 s, newsletter silent, GitHub review request exactly once across a restart, a burst becomes
  one batch, quiet hours flush, tap opens a read-only session from the home screen and from a cold
  start, Bark never receives plaintext, mail stays unread, same binary on the Mac mini and a Linux
  host.
- [ ] **Step 2:** Run it on this Mac mini and the iPhone; record results.
- [ ] **Step 3: Commit** `docs(remote): add B acceptance`.

## Order and dependencies

```
1 ─ 2 ─┬─ 3 ─┐
       ├─ 4 ─┤
       ├─ 5 ─┼─ 8 ─ 10 ───────────┐
       ├─ 6 ─┤                    ├─ 14
       ├─ 7*┘                     │
       └─ 9 ─ 11 ─ 12 ─ 13 ───────┘
```

`*` Task 7 waits for S1.

Task 9's `events`, `batches` and `status` commands need only the store (Task 2), so the app side
(Tasks 11–13) can run in parallel with Tasks 3–8. `doctor` gains its checks as their pieces land:
the push test with Task 5, the GitHub scope check with Task 6, the IMAP check with Task 7.
