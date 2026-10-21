# Remote host pairing — add a computer by scanning a code

Status: spec, 2026-10-21. Decision D21.

## 1. Goal

Adding a host today means handling two keys by hand: copy the phone's public key into the host's
`~/.ssh/authorized_keys`, then compare and trust the host's key fingerprint (A1 spec §7). The user
found this too hard to follow. Pairing replaces both steps with one command and one scan:

1. On the computer: `minis-hostd pair`. It prints a QR code.
2. In Minis: Settings → Remote Hosts → Add Host → scan the code → Add.

The manual form stays as "Enter Details Manually" for hosts without `minis-hostd`.

## 2. What the code carries and why it is enough

The code is shown on the user's own screen and scanned by the user's own phone, so it is the
trusted channel. It carries:

| Field | Use |
|---|---|
| `name` | Suggested host name in Minis: `host_name` from `~/.minis/hostd/config.toml` when that file exists, since push links carry it and Minis opens them only for a host of that name; otherwise the short host name, cleaned to `[A-Za-z0-9_-]{1,32}`. Editable before Add |
| `user` | The SSH login (the user who ran `pair`) |
| `port` | The SSH port (22 unless `--ssh-port`) |
| `addresses` | IPv4 addresses to reach the host: Tailscale (100.64.0.0/10) first, then private LAN ones |
| `pairPort` | The one-shot pairing listener's TCP port |
| `hostKey` | The host's `ssh-ed25519` public key from `/etc/ssh/ssh_host_ed25519_key.pub` |
| `secret` | 32 random bytes, base64url, used only to authenticate the pairing request |

- **The host key comes from the code**, so Minis pins it without showing a fingerprint. The first
  SSH connection then proves the host holds the matching private key, so nobody on the network
  can stand in for it.
- **The phone's public key goes to the host over the pairing listener**, authenticated with an
  HMAC under `secret`. Someone on the same network who sees the request cannot swap in their own
  key, because they do not have the secret, and cannot replay it, because the listener takes one
  request and exits.
- The private key is generated on the phone and never leaves it, as in A1.

Payload text: `minis-pair:` followed by compact JSON with `"v": 1` and the fields above. A version
Minis does not know is refused with "Update Minis to pair with this host."

## 3. Host: `minis-hostd pair`

```
minis-hostd pair [--name <name>] [--ssh-port <port>]
```

A person runs it in a terminal, so it prints plain text, like the other setup commands.

1. Fails fast, with the fix, when:
   - nothing listens on `127.0.0.1:<ssh-port>`: "Remote Login is off. Turn it on in System
     Settings → General → Sharing → Remote Login" on macOS, "Start sshd" on Linux;
   - `/etc/ssh/ssh_host_ed25519_key.pub` is missing or not an Ed25519 key;
   - no non-loopback IPv4 address is up;
   - `config.toml` exists and `--name` differs from its `host_name`, or that `host_name` is invalid.
2. Listens on a random TCP port on all interfaces, prints the code (Unicode half blocks, so it fits
   a terminal) and the host name, user and addresses in plain text under it.
3. Waits up to 5 minutes for one request. Each connection may send one line of at most 4 KiB:

   ```json
   {"v":1,"publicKey":"ssh-ed25519 AAAA… minis@iPhone","mac":"<hex HMAC-SHA256>"}
   ```

   `mac` is `HMAC-SHA256(secret, "minis-pair-v1\n" + publicKey)`. The reply is one line,
   `{"ok":true}` or `{"ok":false,"error":"<code>"}` with code `bad_mac`, `bad_key` or
   `bad_request`.
4. On a valid request it rebuilds the line from the parsed key (type, base64 of a well-formed
   Ed25519 key blob, comment without control characters), so no `authorized_keys` options can
   ride along. It creates `~/.ssh` (0700) and `~/.ssh/authorized_keys` (0600) when missing, adds
   the line unless the same key is already there, replies, prints "Paired <comment>." and exits 0.
5. Five bad MACs or the timeout end it with exit 2 and a message. Nothing is written in either
   case.

`install.sh --pair` installs only the binary and then runs `minis-hostd pair`, so a new host needs
one line:

```sh
curl -fsSL https://raw.githubusercontent.com/NoSugarCoffee/OpenMinis/main/host/minis-hostd/scripts/install.sh \
  | sh -s -- --pair --version <version>
```

## 4. App

**MinisRemote**

- `PairingPayload`: parses and validates the code (prefix, version, fields, the host key line).
- `PairingRequest`: builds the request line and its MAC; decodes the reply.
- `PairingClient`: tries each address in order (3 s connect timeout each) over a plain TCP
  connection and returns the address that answered. Plain TCP keeps App Transport Security out of
  the way; the content is authenticated, and over Tailscale it is also encrypted.

**Setup** (`RemoteHostSetup.pair`)

1. Generate an Ed25519 key in the Keychain under a new key reference (as A1's Generate).
2. Send its public key; on any failure delete the key and show why.
3. Add the host with the answering address, the user, the port and `pinnedHostKey` set from the
   code, then run A1's checks, which also record the OS.

**Screens**

- Add Host opens the pairing sheet: the command to run (with Copy), the camera scanner
  (VisionKit `DataScannerViewController`, QR only), and "Enter Details Manually" below.
- After a scan: the name (editable, refused if it duplicates a host), `user@address`, and Add.
  When the host already runs `minis-hostd`, the suggested name is its `host_name`; changing it here
  means its push links name a host Minis does not have, until `host_name` is changed to match and
  the daemon restarted (`minis-hostd install-service`), since it reads the name only at start.
  Pairing shows progress, then the checks, then closes.
- Devices without a usable camera see the command and the manual entry only.

## 5. Errors

| Case | Shown |
|---|---|
| Code is not a Minis pairing code | "This is not a Minis pairing code. Run minis-hostd pair on the computer and scan the code it prints." |
| Newer payload version | "Update Minis to pair with this host." |
| No address answered | "Could not reach <name> at <addresses>. Check that the phone and the computer are on the same Tailscale network or Wi-Fi, and that minis-hostd pair is still running." |
| `bad_mac` | "The computer refused the pairing. Run minis-hostd pair again and scan the new code." |
| Listener closed (used or timed out) | Same as unreachable |
| Checks fail after pairing | The host is kept; the detail screen shows the failing check, as today |

## 6. Testing

- Go: payload encoding, the MAC check, key-line validation (options, newlines, wrong type, bad
  blob), `authorized_keys` creation, modes and de-duplication, one-shot and the failure limit,
  against a temp home.
- Swift: payload parsing and refusal cases, MAC vectors shared with the Go tests, and the client
  against a local listener, including the first address failing.
- End to end: `minis-hostd pair` on the Mac mini, scan with the iPhone, run a command.

## 7. Out of scope

- Opening Minis from the system Camera (a `minis://` link would put the secret in the app's URL
  logs; the in-app scanner avoids that).
- Hosts reachable only through a jump host or by DNS name: use manual entry.
- Re-pairing an existing host in place: remove it, then pair again.
