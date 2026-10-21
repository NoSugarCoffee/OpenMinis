# B — Proactive push (`minis-hostd`): scope

Status: scoped; the design is in [`spec.md`](spec.md), which supersedes this page where they differ. Depends on A1, because the event body is fetched over A1's SSH
connection. Decisions referenced as D*/Q* are in [`../decisions.md`](../decisions.md).

## What it delivers

New email from people who matter, and GitHub activity that needs the user, reach the iPhone as
notifications. Tapping one opens the event in Pico as untrusted content in a read-only session.

## Shape

```
Host
 └─ minis-hostd          Go binary or Docker image (D15); systemd / launchd / container
      ├─ sources   IMAP (IDLE + reconcile) · GitHub notifications API
      ├─ gate      allowlists · dedup · quiet hours · coalescing · drop automated mail (no model call, D14)
      ├─ store     SQLite: cursors, events, notice keys, liveness                       (retention D16)
      ├─ notifier  pluggable: Bark (D13) · ntfy · Telegram · webhook
      └─ CLI       minis-hostd events list|get|ack --json   (versioned contract)
             │ push: title + one-line summary + pico://host-event/<host>/<id>   (body stays on the host, D5)
Pico ◄──────┘ tap → events get over SSH → wrap as untrusted → read-only session (D17)
```

## Scope

**Sources**
- **IMAP.**
  - **Change detection:** IDLE plus periodic reconciliation, with a full sweep on every reconnect.
  - **Cursor:** `{uidValidity, lastSeenUid}`. First run takes a baseline and processes nothing old.
    The cursor is persisted before an event is emitted.
  - **Dedup:** the key is `account:uidValidity:uid`, plus a ring of recent Message-IDs.
  - **Limits:** a batch size and a body-size cap.
  - **Credentials:** live in the host's own secret store (a 0600 file or container secrets), never
    in an event.
- **GitHub.** Polls the notifications API, honouring `X-Poll-Interval` and `Last-Modified`.
  Mentions, review requests, assignments and CI failures become events. The token is a
  classic PAT with only the `notifications` scope (the API refuses fine-grained tokens; spec §4.2).

**Gate** (rules only)
- **Allowlists:** a sender allowlist for mail; a repo and reason filter for GitHub.
- **Automated mail is dropped:** `Auto-Submitted`, `Precedence: bulk`, `List-Unsubscribe`, noreply.
- **Quiet hours:** the window may wrap past midnight.
- **Coalescing and daily cap:** a burst becomes one batch push; the cap counts notices (spec §5.3).
- **Notice keys:** `mail:<acct>:<uv>:<uid>`, `gh:<threadId>:<updatedAt>`. A key is inserted only
  if absent, so each notice is delivered at most once across retries and restarts.

**Contract and app**
- **`minis-hostd events list|get|ack --json`:** carries a `schemaVersion`. The app depends on
  this contract, never on the host's OS.
- **Deep link:** fetches the event over SSH, wraps it as untrusted content and opens a read-only
  session (no shell writes, no send, no browser) until the user continues in a normal session.
- **Liveness:** hostd stamps a heartbeat, and the app shows "host offline since …" when the stamp
  is stale.

**Setup**
- **Install:** one command: binary plus service unit (Docker deferred; spec §10).
- **`minis-hostd doctor`:** checks the IMAP login, the GitHub token, a test push, and the clock and
  timezone.

## Out of scope

- An agent loop or model keys on the host (D4).
- Model summaries before a push (D14).
- GitHub webhooks and a public endpoint.
- Gmail API, DMARC, calendar and heartbeat watchers (v2+).
- macOS-only host plugins.
- Android.

## Acceptance

1. Mail from an allowlisted sender reaches the iPhone within 60s while IDLE is supported. A
   newsletter, or mail from a sender not on the allowlist, does not.
2. A GitHub review request arrives within one poll interval, exactly once, even across a hostd
   restart.
3. Tapping the notification opens the event as untrusted data in a read-only session, and the push
   provider never receives the body.
4. The same binary and the same app work, unchanged, on a Mac mini and on a Linux VPS.
5. Unit tests cover:
   - the cursor, baseline and UIDVALIDITY rules
   - notice-key dedup
   - quiet hours that wrap past midnight
   - automated-mail detection
   - GitHub poll-interval handling
   - the CLI contract, against golden files
