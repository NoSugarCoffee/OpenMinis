# Decisions

The single source of truth for decisions on the remote agent. Other docs link here instead of
restating them. A changed decision is edited in place, with the date and what it replaced.

## Product

| # | Decision | Since |
|---|---|---|
| D1 | **iOS only.** Android is deferred. | 2026-10-15 |
| D2 | **The host is any Unix machine reachable over SSH** (Mac mini, Linux VPS, NAS, cloud PC). Nothing core may depend on one vendor's ecosystem. *Replaced: "the iPad build on Mac is the host".* | 2026-10-16 |
| D3 | **Only SSH reachability is required.** Tailscale is recommended, not required. | 2026-10-16 |
| D4 | **The agent runs in Minis.** Model keys stay on the phone; the host executes and watches. | 2026-10-16 |
| D5 | **Event bodies stay on the host.** A push carries a one-line summary and an event id; Minis fetches the body over SSH. | 2026-10-16 |
| D6 | **Proactivity is a user dial** (Off / Low / Default / High). Pushes from email and GitHub are rule-based; only the High level of the later heartbeat may infer follow-ups from conversation. | 2026-10-15 |
| D7 | **Fork only, never upstreamed.** New code goes in new files; edits to upstream files are minimal and marked `// fork(remote-host):`. *Replaced: "upstream once stable".* | 2026-10-16 |

## Sequencing

| # | Decision | Since |
|---|---|---|
| D8 | **A1 comes first, then B (proactive push), then A2 → A3.** Each ships with its own spec and plan. A1 already covers coding and long tasks, B needs only A1, and proactive push is the other half of the goal. *Replaced: "all of A (A1 → A2 → A3) before B".* | 2026-10-18 |
| D9 | **A2 step 1 drives ego lite on the host through `ego-browser`**, called with A1's `shell_execute`; the agent learns about it from one system-prompt sentence (A2 spec §3). ego lite keeps its own profile on the host, which can import the user's Chrome logins once. The risk of an agent acting with the user's logins is accepted until the trust core adds per-action gating. *Replaced: "the user's everyday Chrome profile through Chrome's remote debugging".* | 2026-10-20 |
| D10 | **A3 is an in-app screen viewer with take-over**, tunnelled over SSH. The agent pauses its screen actions while the user has control. | 2026-10-16 |
| D19 | **The agent gets the host's screen in A3**: capture and input tools over the same in-app VNC connection as the viewer, so the app pauses them while the user has control. Web pages still go through `ego-browser` (A2). *Was A3 Q2.* | 2026-10-20 |
| D20 | **The viewer logs in to Screen Sharing with a password asked once and kept in the Keychain** under the host. Screen Sharing cannot trust the SSH key; a loopback VNC server started over SSH with a one-time password is the later zero-prompt path. *Was A3 Q1.* | 2026-10-20 |

The user's priorities for the remote computer: coding > long tasks > using the host's network and
environment > administering the host.

## A1 implementation

| # | Decision | Since |
|---|---|---|
| D11 | **SSH library: Citadel 0.9.2** (MIT), with its SSH chain pinned exactly in `MinisRemote/Package.swift` (`Joannis/swift-nio-ssh` 0.3.5, BigInt 5.7.0, ColorizeSwift 1.7.0), because it depends on a third-party NIO SSH fork and SwiftPM ignores a dependency's own `Package.resolved`. swift-nio is shared with upstream's packages and gets only a floor. Citadel caps the whole app at swift-crypto <2.1.0, so an upstream package needing a newer swift-crypto will not resolve until Citadel lifts the cap. | 2026-10-16 |
| D12 | **Cancel walks the process tree, not a process group.** `set -m` fails under busybox `sh` without a tty (verified). | 2026-10-16 |
| D21 | **Hosts are added by scanning a code from `minis-hostd pair`** ([pairing spec](pairing/spec.md)). The code carries the host key, so Minis pins it without a fingerprint prompt, and a one-time secret that authenticates the phone's public key on its way into `authorized_keys`. Manual entry stays for hosts without `minis-hostd`. | 2026-10-21 |
| D22 | **The fork installs as "Pico" and owns the `pico://` scheme** for its own links (host events today), because an upstream Minis on the same phone also claims `minis://` and iOS hands such links to either app. The fork keeps `minis://` for upstream's routes, which stay ambiguous while both apps are installed. | 2026-10-21 |

## B — Proactive push

Settled 2026-10-18 from the open questions Q1–Q6 that were here.

| # | Decision | Since |
|---|---|---|
| D13 | **Push channel: Bark for now**, end-to-end encrypted, behind a notifier interface. Minis's own notifications need a paid developer account, distribution under the fork's bundle ID and a relay holding the APNs key (spec §15), none of which exist yet; the app side depends only on the `minis://host-event` link, so switching later changes the notifier alone. *Was Q1.* | 2026-10-18 |
| D14 | **Rules only decide what pushes in B**; no model call before a push. *Was Q2.* | 2026-10-18 |
| D15 | **`minis-hostd` is written in Go**: one static binary for macOS and Linux. *Was Q3.* | 2026-10-18 |
| D16 | **Event bodies are kept on the host for 30 days.** *Was Q4.* | 2026-10-18 |
| D17 | **The read-only event session is a normal session with a per-session tool allowlist**, not a new session type. *Was Q5.* | 2026-10-18 |
| D18 | **The first mailbox is Gmail over IMAP with an app password.** Gmail API and OAuth stay out of B. *Was Q6.* | 2026-10-18 |
