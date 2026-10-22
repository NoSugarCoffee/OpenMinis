# Pico notifications: hostd sends straight to APNs

Status: design, 2026-10-22. Decision D24. Replaces §15's relay design for installs signed by the
user's own paid team; Bark (§7) stays for everyone else.

## 1. Why there is no relay

§15 put a relay between hosts and APNs because a published app is signed by one team, and that
team's APNs key can push to every app of the team, so it cannot be handed to users. A Pico built
with `scripts/ios-personal-device.sh` is signed by the user's own team. The user creates the APNs
key, keeps it on their own host, and hostd signs its requests to APNs itself. Nothing else runs.

What this gives over Bark: no second app, the notification shows as Pico, and a tap opens the event
with no "Open in Pico?" prompt. Notices are grouped per host.

## 2. Setup

1. **The key (once per team):** in the Apple Developer site, Certificates, Identifiers & Profiles →
   Keys → +, tick Apple Push Notifications service, download `AuthKey_<KEY_ID>.p8`. Copy it to the
   host as `~/.minis/hostd/AuthKey_<KEY_ID>.p8`, mode 0600.
2. **Config:** replace `[bark]` with
   ```toml
   [apns]
   key_file = "AuthKey_ABC123DEFG.p8"   # relative to ~/.minis/hostd, or absolute
   key_id = "ABC123DEFG"
   team_id = "28ZGY8C268"
   ```
   A config with both sections, or neither, is refused.
3. **The phone:** Settings → Remote Hosts → host → Notifications → **Send to This iPhone**. Pico asks
   for notification permission, gets its device token and registers it on the host (§4).
4. **Check:** `minis-hostd doctor --push-test` sends an encrypted test notice through APNs.

The build must keep the push entitlement: `ios-personal-device.sh --keep-push`, which a free team
cannot sign.

## 3. Sending

- **Endpoint:** `https://api.sandbox.push.apple.com` for a development registration,
  `https://api.push.apple.com` for production, `POST /3/device/<token>` over HTTP/2.
- **Auth:** an ES256 JWT `{alg: ES256, kid: key_id}.{iss: team_id, iat}` signed with the `.p8` key.
  APNs rejects a token refreshed more than once per 20 minutes and one older than an hour, so hostd
  reuses one for 40 minutes.
- **Headers:** `apns-topic: <bundle id>`, `apns-push-type: alert`, `apns-priority: 10`,
  `apns-expiration: now + 24 h`, so a phone that is off gets the notice when it comes back.
- **Payload:**
  ```json
  {"aps": {"alert": {"title": "New event", "body": "Open Pico to read it."},
           "mutable-content": 1, "thread-id": "<host>", "sound": "default"},
   "pico": {"v": 1, "host": "<host>", "c": "<base64 ciphertext>"}}
  ```
  The visible alert is a placeholder; the real title, body and link are inside `c` (§5).
- **Errors:** HTTP 200 is sent. `BadDeviceToken`, `Unregistered` and `DeviceTokenNotForTopic`
  mean the registration is stale: the error says to tap Send to This iPhone again.
  `InvalidProviderToken` and `ExpiredProviderToken` point at `key_id`, `team_id` or the key file.
  Other 4xx and 5xx are definite failures and retried as today (§5.4). A connection lost after the
  request was written is "may have been delivered", as with Bark.

## 4. Registration

`minis-hostd apns register <device token> --topic <bundle id> --environment development|production --json`

- hostd generates a fresh 32-byte AES key, writes `{token, topic, environment, key}` to
  `~/.minis/hostd/apns-device.json` (mode 0600, replaced atomically) and prints
  `{schemaVersion, key: "<base64>"}`. The key travels back over the SSH session, so it never
  appears in a command line on the host.
- One phone per host; registering again replaces it (and its key).
- The daemon reads the file for every send, so registering needs no restart. Before the first
  registration, sends fail with "No iPhone is registered for Pico notifications" and are retried
  within the usual window.
- **The environment** comes from the app's `embedded.mobileprovision` (`aps-environment`); an App
  Store build has none and is production.
- **Token changes:** on launch, Pico registers for remote notifications again; when the token
  differs from the one it registered on a host, it registers that host again in the background.

## 5. Encryption and display

- **Cipher:** AES-256-GCM, `c = base64(nonce ‖ ciphertext ‖ tag)` with a fresh 12-byte nonce,
  additional data `pico-push-v1:<host>`. The plaintext is `{"title", "body", "url"}`.
- **What Apple sees:** the device token, the host name (thread id), timing and the placeholder.
  Not the sender, subject or repository.
- **Notification Service Extension** (`PicoNotificationService`): reads the host's key from a
  keychain group shared with the app (`<team prefix>.com.openminis.app.push`), decrypts, and replaces
  title and body; it puts the link in `userInfo["url"]`. When decryption fails it shows "Pico could
  not decrypt this notice. Open Settings → Remote Hosts → <host> → Notifications and tap Send to
  This iPhone." and drops the link.
- **Tap:** the notification delegate passes `userInfo["url"]` to the same `host-event` opener as the
  `pico://` link (§9.1).

## 6. Where the code goes

| Part | Location |
|---|---|
| APNs notifier, JWT, payload | `host/minis-hostd/internal/notify/apns.go` |
| Registration file and `apns register` | `internal/notify/registration.go`, `internal/cli/apns.go` |
| Config `[apns]` | `internal/config` |
| Envelope, cipher, provisioning parser (tested with `swift test`) | `src/ios/Packages/PicoPush` |
| Extension target | `src/ios/PicoNotificationService/` |
| Registration UI and token handling | `Agent/Remote/PushRegistration.swift`, `HostNotificationsView` |
| Tap routing | one fork-marked line in `ShortcutNotificationDelegate` |

## 7. Out of scope

- Several phones per host.
- Notification actions (mark read, explain), the app badge and time-sensitive interruption.
- The relay of §15, needed only for a distributed build.
