# Remote agent

Give Minis an always-on computer of the user's own, and let it reach out when something needs
attention.

1. **Remote computer**: the agent works on a real machine over SSH, not in the emulated iSH
   sandbox, which is slow, has no logged-in state and dies when iOS suspends the app.
2. **Proactive push**: the host watches email and GitHub for what needs the user, notifies the
   phone, and Minis opens each event read-only and explains it.

Fork only, iOS only. All decisions are in [`decisions.md`](decisions.md).

## Status

| Piece | What it delivers | Status | Docs |
|---|---|---|---|
| **A1** | Sessions bound to a host; shell and file tools run there; long commands survive app suspension | **Accepted on the iPhone** (2026-10-21); a Linux host and four items to run | [spec](a1-remote-exec/spec.md) · [plan](a1-remote-exec/plan.md) · [acceptance](a1-remote-exec/acceptance.md) |
| Pairing | Add a host by running `minis-hostd pair` and scanning its code; no keys to copy or fingerprints to check | **Merged and in use** (minis-hostd 0.2.1): the Mac mini was added by scanning | [spec](pairing/spec.md) |
| A2 | Browser with the user's login state; screenshots and screen control by the agent | **Step 1 accepted** (ego-browser through A1) on the Mac mini and the iPhone | [spec](a2-browser/spec.md) |
| A3 | In-app screen viewer with take-over | **Merged**; device checks 1, 2, 4, 6 pass; the handoff link (check 3) is not built | [spec](a3-screen/spec.md) |
| B | **Proactive push**: `minis-hostd` watches email and GitHub → rule gate → notification → Minis explains the event in a read-only session | **Accepted on the iPhone** (2026-10-21) except a real push tap and a batch | [scope](b-push/scope.md) · [spec](b-push/spec.md) · [plan](b-push/plan.md) · [acceptance](b-push/acceptance.md) |
| Later | Built-in push once the app is distributed (B spec §15) · heartbeat with the proactivity dial (v2) · trust core (v3) · webhooks, Gmail API, Android (v4) | — | — |

## Shape

```
Host (any SSH-reachable Unix machine)
 ├─ sshd               A1  commands and files
 ├─ ego lite           A2  browser with the user's logins, driven by `ego-browser`
 ├─ Screen Sharing/VNC A3  screen the user watches and takes over, tunnelled over SSH
 └─ minis-hostd        B   IMAP / GitHub → rule gate → push (body stays on the host)
          │ push: one-line summary + pico://host-event/<host>/<id>
Minis on iPhone ◄─┘   the agent loop and model keys live here; fetches over SSH
```

## Reading guide

- **To approve or change direction:** this page, then [`decisions.md`](decisions.md).
- **To implement A1:** [`a1-remote-exec/spec.md`](a1-remote-exec/spec.md), then
  [`a1-remote-exec/plan.md`](a1-remote-exec/plan.md).
- **To implement B:** [`b-push/spec.md`](b-push/spec.md), then [`b-push/plan.md`](b-push/plan.md).
- **To implement pairing:** [`pairing/spec.md`](pairing/spec.md).
- **To implement A2:** [`a2-browser/spec.md`](a2-browser/spec.md).
- **To implement A3:** [`a3-screen/spec.md`](a3-screen/spec.md).

How Hermes and OpenClaw handle the same layer is summarised in
[`b-push/spec.md` §14](b-push/spec.md#14-prior-art).
