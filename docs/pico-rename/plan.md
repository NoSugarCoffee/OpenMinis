# Renaming the fork to Pico

Status: stage 1 in progress, 2026-10-22. Decision D23.

## Goal

The fork stops calling itself OpenMinis or Minis anywhere: the repository, identifiers, code names,
runtime names on the phone and the hosts, visible text and the icon. What stays:

- the credit to OpenMinis and every open-source project in the README's acknowledgements;
- `LICENSE` (GPLv3) and `THIRD_PARTY_LICENSES.md`, unchanged;
- a plain statement that Pico is a modified version of OpenMinis, with the date the changes
  started (GPLv3 §5a), and the app's licences and acknowledgements screens (§5d);
- links to upstream repositories the build uses (`OpenMinis/ish-arm64`, `OpenMinis/proot`, …),
  articles about OpenMinis, and recorded test data that names real repositories;
- "Ministral", which is a Mistral model name, not ours.

## Names

| Was | Becomes |
|---|---|
| Repository `NoSugarCoffee/OpenMinis` | `NoSugarCoffee/Pico` (done; GitHub redirects the old URLs) |
| Go module `github.com/NoSugarCoffee/OpenMinis/host/minis-hostd` | `github.com/NoSugarCoffee/Pico/host/pico-hostd` |
| Identifier prefix `com.openminis.app` (iOS bundle, app group, iCloud, Android package) | `com.nosugarcoffee.pico` |
| `OpenMinis`, `Minis` in code names (`MinisRemote`, `MinisApp`, `Minis.xcodeproj`, …) | `Pico…` |
| `minis-hostd`, `~/.minis/` on hosts | `pico-hostd`, `~/.pico/` |
| `/var/minis` in the app's sandbox, `minis-*` sandbox commands | `/var/pico`, `pico-*` |
| `.minisbak` backups | `.picobak` |
| `minis://` links | `pico://` |
| "Minis" in visible text | "Pico" |

## What must keep working

Renaming a runtime name breaks whatever already uses it, so each one ships with its migration:

| Name | Who already uses it | Migration |
|---|---|---|
| `~/.minis/hostd` (config, state.db), `~/.minis/bin/minis-hostd`, the launchd job `app.minis.hostd` on macOS and the systemd user unit on Linux | The Mac mini's running daemon, and any Linux host | `pico-hostd install-service` moves `~/.minis/hostd` to `~/.pico/hostd` when the new one is absent, then stops and removes the old service: `launchctl bootout` and its plist on macOS, `systemctl --user disable --now` and its unit file on Linux. Tested against both service managers' fakes, and on the Mac mini. The app runs hostd under its new name and offers the install command when it is missing. |
| `~/.minis/runs` (A1 run files) on each host | Running and finished remote runs | New runs go to `~/.pico/runs`; the app still reads a run it started under the old path until it ends. |
| `/var/minis` in the app's sandbox | Files, skills and memory inside the app | Moved once at launch, before the sandbox starts, when `/var/pico` is absent. |
| `.minisbak` | Existing backups | Still restored; new backups are `.picobak`. |
| `minis://` | Shortcuts, widgets and links that already exist | Still opened; Pico writes only `pico://`. |
| iOS bundle id, app group and iCloud container | Data and Keychain items on installed builds | The phone build always passes `--prefix com.nosugarcoffee.minis` to `scripts/ios-personal-device.sh`, which rewrites every identifier to that prefix, so the installed app keeps its id and data after the source moves to `com.nosugarcoffee.pico`. A new prefix would install a separate app with empty data; moving an existing install to it is out of scope. |
| Android `applicationId` | Installed Android builds | A new id is a new app; no Android install exists yet (D1), so nothing migrates. |

## Stages

One PR each, merged before the next starts.

1. **Repository and links.** GitHub rename, the Go module path, the install URLs in `install.sh` and the
   app, links to the fork in docs.
2. **Branding.** README, `BUILDING.md`, `CONTRIBUTING.md`, the PR template and docs say Pico, with the
   modified-version notice and the acknowledgements kept.
3. **iOS identifiers, code names, visible text and icon.** `com.openminis.app` → `com.nosugarcoffee.pico`,
   the Xcode project, targets, packages and types, "Minis" in strings, and the new icon. The build
   script learns the new source prefix, so `--prefix` keeps rewriting it.
4. **Android.** Package `com.openminis.app` → `com.nosugarcoffee.pico` (sources, manifests, Room schema
   directories), code names, strings and the icon. Built and unit-tested before merging.
5. **Runtime names, with the migrations above.** hostd becomes `pico-hostd` in `host/pico-hostd`
   (release 0.3.0, installed on the Mac mini), then the app's sandbox path, commands, backup format
   and link scheme.

## Checks

- Each stage: the grep below, limited to that stage's area, lists only the kept references. After
  stage 5 it runs on the whole repository: `git grep -i -P '(?<!open)minis|openminis'`.
- iOS: the app and MinisRemote/PicoRemote test suites pass; the phone build, made with
  `--prefix com.nosugarcoffee.minis`, installs over the current one and keeps its hosts, keys, chats and
  settings.
- hostd: tests pass; on the Mac mini the 0.3.0 install moves the state, the daemon runs under the new
  label, and pushes and event links still open in the app.
- Android: `./gradlew assembleDebug testDebugUnitTest` passes.
