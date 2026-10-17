# Remote agent

Give Minis an always-on computer of the user's own, and let it reach out when something needs
attention.

1. **Remote computer**: the agent works on a real machine over SSH, not in the emulated iSH
   sandbox, which is slow, has no logged-in state and dies when iOS suspends the app.
2. **Proactive push**: email and GitHub events reach the phone as first-class notifications.

Fork only, iOS only. All decisions are in [`decisions.md`](decisions.md).

## Status

| Piece | What it delivers | Status | Docs |
|---|---|---|---|
| **A1** | Sessions bound to a host; shell and file tools run there; long commands survive app suspension | **Implemented and reviewed; device acceptance pending** | [spec](a1-remote-exec/spec.md) · [plan](a1-remote-exec/plan.md) · [acceptance](a1-remote-exec/acceptance.md) |
| A2 | Browser with the user's login state; screenshots and screen control by the agent | Not designed | — |
| A3 | In-app screen viewer with take-over | Not designed | — |
| B | `minis-hostd`: email and GitHub events → rule gate → push → read-only session in Minis | Scoped | [scope](b-push/scope.md) |
| Later | Heartbeat with the proactivity dial (v2) · trust core (v3) · webhooks, Gmail API, Android (v4) | — | — |

## Shape

```
Host (any SSH-reachable Unix machine)
 ├─ sshd               A1  commands and files
 ├─ Chrome (CDP)       A2  browser with the user's logins
 ├─ desktop + VNC      A3  screen the agent operates and the user can take over
 └─ minis-hostd        B   IMAP / GitHub → rule gate → push (body stays on the host)
          │ push: one-line summary + minis://host-event/<id>
Minis on iPhone ◄─┘   the agent loop and model keys live here; fetches over SSH
```

## Reading guide

- **To approve or change direction:** this page, then [`decisions.md`](decisions.md).
- **To implement A1:** [`a1-remote-exec/spec.md`](a1-remote-exec/spec.md), then
  [`a1-remote-exec/plan.md`](a1-remote-exec/plan.md).
- **To design B:** [`b-push/scope.md`](b-push/scope.md) and the open questions in
  [`decisions.md`](decisions.md#open-settle-when-b-is-designed).

Background research (comparisons with OpenClaw, Hermes, nanoMuse, Huginn, n8n, OpenMuse and closed
products) is kept locally in `research/`, outside git.
