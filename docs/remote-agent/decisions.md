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
| D8 | **Sub-project A (the remote computer) comes before B (push).** A ships as A1 → A2 → A3, each with its own spec and plan. | 2026-10-16 |
| D9 | **A2 uses the user's everyday Chrome profile** on the host, through Chrome's user-consented remote debugging. The risk is accepted until the trust core adds per-action gating. | 2026-10-16 |
| D10 | **A3 is an in-app screen viewer with take-over**, tunnelled over SSH. The agent pauses its screen actions while the user has control. | 2026-10-16 |

The user's priorities for the remote computer: coding > long tasks > using the host's network and
environment > administering the host.

## A1 implementation

| # | Decision | Since |
|---|---|---|
| D11 | **SSH library: Citadel 0.9.2** (MIT), with its SSH chain pinned exactly in `MinisRemote/Package.swift` (`Joannis/swift-nio-ssh` 0.3.5, BigInt 5.7.0, ColorizeSwift 1.7.0), because it depends on a third-party NIO SSH fork and SwiftPM ignores a dependency's own `Package.resolved`. swift-nio is shared with upstream's packages and gets only a floor. Citadel caps the whole app at swift-crypto <2.1.0, so an upstream package needing a newer swift-crypto will not resolve until Citadel lifts the cap. | 2026-10-16 |
| D12 | **Cancel walks the process tree, not a process group.** `set -m` fails under busybox `sh` without a tty (verified). | 2026-10-16 |

## Open (settle when B is designed)

| # | Question | Leaning |
|---|---|---|
| Q1 | Default push channel | Bark |
| Q2 | Model-written summaries before a push | Rules only in B |
| Q3 | Language for `minis-hostd` | Go |
| Q4 | Retention of event bodies on the host | 30 days |
| Q5 | Read-only event session: new session type, or a normal session with a tool policy | A normal session with a tool policy |
| Q6 | First mailbox to connect | The user's call |
