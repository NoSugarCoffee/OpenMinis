# Renaming the fork to Pico

Status: in progress, 2026-10-22. Decision D23.

## Goal

People who meet the fork see Pico: its GitHub repository, its README and docs, the app's name and
icon. Everything underneath keeps upstream's names, so upstream changes keep merging cleanly (D7).

## What changes

| Surface | Was | Becomes |
|---|---|---|
| GitHub repository | `NoSugarCoffee/OpenMinis` | `NoSugarCoffee/Pico` (done; GitHub redirects the old URLs) |
| Links to the fork (install URLs, docs) | `NoSugarCoffee/OpenMinis` | `NoSugarCoffee/Pico` |
| hostd's Go module path (fork-only code) | `github.com/NoSugarCoffee/OpenMinis/host/minis-hostd` | `github.com/NoSugarCoffee/Pico/host/minis-hostd` |
| README, `BUILDING.md`, `CONTRIBUTING.md`, PR template | OpenMinis branding and upstream's contribution rules | Pico, introduced as a modified version of OpenMinis |
| App name on the home screen | Pico (D22, done) | unchanged |
| App icon | Upstream's | Pico's own, once chosen |

## What stays

- Identifiers (`com.openminis.app`, the app group, the Android package), code names (`Minis…`,
  `Minis.xcodeproj`, `MinisRemote`), runtime names (`minis-hostd`, `~/.minis`, `/var/minis`,
  `.minisbak`, `minis://`) and upstream's in-app text.
- The credit to OpenMinis and every project in the acknowledgements, `LICENSE` (GPLv3) and
  `THIRD_PARTY_LICENSES.md`.
- Links to upstream's repositories, site, store listing, press and community, labelled as
  OpenMinis's.
- Recorded test data that names real repositories.

## Licence

GPLv3 lets a modified version carry its own name. The README says Pico is a modified version of
OpenMinis and since when (§5a), and the app keeps its licences and acknowledgements screens (§5d).

## Stages

1. **Repository and links**: the GitHub rename, the Go module path, the install URLs and the docs.
2. **README and contribution docs**: Pico branding, the modified-version notice, upstream's links
   moved under its own heading.
3. **Icon**: the chosen mark in the iOS asset catalogue. Upstream rarely changes its icon, and if it
   does, keeping ours is a one-file merge.

## Checks

- hostd tests pass under the new module path; the app's install command names the new repository.
- `git grep -i "NoSugarCoffee/OpenMinis"` lists only recorded test data.
- The README names OpenMinis as the origin and keeps the acknowledgements and licence sections whole.
