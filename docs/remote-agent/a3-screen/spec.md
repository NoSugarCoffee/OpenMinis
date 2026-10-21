# A3 — Host screen in the app

Status: implemented (#33, #35) except the handoff link and the Done prompt of §5; device checks 2, 4
and 6 pass (2026-10-21), 1 is partial (measured over 4G only), 3 and 5 are still to run.

## 1. Goal

Let the user see the host's screen from Pico and take control when the agent needs a person:
finishing ego lite onboarding, signing in, a captcha, 2FA, or a confirmation the agent should
not click itself. Today each of these sends the user to the host's own screen (A2 spec §5).

Let the agent see and operate the same screen for work outside the browser: native apps,
system dialogs, anything ego lite cannot reach (D19).

D10: an in-app viewer with take-over, tunnelled over SSH; the agent pauses its screen actions
while the user has control.

## 2. Principles

- **Nothing new opens on the network.** The viewer reaches the host's VNC server only through
  the A1 SSH connection, as a `direct-tcpip` channel to `127.0.0.1:<port>` on the host.
- **No new host daemon.** The host provides a VNC server: Screen Sharing on macOS, any RFB server
  on Linux (D2).
- **Viewing and controlling are separate.** The viewer opens view-only; control is one explicit
  tap and stays visible while it is on.
- **One screen connection, two users.** The agent's screen tools (§4.4) and the user's viewer
  share the app's VNC connection, so the app itself knows who has control and pauses the agent
  while the user does (D10). Web pages still go through `ego-browser` (A2); the screen tools are
  for the rest.

## 3. Architecture

```
Pico on iPhone                                                Host
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

The app uses port 5900 for now (`HostScreenSession.vncPort`); a per-host port for Linux hosts that
use another one is a later setting.

### 3.3 Authentication (Q1)

The user already proved who they are to the host with the SSH key, so ideally the viewer asks
for nothing. macOS Screen Sharing cannot see that: it always runs its own login, either the Mac
account's user name and password (type 30, Apple Diffie-Hellman) or a separate VNC password
(type 2) when "VNC viewers may control screen with password" is on. Both are offered on the Mac
mini. The ways to avoid typing one:

| Option | What the user does | Cost |
|---|---|---|
| **A. Screen Sharing, password once** | Types the Mac password (or VNC password) the first time; Pico saves it in the Keychain under the host and never asks again | None; works today |
| B. Screen Sharing, random VNC password set by Pico | Once, over SSH: `sudo kickstart -configure -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw <random>`, which asks for the sudo password one time | `kickstart` on macOS 27 unverified; the random password still lives in the Keychain |
| C. Own VNC server on loopback, started over SSH per open with a one-time password | Nothing after a one-time Screen Recording and Accessibility grant | A server to ship and maintain: macVNC (GPL-2.0) has had no commit since 2024-12 and builds from source; writing one means a Swift helper beside `minis-hostd`. On Linux `x11vnc -localhost` / `wayvnc` already work this way. |

Chosen: A (D20), since the prompt appears once per host. C is the zero-password path if the
one prompt is still unwanted, and it is the one Linux hosts get anyway.

## 4. App

### 4.1 Where the viewer opens

1. **Settings → Remote Hosts → host → Screen.**
2. **The bound session's host row** (`SessionRemoteHostView`): a "Screen" button.
3. **A handoff from the agent** (§5): the agent's message carries a `minis://host-screen/<host>`
   link; tapping it opens the viewer in control mode. *Not built yet.*

### 4.2 Viewer

- Full screen, landscape allowed, pinch to zoom, noVNC's `scaleViewport` on by default.
- **View / Control** toggle. View sets noVNC's `viewOnly`. Control shows a coloured banner
  "You are controlling <host>" while it lasts.
- In Control, a bar to type text on the host (sent through the same input path as the agent's
  `type` action) and keys for Return, Tab and Esc. Ctrl, Option, Command and arrows come later.
- Quality: noVNC's `qualityLevel` and `compressionLevel` default to values for cellular
  (spike S3) and can be raised on Wi-Fi.
- **Done** closes the viewer. If the agent handed off (§5), Done also tells the agent to continue.

### 4.3 Lifecycle

- One `HostScreenSession` per host: the bridge, the tunnel and a noVNC instance in a WKWebView.
  It opens when the viewer or an agent screen tool first needs it and closes after the viewer is
  gone and no screen tool has run for 2 minutes.
- When the viewer is not on screen, the WKWebView stays in the window hierarchy at 1×1 so its
  JavaScript keeps running (spike S4).
- Backgrounding the app closes it; the next use reconnects.

### 4.4 Agent screen tools (D19)

Two tools, offered only in sessions bound to a host whose screen is set up:

| Tool | Arguments | Result |
|---|---|---|
| `host_screen_capture` | none | A JPEG of the whole screen, scaled to at most 1568 px on the long side, saved under `/var/minis/offloads` on the phone; the result names the file, its size and scale, and the agent opens it with `read_image`, so the upstream image path is reused unchanged |
| `host_screen_input` | `actions`: a list of `click {x, y, button, count}`, `move {x, y}`, `drag {from, to}`, `scroll {x, y, dy}`, `type {text}`, `key {combo}` like `cmd+shift+4` | What ran; a fresh capture when `capture_after` is true |

- Coordinates are in the capture's pixels; the app maps them to the framebuffer.
- Capture is noVNC's canvas read with `toDataURL('image/jpeg')`. Input is sent through noVNC:
  keys with its `sendKey`, pointer actions as synthetic pointer events on its canvas (S4).
- While the user holds Control (§4.2), both tools return at once: "The user is controlling
  <host>'s screen. Wait until they tap Done." The agent's queued actions are dropped, not
  delayed.
- Every `host_screen_input` goes through the session's tool permission like `shell_execute`
  (A1); "Allow for this chat" covers it for the rest of the session.
- The read-only event sessions of B never get these tools (`SessionToolPolicy`).

## 5. Take-over with the agent

The agent acts on the host in two ways, and each has one lock:

- **Screen tools (§4.4):** the app's Control toggle. Control on pauses them.
- **`ego-browser` (A2):** ego lite's own lock. While the user controls a task space, every agent
  action fails with "user is controlling", and the agent must stop and ask. Taking Control in the
  viewer does not reach ego lite, so a handoff that involves ego lite also uses its handoff.

1. The agent hits something only the user can do. In ego lite it first calls
   `handOffTaskSpace(id)`; either way it replies with what to do and the
   `minis://host-screen/<host>` link.
2. The user taps it, the viewer opens in Control on the host's screen, and the user finishes
   the step in the ego lite window.
3. The user taps **Done**. Pico sends a programmatic prompt into the session: "The user finished
   on the host's screen; continue." Control turns off, and in ego lite the agent starts its next
   script with `takeOverTaskSpace(id)`.

The user can also take control without being asked: clicking in an ego lite task-space window
hands it to the user, and the agent's next action fails with "user is controlling".

The A2 prompt sentence (`RemoteToolOutput.hostBrowserSentence`) gains the handoff rule: hand off
with `handOffTaskSpace`, include the link, wait for the user.

## 6. Integration points

| File | Change |
|---|---|
| `MinisRemote/ScreenBridge.swift` (new) | Loopback WebSocket ↔ `direct-tcpip` pipe |
| `MinisRemote/ScreenToolLogic.swift` (new) | Tool schemas, action parsing, coordinate mapping, the "user is controlling" reply |
| `Agent/Remote/HostScreenSession.swift` (new) | One noVNC session per host; capture and input for the tools; Control state |
| `Agent/Remote/RemoteAgentToolSchema.swift`, `RemoteToolBridge.swift` | Offer and dispatch the two tools in bound sessions |
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
| The host's sshd has `AllowTcpForwarding no` (Alpine's default) | "Host `<host>` does not allow SSH tunnels. Set `AllowTcpForwarding yes` in /etc/ssh/sshd_config on the host and restart sshd." |
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
- `ScreenToolLogic` tests: every action shape parses or is refused with a clear error, capture
  coordinates map to framebuffer coordinates at several scales, Control on returns the pause
  reply without sending input.
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
| ~~Q1~~ | How does Pico log in to the VNC server without a password, since SSH already proves who the user is? | **Option A** (2026-10-20, D20): the password once, then the Keychain. |
| ~~Q2~~ | Does the agent get the host's screen too? | **Yes** (2026-10-20, D19): §4.4. |
| ~~Q3~~ | Should a handoff also push (Bark) when the app is closed? | **Yes, later** through `minis-hostd`; not part of A3 (2026-10-20). |

## 11. Spikes before the plan

| # | Spike | Pass when |
|---|---|---|
| S1 | noVNC in a WKWebView on the iPhone through the bridge to the Mac mini | The Mac's screen shows and a tap clicks |
| S2 | Type 30 login on macOS 27 with noVNC 1.7.0; headless resolution on the Mac mini | Login works; the screen is readable |
| S3 | Frame rate and data use on cellular with Tight at a low quality | Usable at a few frames a second; data use recorded |
| S4 | A 1×1 WKWebView keeps noVNC running; canvas capture and synthetic pointer events reach the Mac | Capture matches the screen; a synthetic click opens a Finder window |

## 12. Acceptance

Run on 2026-10-21: Pico on the iPhone 17 over 4G and Tailscale to the Mac mini (macOS 27), driven
with iCTRL. Model: Claude Haiku 5.5 through OpenRouter.

| # | Check | Result |
|---|---|---|
| 1 | From Settings, the Mac mini's screen opens view-only within 5 s on Wi-Fi | **Partial:** about 3 s over 4G; not measured on Wi-Fi |
| 2 | Control lets the user click and type; the banner shows while it is on | **Pass.** "You are controlling macmini" shows in the bar; a tap focused ego lite's settings search and the typing bar entered "pico check" there |
| 3 | An agent handoff in ego lite → link → finish the step → Done → the agent continues | Not run: the `host-screen` link and the Done prompt are not built |
| 4 | Nothing on the host listens anywhere new; the only traffic is the SSH connection | **Pass.** The phone's only connection is SSH on port 22; the viewer's 5900 connection is `sshd-session` to 127.0.0.1. Port 5900 on all interfaces is macOS Screen Sharing's own listener |
| 5 | A wrong password and Screen Sharing off show the messages in §7 | Not run: a wrong password replaces the saved one, and turning Screen Sharing off cuts other viewers, so the user runs it |
| 6 | The agent opens TextEdit with the screen tools and types a line; taking Control mid-task pauses it with the §4.4 reply | **Pass.** In a chat bound to macmini the agent clicked TextEdit in the Dock, pressed cmd+n and typed "Pico screen check 2026-10-21"; with Control on, its next capture returned the §4.4 reply and it stopped and said to tap Done. Done does not resume it yet (check 3) |

Also seen:

- The first capture of a new screen session came back solid black; the next one was right.
- Actions in one `host_screen_input` call run back to back: after `cmd+space` the typed "TextEdit"
  and Return were lost because Spotlight had not taken focus yet, and a capture right after typing
  showed only part of the line. A short settle between actions, and before `capture_after`, would fix
  both.
- In an unbound chat the agent has no screen tools, and asked to "use the screen tools" it ran
  `osascript` through `shell_execute` instead, which made macOS ask whether `sshd-keygen-wrapper` may
  control TextEdit (declined).
