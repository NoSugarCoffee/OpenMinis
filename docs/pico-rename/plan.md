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
| `~/.minis/hostd` (config, state.db), `~/.minis/bin/minis-hostd`, launchd `app.minis.hostd` | The Mac mini's running daemon | `pico-hostd install-service` moves `~/.minis/hostd` to `~/.pico/hostd` when the new one is absent, boots out the old launchd job and removes its plist. The app runs hostd under its new name and offers the install command when it is missing. |
| `~/.minis/runs` (A1 run files) on each host | Running and finished remote runs | New runs go to `~/.pico/runs`; the app still reads a run it started under the old path until it ends. |
| `/var/minis` in the app's sandbox | Files, skills and memory inside the app | Moved once at launch, before the sandbox starts, when `/var/pico` is absent. |
| `.minisbak` | Existing backups | Still restored; new backups are `.picobak`. |
| `minis://` | Shortcuts, widgets and links that already exist | Still opened; Pico writes only `pico://`. |
| iOS app group and iCloud container | Data on installed builds | On the phone the build script sets the identifiers from `--prefix` (`com.nosugarcoffee.minis` today), so a source rename does not move them. The default prefix becomes `com.nosugarcoffee.pico` for new installs only. |
| Android `applicationId` | Installed Android builds | A new id is a new app; no Android install exists yet (D1), so nothing migrates. |

## Stages

One PR each, merged before the next starts.

1. **Repository and links.** GitHub rename, the Go module path, the install URLs in `install.sh` and the
   app, links to the fork in docs.
2. **Branding.** README, `BUILDING.md`, `CONTRIBUTING.md`, the PR template and docs say Pico, with the
   modified-version notice and the acknowledgements kept.
3. **iOS identifiers, code names, visible text and icon.** `com.openminis.app` → `com.nosugarcoffee.pico`,
   the Xcode project, targets, packages and types, "Minis" in strings, and the new icon. The build
   script's `--prefix` default follows.
4. **Android.** Package `com.openminis.app` → `com.nosugarcoffee.pico` (sources, manifests, Room schema
   directories), code names, strings and the icon. Built and unit-tested before merging.
5. **Runtime names, with the migrations above.** hostd becomes `pico-hostd` in `host/pico-hostd`
   (release 0.3.0, installed on the Mac mini), then the app's sandbox path, commands, backup format
   and link scheme.

## Checks

- Every stage: `git grep -i -P '(?<!open)minis|openminis'` lists only the kept references above.
- iOS: the app and MinisRemote/PicoRemote test suites pass; the phone build installs over the current
  one and keeps its hosts, keys, chats and settings.
- hostd: tests pass; on the Mac mini the 0.3.0 install moves the state, the daemon runs under the new
  label, and pushes and event links still open in the app.
- Android: `./gradlew assembleDebug testDebugUnitTest` passes.
