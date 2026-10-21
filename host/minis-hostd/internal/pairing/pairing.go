// Package pairing implements the host side of adding a host to Minis by scanning a code
// (docs/remote-agent/pairing/spec.md). The code is the trusted channel: it carries the host key, so
// Minis pins it without a fingerprint prompt, and a secret that authenticates the phone's public key.
package pairing

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"unicode"
)

const (
	PayloadVersion = 1
	payloadPrefix  = "minis-pair:"
	macContext     = "minis-pair-v1\n"
	SecretSize     = 32
	keyType        = "ssh-ed25519"
	ed25519KeySize = 32
	maxNameLength  = 32
)

// Payload is what the code carries; its JSON field names are the contract with the app.
type Payload struct {
	V         int      `json:"v"`
	Name      string   `json:"name"`
	User      string   `json:"user"`
	Port      int      `json:"port"`
	Addresses []string `json:"addresses"`
	PairPort  int      `json:"pairPort"`
	HostKey   string   `json:"hostKey"`
	Secret    string   `json:"secret"`
}

func (p Payload) Text() (string, error) {
	encoded, err := json.Marshal(p)
	if err != nil {
		return "", fmt.Errorf("encoding the pairing code: %w", err)
	}
	return payloadPrefix + string(encoded), nil
}

func EncodeSecret(secret []byte) string { return base64.RawURLEncoding.EncodeToString(secret) }

// MAC is hex HMAC-SHA256 over the public key line, with a context prefix so the secret cannot be
// reused to authenticate anything else.
func MAC(secret []byte, publicKey string) string {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(macContext + publicKey))
	return hex.EncodeToString(mac.Sum(nil))
}

func validMAC(secret []byte, publicKey, presented string) bool {
	decoded, err := hex.DecodeString(presented)
	if err != nil {
		return false
	}
	expected, _ := hex.DecodeString(MAC(secret, publicKey))
	return hmac.Equal(decoded, expected)
}

// CleanName turns the host name into a Minis host name: the first label, with every character
// outside [A-Za-z0-9_-] replaced by "-", cut to 32 characters.
func CleanName(hostname string) string {
	label, _, _ := strings.Cut(hostname, ".")
	var cleaned strings.Builder
	for _, r := range label {
		if r < unicode.MaxASCII && (unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' || r == '-') {
			cleaned.WriteRune(r)
		} else {
			cleaned.WriteRune('-')
		}
	}
	name := strings.Trim(cleaned.String(), "-")
	if len(name) > maxNameLength {
		name = strings.TrimRight(name[:maxNameLength], "-")
	}
	if name == "" {
		return "host"
	}
	return name
}

var (
	tailscaleRange = mustCIDR("100.64.0.0/10")
	privateRanges  = []*net.IPNet{mustCIDR("10.0.0.0/8"), mustCIDR("172.16.0.0/12"), mustCIDR("192.168.0.0/16")}
)

func mustCIDR(cidr string) *net.IPNet {
	_, network, err := net.ParseCIDR(cidr)
	if err != nil {
		panic(err)
	}
	return network
}

// OrderAddresses keeps the IPv4 addresses a phone can reach: Tailscale first, because it works away
// from home, then private LAN ones. Public and link-local addresses are dropped.
func OrderAddresses(ips []net.IP) []string {
	var tailscale, lan []string
	seen := map[string]bool{}
	for _, ip := range ips {
		v4 := ip.To4()
		if v4 == nil || v4.IsLoopback() || seen[v4.String()] {
			continue
		}
		seen[v4.String()] = true
		switch {
		case tailscaleRange.Contains(v4):
			tailscale = append(tailscale, v4.String())
		case inAny(privateRanges, v4):
			lan = append(lan, v4.String())
		}
	}
	return append(tailscale, lan...)
}

func inAny(networks []*net.IPNet, ip net.IP) bool {
	for _, network := range networks {
		if network.Contains(ip) {
			return true
		}
	}
	return false
}

var ErrNotEd25519HostKey = errors.New("not an ssh-ed25519 public key")

// HostKeyLine returns "ssh-ed25519 <base64>" from the contents of ssh_host_ed25519_key.pub,
// dropping the comment.
func HostKeyLine(contents string) (string, error) {
	key, err := ParseAuthorizedKey(strings.TrimSpace(contents))
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrNotEd25519HostKey, err)
	}
	return keyType + " " + base64.StdEncoding.EncodeToString(key.Blob), nil
}

// AuthorizedKey is a validated Ed25519 public key; Line rebuilds it so nothing but the key and a
// plain comment can reach authorized_keys.
type AuthorizedKey struct {
	Blob    []byte
	Comment string
}

func (k AuthorizedKey) Line() string {
	line := keyType + " " + base64.StdEncoding.EncodeToString(k.Blob)
	if k.Comment == "" {
		return line
	}
	return line + " " + k.Comment
}

var ErrBadKey = errors.New("bad public key")

func ParseAuthorizedKey(line string) (AuthorizedKey, error) {
	fields := strings.SplitN(line, " ", 3)
	if len(fields) < 2 || fields[0] != keyType {
		return AuthorizedKey{}, fmt.Errorf("%w: expected %q followed by the key", ErrBadKey, keyType)
	}
	blob, err := base64.StdEncoding.DecodeString(fields[1])
	if err != nil {
		return AuthorizedKey{}, fmt.Errorf("%w: key is not base64: %v", ErrBadKey, err)
	}
	if err := checkEd25519Blob(blob); err != nil {
		return AuthorizedKey{}, err
	}
	comment := ""
	if len(fields) == 3 {
		comment = fields[2]
	}
	for _, r := range comment {
		if !unicode.IsPrint(r) {
			return AuthorizedKey{}, fmt.Errorf("%w: comment holds a control character", ErrBadKey)
		}
	}
	return AuthorizedKey{Blob: blob, Comment: comment}, nil
}

// checkEd25519Blob checks the SSH wire format: string "ssh-ed25519", then a 32-byte string.
func checkEd25519Blob(blob []byte) error {
	rest := blob
	name, rest, ok := readSSHString(rest)
	if !ok || string(name) != keyType {
		return fmt.Errorf("%w: key blob is not %s", ErrBadKey, keyType)
	}
	key, rest, ok := readSSHString(rest)
	if !ok || len(key) != ed25519KeySize || len(rest) != 0 {
		return fmt.Errorf("%w: key blob does not hold one 32-byte Ed25519 key", ErrBadKey)
	}
	return nil
}

func readSSHString(data []byte) (value, rest []byte, ok bool) {
	if len(data) < 4 {
		return nil, nil, false
	}
	length := binary.BigEndian.Uint32(data)
	if uint64(length) > uint64(len(data)-4) {
		return nil, nil, false
	}
	return data[4 : 4+length], data[4+length:], true
}

// sameKey compares only type and blob: a comment differing is still the same key.
func sameKey(line string, key AuthorizedKey) bool {
	fields := strings.Fields(line)
	if len(fields) < 2 || fields[0] != keyType {
		return false
	}
	blob, err := base64.StdEncoding.DecodeString(fields[1])
	return err == nil && bytes.Equal(blob, key.Blob)
}
