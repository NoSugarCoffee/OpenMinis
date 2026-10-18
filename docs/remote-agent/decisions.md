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
| D8 | **A1 comes first, then B (push), then A2 → A3.** Each ships with its own spec and plan. A1 already covers coding and long tasks, B needs only A1, and push is the other half of the goal. *Replaced: "all of A (A1 → A2 → A3) before B".* | 2026-10-18 |
| D9 | **A2 uses the user's everyday Chrome profile** on the host, through Chrome's user-consented remote debugging. The risk is accepted until the trust core adds per-action gating. | 2026-10-16 |
| D10 | **A3 is an in-app screen viewer with take-over**, tunnelled over SSH. The agent pauses its screen actions while the user has control. | 2026-10-16 |

The user's priorities for the remote computer: coding > long tasks > using the host's network and
environment > administering the host.

## A1 implementation

| # | Decision | Since |
|---|---|---|
| D11 | **SSH library: Citadel 0.9.2** (MIT), with its SSH chain pinned exactly in `MinisRemote/Package.swift` (`Joannis/swift-nio-ssh` 0.3.5, BigInt 5.7.0, ColorizeSwift 1.7.0), because it depends on a third-party NIO SSH fork and SwiftPM ignores a dependency's own `Package.resolved`. swift-nio is shared with upstream's packages and gets only a floor. Citadel caps the whole app at swift-crypto <2.1.0, so an upstream package needing a newer swift-crypto will not resolve until Citadel lifts the cap. | 2026-10-16 |
| D12 | **Cancel walks the process tree, not a process group.** `set -m` fails under busybox `sh` without a tty (verified). | 2026-10-16 |

## B (push)

Settled 2026-10-18 from the open questions Q1–Q6 that were here.

| # | Decision | Since |
|---|---|---|
| D13 | **Push channel: Bark**, end-to-end encrypted, behind a notifier interface so ntfy, Telegram or a webhook can be added. *Was Q1.* | 2026-10-18 |
| D14 | **Rules only decide what pushes in B**; no model call before a push. *Was Q2.* | 2026-10-18 |
| D15 | **`minis-hostd` is written in Go**: one static binary for macOS and Linux. *Was Q3.* | 2026-10-18 |
| D16 | **Event bodies are kept on the host for 30 days.** *Was Q4.* | 2026-10-18 |
| D17 | **The read-only event session is a normal session with a per-session tool allowlist**, not a new session type. *Was Q5.* | 2026-10-18 |
| D18 | **The first mailbox is Gmail over IMAP with an app password.** Gmail API and OAuth stay out of B. *Was Q6.* | 2026-10-18 |
