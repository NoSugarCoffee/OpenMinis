package pairing

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// Shared with the app's tests (MinisRemote PairingTests): changing either side breaks pairing.
const (
	vectorSecret    = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
	vectorPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKn78iqpSP+qI9YVAkEx9IFgvGfJNWffdtQLrSCdKh8p minis@iPhone"
	vectorMAC       = "c9b6420d8207f338f2ce7ecbd4aff2f43e3cc8656524f10881dcfa45fc836611"
)

func vectorSecretBytes(t *testing.T) []byte {
	t.Helper()
	secret, err := base64.RawURLEncoding.DecodeString(vectorSecret)
	if err != nil {
		t.Fatal(err)
	}
	return secret
}

func TestSecretAndMACMatchTheSharedVector(t *testing.T) {
	secret := make([]byte, SecretSize)
	for i := range secret {
		secret[i] = byte(i)
	}
	if got := EncodeSecret(secret); got != vectorSecret {
		t.Errorf("secret %q", got)
	}
	if got := MAC(secret, vectorPublicKey); got != vectorMAC {
		t.Errorf("mac %q", got)
	}
}

func TestPayloadTextIsPrefixedCompactJSON(t *testing.T) {
	text, err := Payload{
		V: 1, Name: "macmini", User: "light", Port: 22, Addresses: []string{"100.81.208.83"},
		PairPort: 50123, HostKey: "ssh-ed25519 AAAA", Secret: vectorSecret,
	}.Text()
	if err != nil {
		t.Fatal(err)
	}
	want := `minis-pair:{"v":1,"name":"macmini","user":"light","port":22,"addresses":["100.81.208.83"],` +
		`"pairPort":50123,"hostKey":"ssh-ed25519 AAAA","secret":"` + vectorSecret + `"}`
	if text != want {
		t.Errorf("got  %s\nwant %s", text, want)
	}
}

func TestCleanName(t *testing.T) {
	cases := map[string]string{
		"dailiangliangdeMac-mini.local": "dailiangliangdeMac-mini",
		"My Mac's mini":                 "My-Mac-s-mini",
		"--":                            "host",
		"":                              "host",
		strings.Repeat("a", 40):         strings.Repeat("a", 32),
		"诗序":                            "host",
		"box_1":                         "box_1",
	}
	for in, want := range cases {
		if got := CleanName(in); got != want {
			t.Errorf("CleanName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestOrderAddressesPutsTailscaleFirstAndDropsTheRest(t *testing.T) {
	ips := []net.IP{
		net.ParseIP("127.0.0.1"), net.ParseIP("192.168.1.5"), net.ParseIP("8.8.8.8"),
		net.ParseIP("fe80::1"), net.ParseIP("100.81.208.83"), net.ParseIP("169.254.3.4"),
		net.ParseIP("10.0.0.2"), net.ParseIP("192.168.1.5"), net.ParseIP("100.128.0.1"),
	}
	got := OrderAddresses(ips)
	want := []string{"100.81.208.83", "192.168.1.5", "10.0.0.2"}
	if !slices.Equal(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestHostKeyLineDropsTheComment(t *testing.T) {
	line, err := HostKeyLine(vectorPublicKey + "\n")
	if err != nil {
		t.Fatal(err)
	}
	if line != "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKn78iqpSP+qI9YVAkEx9IFgvGfJNWffdtQLrSCdKh8p" {
		t.Errorf("line %q", line)
	}
	if _, err := HostKeyLine("ecdsa-sha2-nistp256 AAAAE2VjZHNh root@mini"); !errors.Is(err, ErrNotEd25519HostKey) {
		t.Errorf("ecdsa: %v", err)
	}
}

func TestParseAuthorizedKeyRefusesAnythingButAPlainEd25519Key(t *testing.T) {
	blob := "AAAAC3NzaC1lZDI1NTE5AAAAIKn78iqpSP+qI9YVAkEx9IFgvGfJNWffdtQLrSCdKh8p"
	shortBlob := base64.StdEncoding.EncodeToString(append([]byte("\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x02"), 1, 2))
	rsaBlob := base64.StdEncoding.EncodeToString([]byte("\x00\x00\x00\x07ssh-rsa\x00\x00\x00\x20" + strings.Repeat("k", 32)))
	bad := []string{
		`command="sh" ssh-ed25519 ` + blob,
		"ssh-rsa " + blob,
		"ssh-ed25519 not-base64!",
		"ssh-ed25519 " + shortBlob,
		"ssh-ed25519 " + rsaBlob,
		"ssh-ed25519 " + blob + "AAAA",
		"ssh-ed25519 " + blob + " evil\nssh-ed25519 other",
		"ssh-ed25519 " + blob + " tab\there",
		"ssh-ed25519",
	}
	for _, line := range bad {
		if _, err := ParseAuthorizedKey(line); !errors.Is(err, ErrBadKey) {
			t.Errorf("%q: %v", line, err)
		}
	}
	key, err := ParseAuthorizedKey("ssh-ed25519 " + blob)
	if err != nil || key.Comment != "" || key.Line() != "ssh-ed25519 "+blob {
		t.Errorf("no comment: %+v %v", key, err)
	}
	key, err = ParseAuthorizedKey(vectorPublicKey)
	if err != nil || key.Line() != vectorPublicKey {
		t.Errorf("vector: %q %v", key.Line(), err)
	}
}

func TestAddAuthorizedKeyCreatesPrivateFilesAndSkipsDuplicates(t *testing.T) {
	home := t.TempDir()
	key, _ := ParseAuthorizedKey(vectorPublicKey)
	added, err := AddAuthorizedKey(home, key)
	if err != nil || !added {
		t.Fatalf("first add: %v %v", added, err)
	}
	dir := filepath.Join(home, ".ssh")
	if info, _ := os.Stat(dir); info.Mode().Perm() != 0o700 {
		t.Errorf(".ssh mode %v", info.Mode().Perm())
	}
	path := filepath.Join(dir, "authorized_keys")
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o600 {
		t.Errorf("authorized_keys mode %v", info.Mode().Perm())
	}
	renamed := key
	renamed.Comment = "minis@Other"
	if added, err := AddAuthorizedKey(home, renamed); err != nil || added {
		t.Errorf("same key with another comment: %v %v", added, err)
	}
	contents, _ := os.ReadFile(path)
	if string(contents) != vectorPublicKey+"\n" {
		t.Errorf("contents %q", contents)
	}
}

func TestAddAuthorizedKeyStartsANewLineAfterAnUnterminatedFile(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".ssh")
	os.MkdirAll(dir, 0o700)
	path := filepath.Join(dir, "authorized_keys")
	os.WriteFile(path, []byte("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKZLkiISgErH3yhnlmPsTraduwwNsQAXgtmW88hYus50 laptop"), 0o644)
	key, _ := ParseAuthorizedKey(vectorPublicKey)
	if _, err := AddAuthorizedKey(home, key); err != nil {
		t.Fatal(err)
	}
	contents, _ := os.ReadFile(path)
	if !strings.HasSuffix(string(contents), " laptop\n"+vectorPublicKey+"\n") {
		t.Errorf("contents %q", contents)
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o644 {
		t.Errorf("existing mode changed to %v", info.Mode().Perm())
	}
}

func TestCheck(t *testing.T) {
	secret := vectorSecretBytes(t)
	line := func(v int, publicKey, mac string) []byte {
		encoded, _ := json.Marshal(map[string]any{"v": v, "publicKey": publicKey, "mac": mac})
		return encoded
	}
	cases := []struct {
		name string
		line []byte
		want Reply
	}{
		{"valid", line(1, vectorPublicKey, vectorMAC), Reply{OK: true}},
		{"wrong mac", line(1, vectorPublicKey, strings.Repeat("0", 64)), Reply{Error: CodeBadMAC}},
		{"mac not hex", line(1, vectorPublicKey, "zz"), Reply{Error: CodeBadMAC}},
		{"swapped key", line(1, strings.Replace(vectorPublicKey, "iPhone", "attacker", 1), vectorMAC), Reply{Error: CodeBadMAC}},
		{"version", line(2, vectorPublicKey, vectorMAC), Reply{Error: CodeBadRequest}},
		{"not json", []byte("hello"), Reply{Error: CodeBadRequest}},
		{"bad key", line(1, "ssh-ed25519 AAAA x", MAC(secret, "ssh-ed25519 AAAA x")), Reply{Error: CodeBadKey}},
	}
	for _, c := range cases {
		key, reply := Check(c.line, secret)
		if reply != c.want || (reply.OK != (key != nil)) {
			t.Errorf("%s: reply %+v key %v", c.name, reply, key)
		}
	}
}

func exchange(t *testing.T, address, line string) Reply {
	t.Helper()
	conn, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.Write([]byte(line + "\n"))
	response, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		t.Fatalf("reading reply: %v", err)
	}
	var reply Reply
	if err := json.Unmarshal([]byte(response), &reply); err != nil {
		t.Fatalf("reply %q: %v", response, err)
	}
	return reply
}

func requestLine(publicKey, mac string) string {
	encoded, _ := json.Marshal(map[string]any{"v": 1, "publicKey": publicKey, "mac": mac})
	return string(encoded)
}

type serveResult struct {
	key AuthorizedKey
	err error
}

func startServe(t *testing.T, ctx context.Context, install func(AuthorizedKey) error) (string, <-chan serveResult) {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan serveResult, 1)
	go func() {
		key, err := Serve(ctx, listener, vectorSecretBytes(t), 2, install)
		done <- serveResult{key, err}
	}()
	return listener.Addr().String(), done
}

func TestServeAcceptsOneValidRequestThenCloses(t *testing.T) {
	var installed []string
	address, done := startServe(t, context.Background(), func(key AuthorizedKey) error {
		installed = append(installed, key.Line())
		return nil
	})
	if reply := exchange(t, address, "garbage"); reply.Error != CodeBadRequest {
		t.Errorf("garbage: %+v", reply)
	}
	if reply := exchange(t, address, requestLine(vectorPublicKey, vectorMAC)); !reply.OK {
		t.Errorf("valid: %+v", reply)
	}
	result := <-done
	if result.err != nil || result.key.Comment != "minis@iPhone" || len(installed) != 1 {
		t.Fatalf("result %+v installed %v", result, installed)
	}
	if conn, err := net.Dial("tcp", address); err == nil {
		conn.Close()
		t.Error("listener still accepts after pairing")
	}
}

func TestServeStopsAfterTooManyBadMACs(t *testing.T) {
	address, done := startServe(t, context.Background(), func(AuthorizedKey) error {
		t.Error("install called")
		return nil
	})
	for range 2 {
		if reply := exchange(t, address, requestLine(vectorPublicKey, strings.Repeat("ab", 32))); reply.Error != CodeBadMAC {
			t.Errorf("reply %+v", reply)
		}
	}
	if result := <-done; !errors.Is(result.err, ErrTooManyBadMACs) {
		t.Errorf("err %v", result.err)
	}
}

func TestServeTimesOut(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_, done := startServe(t, ctx, func(AuthorizedKey) error { return nil })
	if result := <-done; !errors.Is(result.err, ErrTimedOut) {
		t.Errorf("err %v", result.err)
	}
}

func TestServeReportsAFailedInstall(t *testing.T) {
	failure := errors.New("disk full")
	address, done := startServe(t, context.Background(), func(AuthorizedKey) error { return failure })
	if reply := exchange(t, address, requestLine(vectorPublicKey, vectorMAC)); reply.Error != CodeHostError {
		t.Errorf("reply %+v", reply)
	}
	if result := <-done; !errors.Is(result.err, failure) {
		t.Errorf("err %v", result.err)
	}
}

func TestRenderQRHasAQuietZoneAndOnlyBlocks(t *testing.T) {
	drawn, err := RenderQR("minis-pair:" + strings.Repeat("x", 300))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(drawn, "\n"), "\n")
	if !strings.HasPrefix(lines[0], strings.Repeat("█", 4)) || strings.Trim(lines[0], "█") != "" {
		t.Errorf("first row is not all quiet zone: %q", lines[0])
	}
	for _, line := range lines {
		if strings.Trim(line, "█▀▄ ") != "" {
			t.Fatalf("unexpected character in %q", line)
		}
	}
}
