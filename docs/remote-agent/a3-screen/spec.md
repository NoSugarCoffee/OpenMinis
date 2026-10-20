# A3 — Host screen in the app

Status: draft. Open questions in §10; spikes in §11 run before the plan.

## 1. Goal

Let the user see the host's screen from Minis and take control when the agent needs a person:
finishing ego lite onboarding, signing in, a captcha, 2FA, or a confirmation the agent should
not click itself. Today each of these sends the user to the host's own screen (A2 spec §5).

D10: an in-app viewer with take-over, tunnelled over SSH; the agent pauses its screen actions
while the user has control.

## 2. Principles

- **Nothing new opens on the network.** The viewer reaches the host's VNC server only through
  the A1 SSH connection, as a `direct-tcpip` channel to `127.0.0.1:<port>` on the host.
- **No new host daemon.** The host provides a VNC server: Screen Sharing on macOS, any RFB server
  on Linux (D2).
- **Viewing and controlling are separate.** The viewer opens view-only; control is one explicit
  tap and stays visible while it is on.
- **The agent never drives the viewer.** A3 is for the user. The agent's screen actions stay in
  A2 (`ego-browser`); A3 only lets the user step in.

## 3. Architecture

```
Minis on iPhone                                               Host
┌─────────────────────────────────────────┐                ┌──────────────────────┐
│ HostScreenView                          │                │                      │
│  WKWebView ── noVNC (bundled, MPL 2.0)  │                │ Screen Sharing / VNC │
│     │ ws://127.0.0.1:<random>/<token>   │                │   127.0.0.1:5900     │
│ ScreenBridge (NIO WebSocket server) ────┼── SSH (A1) ──► │   ▲ direct-tcpip     │
│     loopback only, one connection       │ direct-tcpip   │   └──────────────────┤
└─────────────────────────────────────────┘                └──────────────────────┘
```

### 3.1 Client: noVNC in a WKWebView

| Option | Verdict |
|---|---|
| **noVNC 1.7.0** (MPL 2.0) in a WKWebView | **Chosen.** Maintained, touch gestures, scaling, Tight/ZRLE, Apple Diffie-Hellman auth. Pure JS bundled in the app, so it loads offline. |
| RoyalVNCKit (MIT, Swift) | Archived on 2026-10-05; its iOS view was unfinished. |
| LibVNCClient (C) | Compatible with the repo's GPL-3, but needs our own renderer and touch handling. |

noVNC speaks RFB over a WebSocket, so the app runs `ScreenBridge`: a WebSocket server on
`127.0.0.1` at a random port that accepts one connection carrying a per-open random path token,
and pipes binary frames to and from a Citadel `createDirectTCPIPChannel` to the host's VNC port.
It stops when the viewer closes. `NIOWebSocket` and `NIOHTTP1` come with swift-nio, which
MinisRemote already depends on.

### 3.2 Host VNC server

| Host | Server | Port | Notes |
|---|---|---|---|
| macOS | Screen Sharing (System Settings → General → Sharing) | 5900 | Offers RFB 3.889 with security types 30, 33, 35, 36 and 2 on the Mac mini (macOS 27.0.1, checked 2026-10-20). It listens on all interfaces, not only loopback (§9). |
| Linux | `wayvnc` or `x11vnc -localhost` | 5900 by default | Needs a desktop session; headless hosts can use a virtual display. |

The port is a per-host setting (`RemoteHostConfig.screenPort`, default 5900) so a Linux host can
use another one.

### 3.3 Authentication (Q1)

Screen Sharing asks for either the Mac account's user name and password (type 30, Apple
Diffie-Hellman) or a separate VNC password (type 2), if the user has turned that on. noVNC
handles both. Minis asks the first time, offers to save it in the Keychain under the host
(like the SSH key), and never sends it anywhere but through the tunnel.

## 4. App

### 4.1 Where the viewer opens

1. **Settings → Remote Hosts → host → Screen.**
2. **The bound session's host row** (`SessionRemoteHostView`): a "Screen" button.
3. **A handoff from the agent** (§5): the agent's message carries a `minis://host-screen/<host>`
   link; tapping it opens the viewer in control mode.

### 4.2 Viewer

- Full screen, landscape allowed, pinch to zoom, noVNC's `scaleViewport` on by default.
- **View / Control** toggle. View sets noVNC's `viewOnly`. Control shows a coloured banner
  "You are controlling <host>" while it lasts.
- Keyboard button for the iOS keyboard; a small bar for Esc, Tab, Ctrl, Option, Command and
  arrow keys.
- Quality: noVNC's `qualityLevel` and `compressionLevel` default to values for cellular
  (spike S3) and can be raised on Wi-Fi.
- **Done** closes the viewer. If the agent handed off (§5), Done also tells the agent to continue.

### 4.3 Lifecycle

- The bridge and tunnel live only while the viewer is on screen. Backgrounding the app closes
  them; returning reconnects.
- One viewer per host at a time.

## 5. Take-over with the agent

The agent's screen actions are `ego-browser` scripts (A2). ego lite already has a lock: while the
user controls a task space, every agent action fails with "user is controlling", and the agent
must stop and ask (the ego-browser guide). A3 reuses it rather than adding a second lock.

1. The agent hits something only the user can do. It calls `handOffTaskSpace(id)`, then replies
   with what to do and the `minis://host-screen/<host>` link.
2. The user taps it, the viewer opens in Control on the host's screen, and the user finishes
   the step in the ego lite window.
3. The user taps **Done**. Minis sends a programmatic prompt into the session: "The user finished
   on the host's screen; continue." The agent starts its next script with
   `takeOverTaskSpace(id)`.

The user can also take control without being asked: clicking in an ego lite task-space window
hands it to the user, and the agent's next action fails with "user is controlling".

The A2 prompt sentence (`RemoteToolOutput.hostBrowserSentence`) gains the handoff rule: hand off
with `handOffTaskSpace`, include the link, wait for the user.

## 6. Integration points

| File | Change |
|---|---|
| `MinisRemote/ScreenBridge.swift` (new) | Loopback WebSocket ↔ `direct-tcpip` pipe |
| `MinisRemote/RemoteHostConfig.swift` | `screenPort` with default 5900; decoding older configs keeps working |
| `MinisRemote/RemoteToolCall.swift` | Handoff rule in `hostBrowserSentence` |
| `Views/Remote/HostScreenView.swift` (new) | WKWebView, toolbar, View/Control, Done |
| `Resources/noVNC/` (new) | noVNC 1.7.0 `core/` and a small `screen.html`, with its licence |
| `Views/Remote/SessionRemoteHostView.swift`, `RemoteHostsSettingsView.swift` | "Screen" entry points |
| `Shared/DeepLinkRouter.swift` (upstream, marked) | `case "host-screen"` |
| `AIChatViewModel+ProgrammaticPrompt.swift` (upstream, marked) | `.hostScreenDone` prompt |

## 7. Errors

| Case | Message |
|---|---|
| Nothing listens on the VNC port | "Screen Sharing is off on <host>. Turn it on in System Settings → General → Sharing." (Linux: "No VNC server on <host>:<port>.") |
| Authentication fails | "<host> refused the password." with retry; a saved password is cleared |
| SSH drops | The viewer shows "Reconnecting…" and retries with A1's pool |
| The host's screen is locked | Shown as is; the user unlocks with the Mac password in the viewer |

## 8. Testing

- `ScreenBridge` tests with a local TCP echo server standing in for the host: frames pass both
  ways byte for byte, a wrong token is refused, a second connection is refused, closing either
  side closes the other.
- `RemoteHostConfig` decodes configs without `screenPort`.
- Deep link parsing tests like `HostEventLinks`.
- Manual on the iPhone: §12.

## 9. Limitations

- macOS Screen Sharing also listens on the LAN; A3 does not need that, and turning it off is not
  possible without turning off Screen Sharing. A firewall rule is the user's choice.
- The type 30 login is the Mac account's password; saving it on the phone is optional (Q1).
- A Mac with no display attached may render at a low resolution; a dummy display adapter or
  Screen Sharing's virtual display fixes it (spike S2).
- iOS suspends the app in the background, so the viewer cannot stay open there.

## 10. Open questions

| # | Question | Proposal |
|---|---|---|
| Q1 | How does Minis log in to Screen Sharing? | Mac account (type 30), asked the first time, saved in the Keychain only if the user agrees. |
| Q2 | Does A3 also show the host's screen to the agent (desktop control beyond the browser)? | No. The agent's screen work stays in ego lite; desktop control is later, with the trust core. |
| Q3 | Should a handoff also push (Bark) when the app is closed? | Yes, through `minis-hostd` later; not in A3. |

## 11. Spikes before the plan

| # | Spike | Pass when |
|---|---|---|
| S1 | noVNC in a WKWebView on the iPhone through the bridge to the Mac mini | The Mac's screen shows and a tap clicks |
| S2 | Type 30 login on macOS 27 with noVNC 1.7.0; headless resolution on the Mac mini | Login works; the screen is readable |
| S3 | Frame rate and data use on cellular with Tight at a low quality | Usable at a few frames a second; data use recorded |

## 12. Acceptance

| # | Check |
|---|---|
| 1 | From Settings, the Mac mini's screen opens view-only within 5 s on Wi-Fi |
| 2 | Control lets the user click and type; the banner shows while it is on |
| 3 | An agent handoff in ego lite → link → finish the step → Done → the agent continues |
| 4 | Nothing on the host listens anywhere new; the only traffic is the SSH connection |
| 5 | A wrong password and Screen Sharing off show the messages in §7 |
