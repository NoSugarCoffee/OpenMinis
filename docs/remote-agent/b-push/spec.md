# B — Proactive push (`minis-hostd`)

Date: 2026-10-18. Status: draft for review. Spikes (§13) run before the implementation plan.
Scope: iOS only, fork only (D7). Builds on A1: the event body is fetched over A1's SSH connection.

Part of [`../README.md`](../README.md); decisions are in [`../decisions.md`](../decisions.md) (D13–D18
settle B's open questions). Scope: [`scope.md`](scope.md).

## 1. Goal

New mail from people who matter, and GitHub activity that needs the user, reach the iPhone as
notifications within a minute. Tapping one opens the event in Minis as untrusted content in a
read-only session.

**Success for B**: with `minis-hostd` running on the Mac mini, mail from an allowlisted sender to
the user's Gmail and a GitHub review request each arrive as one Bark notification. Tapping it opens
Minis, which fetches the body over SSH and summarises it without being able to run a command. A
newsletter produces nothing. The same binary runs unchanged on a Linux VPS.

## 2. Principles

- **Rules, not models, decide what pushes** (D14). The host holds no model keys (D4).
- **Bodies stay on the host** (D5). A push carries a title, one line and an event id, and is
  end-to-end encrypted to the Bark app (§7).
- **Read-only on every source.** hostd never marks mail read, never changes a label, never marks a
  GitHub thread read. The user's other clients see exactly what they saw before.
- **At most one push per notice**, across retries and restarts (§5.4).
- **No listener.** hostd opens no port; it only dials out (IMAP, GitHub, Bark). The app reaches it
  through `sshd`, like every other A1 command.
- **Fail loudly.** A source that cannot log in stops, records why, and `status` and the app show it.
  It never silently skips mail.

## 3. Architecture

### 3.1 Host

```
~/.minis/bin/minis-hostd                one static Go binary (D15), darwin/linux × arm64/amd64
~/.minis/hostd/config.toml   0600       accounts, allowlists, quiet hours, Bark key
~/.minis/hostd/state.db                 SQLite: cursors, events, outbox, heartbeat

minis-hostd run           the daemon, started by launchd (macOS) or a systemd user unit (Linux)
 ├─ source/imap           IDLE on INBOX + reconcile → candidate events
 ├─ source/github         polls /notifications → candidate events
 ├─ gate                  pure rules → push / store only / drop
 ├─ store                 one transaction per event: insert event + advance cursor + enqueue notice
 └─ notifier/bark         drains the outbox
minis-hostd events …      the contract the app calls over SSH (§8)
minis-hostd status|doctor|install-service
```

The code lives in this repo under `host/minis-hostd/` as its own Go module. Dependencies:
`github.com/emersion/go-imap/v2` (IMAP with IDLE), `modernc.org/sqlite` (pure Go, so
`CGO_ENABLED=0` cross-builds work), `github.com/BurntSushi/toml`. GitHub and Bark are plain
`net/http`.

Decision logic is written as pure functions over plain values, as in A1: the cursor rules, the
gate, quiet hours, automated-mail detection, poll scheduling, notice keys and the CLI encoding.

### 3.2 App

```
Minis (iOS)
 ├─ DeepLinkRouter        minis://host-event/<host>/<id>  → HostEventOpener
 ├─ HostEventClient       runs `~/.minis/bin/minis-hostd events get|list|ack|status --json` via SSHConnectionPool.exec
 ├─ HostEventOpener       fetch → new session with the read-only policy → wrapped event as first prompt → ack
 ├─ SessionToolPolicy     per-session allowlist of tools; makeAgentTools filters, dispatch enforces
 └─ Settings → host → Notifications   install command, status, test push, recent events
```

New code lives in `src/ios/Agent/HostEvents/` and `src/ios/Views/Remote/`. The event types and their
decoding go in the `MinisRemote` package, so they are tested against the same golden files as the Go
side (§12).

### 3.3 Integration points in upstream files

Each edit is marked `// fork(remote-host):`.

1. **`Shared/DeepLinkRouter.swift`**: a `case "host-event"` that hands the URL to `HostEventOpener`.
2. **`Agent/Chat/AIChatViewModel+ToolDefinitions.swift`, `makeAgentTools()`**: one filter through the
   session's `SessionToolPolicy`, next to the existing `includeMemoryTools` gate.
3. **`Agent/Chat/AIChatViewModel+ConcurrentTools.swift`**: one guard beside A1's routing call that
   rejects a tool the policy excludes, in case a model calls a tool it was not offered.
4. **`Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift`**: a `ProgrammaticPromptOrigin` case for a
   host event, if no existing origin fits (settled in the plan).

## 4. Sources

### 4.1 Gmail over IMAP (D18)

- **Login:** `imap.gmail.com:993`, TLS, the Gmail address and an app password. App passwords need
  2-Step Verification on the Google account. Gmail API and OAuth are out of scope.
- **Mailbox:** `INBOX` only.
- **Change detection:** `IDLE`, re-issued every 9 minutes (Gmail's IDLE limit is checked in S1). On
  every (re)connect and every 15 minutes, a reconcile runs `UID SEARCH UID <lastSeenUid+1>:*`.
- **Cursor:** `{uidValidity, lastSeenUid}` per account.
  - **First run:** records the current `UIDNEXT - 1` as `lastSeenUid` and emits nothing, so old mail
    never pushes.
  - **`UIDVALIDITY` changed:** take a new baseline, emit nothing, and record a `source_reset` line in
    `status`. Re-pushing a whole mailbox is worse than missing the gap.
- **Fetch:** `BODY.PEEK[]` (never `BODY[]`, which sets `\Seen`), capped at 1 MiB per message. Larger
  messages keep their headers, the first 1 MiB of text and a `truncated: true` flag.
- **Body for the event:** `text/plain` if present, otherwise the HTML part converted to text. Capped
  at 64 KiB. Attachments are listed by name, type and size only, never stored.
- **Optional Gmail category filter:** `gmail_primary_only = true` keeps only UIDs matching
  `X-GM-RAW "category:primary"` (checked in S1). Off by default; the allowlist already decides.
- **Event key:** `mail:<account>:<uidValidity>:<uid>`. A ring of the last 1,000 `Message-ID`s drops a
  message seen twice, for example after a move back into INBOX.
- **Unreadable messages:** a message the parser cannot read is stored as `parse_failed` and skipped
  at once, since the same bytes will fail again. A transient failure (a dropped fetch) is retried up
  to 3 times, then skipped with its reason. Skipped mail stays in the mailbox untouched.

### 4.2 GitHub notifications

- **Token:** a classic personal access token with only the `notifications` scope. The notifications
  API does not accept fine-grained tokens (checked in S2; `scope.md` assumed it did). The
  `notifications` scope reads notifications and grants no repository access.
- **Polling:** `GET /notifications` with `If-Modified-Since: <last Last-Modified>`. The interval is
  `max(X-Poll-Interval, 60 s)`. A `304` costs nothing against the rate limit.
- **Kept reasons:** `mention`, `team_mention`, `review_requested`, `assign`, `ci_activity` (GitHub
  sends `ci_activity` for workflow runs the user triggered; the user's GitHub setting decides whether
  successes are included). Everything else is stored only if the config asks for it.
- **Body for the event:** repo, reason, subject type, subject title, the subject's `html_url`
  (derived from the API URL), thread id and `updated_at`. hostd fetches nothing else, since that
  would need repository access.
- **Event key:** `gh:<threadId>:<updatedAt>`, so new activity on the same thread is a new event.

## 5. Gate

Pure function: `(candidate, config, now, recentNotices) → push | storeOnly(reason) | drop(reason)`.
Every decision and its reason is stored with the event, so `events list` explains why something did
or did not push.

### 5.1 Mail

1. **Malformed sender:** a message with no `From` or more than one `From` address is stored only.
   The display name and `Reply-To` never count.
2. **Too old:** a message whose IMAP internal date is more than 48 hours old is stored only, so a
   long outage or a reconcile never pushes stale mail.
3. **Drop automated mail:** any of `Auto-Submitted` other than `no`; `Precedence: bulk|list|junk`;
   `List-Unsubscribe` or `List-Id`; a sender local part matching `no-?reply|notifications?|mailer-daemon`.
4. **Allowlist:** push only if the `From` address matches an entry. An entry is an exact address
   (`alice@example.com`) or a domain (`@example.com`). Anything else is stored only.
5. **Sender authentication:** an allowlisted `From` is forged easily, so a push also needs
   `dmarc=pass` in the topmost `Authentication-Results` header whose authserv-id is `mx.google.com`.
   Gmail writes that header on receipt, so hostd trusts it for this mailbox only and does no DKIM
   checking of its own. A per-entry `require_dmarc = false` admits a sender that cannot pass DMARC.
   A failed check stores the event with reason `sender_unauthenticated`.

### 5.2 GitHub

Push if the reason is in the kept list and the repo matches the repo filter (`owner/*` or
`owner/name`; empty means all). Otherwise store only.

### 5.3 Pacing

- **Quiet hours:** `start`–`end` in the host's timezone; the window may wrap past midnight
  (`22:00`–`07:30`). Events inside it are stored. When the window ends, one push summarises them:
  "3 events while quiet: 2 mail, 1 GitHub".
- **Cooldown:** at most one push per sender (mail) or thread (GitHub) per 10 minutes. Later events in
  the window are stored and noted in the next push for that key.
- **Daily cap:** 30 pushes per local day. The 31st event sends one "Daily cap reached" push; the
  rest are stored.

### 5.4 Delivery

- The event, the cursor advance and its notice (if pushing) are written in one SQLite transaction.
  A crash before commit refetches the message; the event key makes the retry a no-op.
- The notifier drains the outbox. A notice key is unique, so it is enqueued at most once.
- **Retry rule:** an HTTP error status from Bark is retried with backoff for up to 1 hour. A
  timeout, or a connection dropped after the request was sent, is not retried, since Bark may have
  delivered it. This keeps "at most once".

### 5.5 Notice text

- Mail: title `<sender name>`, body `<subject>`.
- GitHub: title `<owner/repo>`, body `<reason>: <subject title>`.
- Both are truncated to 120 characters. The tap URL is `minis://host-event/<host>/<event id>`, where
  `<host>` is the name the app gave this host (written into the config by the app's install
  command).

## 6. Store and retention

SQLite tables: `cursors`, `events` (id, key, source, created_at, title, summary, body JSON,
decision, reason, acked_at), `outbox` (notice key, event id, state, attempts, last_error),
`message_ids`, `heartbeat`.

- **Event id:** a ULID, so ids sort by time.
- **Retention (D16):** a daily job deletes events, outbox rows and message-id ring entries older than
  30 days. Cursors and the heartbeat are kept.
- **Heartbeat:** the daemon stamps `heartbeat.at` every 60 s and each source stamps its last success
  or last error.

## 7. Notifier: Bark (D13)

- **Request:** `POST https://api.day.app/push` (or a self-hosted `bark-server`) with the device key,
  title, body, `url` (the `minis://` link), `group: "minis"`.
- **Encryption:** on by default. The fields are sent as AES-256-GCM `ciphertext` with the key set in
  the Bark app, so Bark's server and APNs see only the device key and timing. The exact request
  format is checked in S3.
- **Interface:** the notifier is a small Go interface (`Send(ctx, Notice) error` plus a
  "may have been delivered" error kind). The built-in push of §15, ntfy, Telegram or an iMessage
  sender on macOS hosts can be added later without touching the gate.
- **The app never depends on Bark.** Everything after the tap starts from the
  `minis://host-event/<host>/<id>` link, so the app works the same whichever notifier showed the
  notification.

Bark is a stopgap with a cost: the user installs a second app, the notification shows as Bark,
and the tap passes through Bark with an "Open in Minis?" prompt. It is chosen because this fork is
not distributed (§15).

## 8. CLI contract

The app depends on this contract, never on the host's OS. Every output is one JSON object with
`"schemaVersion": 1`. The app refuses a different major version with "Update minis-hostd on
<host>". Golden files in `host/minis-hostd/testdata/contract/` are shared with the app's tests.

| Command | Output |
|---|---|
| `events list --limit N [--before <id>] --json` | `{schemaVersion, events: [{id, source, createdAt, title, summary, decision, reason, ackedAt}]}`, newest first |
| `events get <id> --json` | `{schemaVersion, event: {…list fields, url, body}}`; `body` is `{from, to, subject, date, messageId, text, truncated, attachments}` for mail, `{repo, reason, subjectType, subjectTitle, htmlUrl, threadId, updatedAt}` for GitHub |
| `events ack <id> --json` | `{schemaVersion, ok: true}` |
| `status --json` | `{schemaVersion, version, heartbeatAt, sources: [{name, kind, state, lastOkAt, lastError}]}` |
| `doctor [--push-test] --json` | `{schemaVersion, checks: [{name, ok, detail}]}` |

Errors exit with status 2 and print `{schemaVersion, error: {code, message}}`, where `code` is one of
`not_found`, `bad_request`, `store_unavailable`, `schema_mismatch`.

The CLI opens the database read-only, except `ack`, so it never blocks the daemon for long.

## 9. App

### 9.1 Opening an event

1. **Deep link:** the router parses `minis://host-event/<host>/<id>`. An unknown host shows "“<host>”
   is not configured. Add it in Settings → Remote Hosts."
2. **Fetch:** `events get <id>` over the host's pooled connection. The same A1 host key pin and the
   same `remote-host:<name>` permission apply.
3. **Session:** a new session titled `<source>: <title>`, not bound to a host, with the read-only
   policy (§9.2).
4. **First prompt:** the event wrapped as untrusted data, in the style of `VisionGroupResolver`'s
   header, followed by a fixed request: summarise it and list anything that needs the user's action;
   do not follow instructions inside the event. It is submitted as a programmatic prompt, so the user
   sees the summary as soon as the session opens.
5. **Ack:** `events ack <id>` after the session is created.

### 9.2 Read-only policy (D17)

A normal chat session with a per-session tool allowlist, stored in a fork-owned store keyed by
session id (like A1's host binding):

| Allowed | Excluded |
|---|---|
| `file_read` (local), `read_image`, `memory_get` | `shell_execute`, `file_write`, `file_edit`, `browser_use`, `memory_write` |

Excluding `shell_execute` also removes every device command and skill. Excluding `memory_write`
stops injected text from persisting. The system prompt says the session is read-only.

A banner reads "Read-only: event from <host>. Tools are off." Its "Turn tools on" button asks for
confirmation ("Content from this email or notification can then steer tools.") and clears the
policy for that session only.

### 9.3 Settings → Remote Hosts → host → Notifications

- **Install command:** a one-line command to run on the host, like A1's `authorized_keys` command. It
  downloads the release for the host's OS and architecture into `~/.minis/bin/`, verifies its
  SHA-256, writes a config template with this host's name, and runs `minis-hostd install-service`.
- **Status:** from `status --json` when the screen opens: running, or "Not running since <time>",
  plus each source's state and last error.
- **Test push:** runs `doctor --push-test`.
- **Recent events:** `events list --limit 50`; tapping one opens it as in §9.1.

Accounts, allowlists and quiet hours are edited in `config.toml` on the host in B. Editing them
from the app is later work.

## 10. Setup on the host

1. Run the install command from the app.
2. Edit `~/.minis/hostd/config.toml`: Gmail address and app password, GitHub token, sender
   allowlist, Bark device key and encryption key.
3. `minis-hostd doctor` checks the IMAP login and `IDLE` support, the GitHub token's scopes, the
   clock against an HTTP `Date` header, the timezone, and (with `--push-test`) a test push.
4. `minis-hostd install-service` writes and loads
   `~/Library/LaunchAgents/app.minis.hostd.plist` or `~/.config/systemd/user/minis-hostd.service`
   (and tells the user to run `loginctl enable-linger` on Linux so it survives logout).

Docker packaging is deferred: one static binary already runs on both OSes.

## 11. Errors

| Failure | Behaviour |
|---|---|
| IMAP login rejected | Source stops; `status` shows "Gmail rejected the app password"; retried every 30 min |
| IMAP connection drop | Reconnect with backoff (5 s → 5 min), then reconcile |
| GitHub `401`/`403` | Source stops with the response message; retried every 30 min |
| GitHub rate limit | Wait until `X-RateLimit-Reset` |
| Bark HTTP error | Retry with backoff for 1 hour, then mark the notice failed |
| Database locked or corrupt | Daemon exits non-zero so the service manager restarts it and logs the error |
| App: hostd missing | "minis-hostd is not installed on <host>." with a link to the Notifications screen |
| App: event pruned | "This event is older than 30 days and was deleted on <host>." |

## 12. Testing

**Go, unit (pure functions):** the cursor and baseline rules, `UIDVALIDITY` reset, notice-key
dedup, the Message-ID ring, multiple-`From` and freshness rejection, `Authentication-Results`
parsing (topmost trusted header only, a forged header lower down ignored), quiet hours including windows that wrap past midnight and DST changes,
automated-mail detection, the allowlist, cooldown and daily cap, poll-interval scheduling, Bark
request encoding and encryption, and the CLI encoding against the golden files.

**Go, integration:** an in-process IMAP server (`go-imap/v2`'s `imapmemserver`) for IDLE, reconnect
and restart; `httptest` servers standing in for GitHub and Bark. One test kills the daemon between
commit and send and checks that nothing is pushed twice.

**App:** decoding the golden files in `MinisRemote`, deep-link parsing, `makeAgentTools` under the
read-only policy, the dispatch guard, and an opener test against a fake `HostEventClient`. A UI test
in the Simulator opens a `minis://host-event` link and checks the banner and summary.

## 13. Spikes before the plan

| # | Question | Done when |
|---|---|---|
| S1 | Gmail: app-password login, how long `IDLE` lasts, `X-GM-RAW` category search, `BODY.PEEK` leaving mail unread, the `Authentication-Results` header Gmail writes | A Go script against the user's Gmail shows each |
| S2 | GitHub: `/notifications` with a classic token scoped to `notifications` only; a fine-grained token is refused | Both responses recorded |
| S3 | Bark: encrypted request format; tapping a notification opens `minis://host-event/…` in Minis | Push received and tap lands in Minis on the iPhone |
| S4 | A1 exec of `~/.minis/bin/minis-hostd` under the host's login-shell rules, on macOS and Linux | `status --json` returned to the app from both |

## 14. Prior art

Both projects below run the agent and its model keys on the host (a "gateway"), so an event can
start a model turn there. B keeps the agent on the phone (D4): the host filters and notifies, and
the model runs only when the user taps. Read 2026-10-18 from their repositories.

| | Hermes (NousResearch/hermes-agent) | OpenClaw (openclaw/openclaw) |
|---|---|---|
| Mail | Email adapter polls IMAP every 15 s; meant as a dedicated address people write to, not a watcher on the user's own inbox | Gmail through Pub/Sub to a public HTTPS hook (Tailscale Funnel); other mailboxes through an IMAP plugin (IDLE plus reconcile) |
| GitHub | Inbound webhooks on port 8644 with HMAC checks; a `deliver_only` mode forwards without a model | Generic inbound webhooks |
| Untrusted content | Per-route tool sets | Per-message isolated `mail_reader` agent in a sandbox with almost no tools |
| Scheduled | Cron jobs, including script-only jobs with no model call | Heartbeat: a model turn every 30 min |
| Delivery | Chat platforms (Telegram, Slack, …) | Chat platforms |

Taken from OpenClaw's IMAP plugin, which matches §4.1 closely (no flag changes, no backfill,
`UIDVALIDITY` rebaseline, body cap): rejecting multiple `From` addresses, the 48-hour freshness
check, DMARC before an allowlist match counts, and skipping unparseable mail instead of retrying it.

Rejected for B: webhooks (they need a public endpoint, which §2 rules out) and running a model per
event on the host (D4). Lighter builds were weighed on 2026-10-18 (iOS Mail VIP notifications plus
sharing to Minis; a polling script with no app changes) and set aside in favour of this design,
because neither opens the event in Minis behind the read-only policy.

## 15. Later: built-in push

Minis showing its own notifications needs three things this fork does not have yet:

1. **A paid Apple Developer account.** The free Personal Team has no push capability, and a free
   signed build expires after 7 days.
2. **Distribution** (TestFlight or the App Store) under the fork's own bundle ID. APNs only accepts
   pushes signed with the key of the team that signed the app, so every user must run a build
   signed by that one team.
3. **A relay.** That APNs key can push to every app of the team, so it never leaves the publisher:
   hosts send to a small relay service the publisher runs (a Cloudflare Worker is enough), which
   forwards to APNs. This is what Bark's own server does for Bark.

The design when those exist:

- **Registration:** Minis registers for remote notifications and writes its device token, a relay
  credential and a fresh AES key into the host's hostd config over A1's SSH connection.
- **Sending:** a `relay` notifier encrypts the notice with that key and posts it to the relay,
  authenticated by the credential. The relay sees only the token, ciphertext and timing, so D5
  holds.
- **Display:** a Notification Service Extension decrypts the notice before it is shown. A tap opens
  the same `minis://host-event` route as today.
- **Testing:** the Simulator accepts pushes through `xcrun simctl push`, so the app side can be
  built before the relay exists.

Bark stays as the notifier for self-built installs.

## 16. Out of scope for B

- Model summaries before a push (D14), and any model key on the host (D4).
- GitHub webhooks and any public endpoint.
- Gmail API, OAuth (and so Outlook personal accounts), other mailboxes than INBOX.
- Editing hostd's config from the app.
- Docker packaging.
- Notifications delivered by Minis itself (§15).
- Android.

## 17. Known limitations

- A dead hostd is noticed only when the user opens the Notifications screen or an event; nothing can
  push "I stopped".
- The push title and summary still reach the iPhone's lock screen; turning off previews is the
  user's iOS setting.
- A model reply in the read-only session can contain a link built from the event; the user decides
  whether to tap it.
