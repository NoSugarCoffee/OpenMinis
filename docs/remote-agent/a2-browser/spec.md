# A2 — Browser on the host

Status: step 1 merged; accepted on the Mac mini and the iPhone (2026-10-21).

## 1. Goal

Let Pico's agent use a browser on the host that is already logged in to the user's sites, so it
can read and act on pages that need an account (GitHub, Gmail, dashboards) and keep working while
the app is suspended. The agent stays on the phone (D4); the browser and its cookies stay on the
host.

```
Pico on iPhone ─── shell_execute over SSH (A1) ──► ego-browser nodejs <<'EOF' … EOF
       ▲                                                   │
       └──── page text, or a screenshot via minis-remote cp ◄─ ego lite (host profile)
```

## 2. Why ego lite

| Option | Logins | Agent control | Cost to Pico |
|---|---|---|---|
| Everyday Chrome with remote debugging (old D9) | The user's real profile | Raw CDP; a new client in Pico | A CDP client, a tunnel, a consent flow |
| **ego lite + `ego-browser`** | Its own profile on the host; can import Chrome's once (`ego-browser import --browser chrome --profile Default`) | Isolated task spaces, handoff to the user, helpers for text snapshots, clicks and input | One prompt sentence |
| Pico's built-in `browser_use` | Pico's own WebKit store on the phone | Existing tool | None, but stops when the app is suspended and has no host logins |

ego lite gives the agent its own tabs instead of the user's windows, which is the main risk of
driving the everyday profile, and its CLI is already a scripting surface, so Pico needs no new tool.

## 3. Step 1: prompt only

Sessions bound to a host get one more sentence in the system prompt
(`RemoteToolOutput.hostBrowserSentence`): check `command -v ego-browser` on the host; if present,
read `ego-browser skill` once, then drive the browser with `ego-browser nodejs <<'EOF' … EOF`
through `shell_execute`; copy screenshots to the phone with `minis-remote cp` and open them with
`read_image`.

- The agent does the presence check, so hosts without ego lite need no setting and see no error.
- `ego-browser skill` prints the guide for the installed version, so the prompt does not pin
  helper names that ego lite may change.
- A1 runs commands in a login shell, so `ego-browser` installed in `~/.local/bin` or a Nix profile
  is found.

## 4. Host setup

1. Install ego lite on the host and finish its onboarding window (once, at the host's screen or
   over screen sharing).
2. Sign in to the sites the agent should use inside ego lite, or import them from Chrome.

## 5. Limitations

- Onboarding and logins need the host's screen; A3 will bring that into the app.
- macOS only today, since ego lite is a Mac app. A Linux host has no browser path yet.
- The agent acts with the user's logins with no per-action gate (D9).
- A page that needs the user (captcha, 2FA) is handed off in ego lite on the host; the user has to
  reach the host to finish it.

## 6. Acceptance

| # | Check | Result |
|---|---|---|
| 1 | On the Mac mini, `ego-browser` opens GitHub notifications logged in | **Pass** (2026-10-21): logged in as NoSugarCoffee |
| 2 | Over SSH as A1 runs it, the same script works from a login shell | **Pass**: covered by 3, which runs it through A1 |
| 3 | From Pico on the iPhone, a bound session reads a logged-in page and shows a screenshot | **Pass**: the account, the first three notifications and a screenshot of the page, in the chat |
