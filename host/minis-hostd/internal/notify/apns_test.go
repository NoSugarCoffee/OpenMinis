package notify

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

var updateVector = flag.Bool("update", false, "rewrite testdata/contract/apns_payload.json")

const (
	testToken = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
	testTopic = "com.example.pico"
	testHost  = "mac-mini"
)

var apnsT0 = time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC)

type apnsRequest struct {
	Proto   string
	Path    string
	Headers http.Header
	Body    []byte
}

type apnsServer struct {
	server *httptest.Server
	mu     sync.Mutex
	seen   []apnsRequest
	status int
	reply  string
}

func startAPNs(t *testing.T) *apnsServer {
	t.Helper()
	fake := &apnsServer{status: http.StatusOK}
	fake.server = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Errorf("read body: %v", err)
		}
		fake.mu.Lock()
		fake.seen = append(fake.seen, apnsRequest{Proto: r.Proto, Path: r.URL.Path, Headers: r.Header.Clone(), Body: body})
		status, reply := fake.status, fake.reply
		fake.mu.Unlock()
		w.WriteHeader(status)
		io.WriteString(w, reply)
	}))
	fake.server.EnableHTTP2 = true
	fake.server.StartTLS()
	t.Cleanup(fake.server.Close)
	return fake
}

func (s *apnsServer) requests() []apnsRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]apnsRequest(nil), s.seen...)
}

func writeKeyFile(t *testing.T, mode os.FileMode) (string, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "AuthKey_ABC123DEFG.p8")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
	return path, key
}

type apnsFixture struct {
	apns   *APNs
	server *apnsServer
	key    *ecdsa.PrivateKey
	device Device
	now    *time.Time
}

func newAPNsFixture(t *testing.T) apnsFixture {
	t.Helper()
	server := startAPNs(t)
	_, key := writeKeyFile(t, 0o600)
	device, err := NewDevice(testToken, testTopic, Development, apnsT0)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), RegistrationFile)
	if err := SaveRegistrations(path, Registrations{Active: &device}); err != nil {
		t.Fatal(err)
	}
	now := apnsT0
	apns := &APNs{
		KeyID: "ABC123DEFG", TeamID: "TEAM123456", Key: key, HostName: testHost, RegistrationPath: path,
		Endpoints: map[Environment]string{Development: server.server.URL, Production: "https://production.invalid"},
		Client:    server.server.Client(),
		Now:       func() time.Time { return now },
	}
	return apnsFixture{apns: apns, server: server, key: key, device: device, now: &now}
}

func openSealed(t *testing.T, key []byte, host, sealed string) SealedNotice {
	t.Helper()
	combined, err := base64.StdEncoding.DecodeString(sealed)
	if err != nil {
		t.Fatal(err)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	nonce, ciphertext := combined[:gcm.NonceSize()], combined[gcm.NonceSize():]
	plaintext, err := gcm.Open(nil, nonce, ciphertext, AdditionalData(host))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	var notice SealedNotice
	if err := json.Unmarshal(plaintext, &notice); err != nil {
		t.Fatal(err)
	}
	return notice
}

func verifyProviderToken(t *testing.T, token string, key *ecdsa.PrivateKey) map[string]any {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("token %q has %d parts", token, len(parts))
	}
	decode := func(part string) []byte {
		raw, err := base64.RawURLEncoding.DecodeString(part)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	var header map[string]string
	if err := json.Unmarshal(decode(parts[0]), &header); err != nil {
		t.Fatal(err)
	}
	if header["alg"] != "ES256" || header["kid"] != "ABC123DEFG" {
		t.Errorf("header %v", header)
	}
	signature := decode(parts[2])
	if len(signature) != 64 {
		t.Fatalf("signature is %d bytes, want 64", len(signature))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:])
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Error("signature does not verify")
	}
	var claims map[string]any
	if err := json.Unmarshal(decode(parts[1]), &claims); err != nil {
		t.Fatal(err)
	}
	return claims
}

func TestAPNsSendsAnEncryptedAlert(t *testing.T) {
	f := newAPNsFixture(t)
	notice := Notice{Title: "owner/repo", Body: "Mentioned: Fix 1", URL: "pico://host-event/mac-mini/01JS0000000000000000000001"}
	if err := f.apns.Send(context.Background(), notice); err != nil {
		t.Fatal(err)
	}
	requests := f.server.requests()
	if len(requests) != 1 {
		t.Fatalf("%d requests", len(requests))
	}
	got := requests[0]
	if got.Proto != "HTTP/2.0" || got.Path != "/3/device/"+testToken {
		t.Errorf("proto %s path %s", got.Proto, got.Path)
	}
	for header, want := range map[string]string{
		"Apns-Topic": testTopic, "Apns-Push-Type": "alert", "Apns-Priority": "10",
		"Apns-Expiration": strconv.FormatInt(apnsT0.Add(24*time.Hour).Unix(), 10),
	} {
		if value := got.Headers.Get(header); value != want {
			t.Errorf("%s = %q, want %q", header, value, want)
		}
	}
	claims := verifyProviderToken(t, strings.TrimPrefix(got.Headers.Get("Authorization"), "bearer "), f.key)
	if claims["iss"] != "TEAM123456" || claims["iat"] != float64(apnsT0.Unix()) {
		t.Errorf("claims %v", claims)
	}

	var payload apnsPayload
	if err := json.Unmarshal(got.Body, &payload); err != nil {
		t.Fatal(err)
	}
	wantAPS := apnsAPS{Alert: apnsAlert{Title: placeholderTitle, Body: placeholderBody}, MutableContent: 1, ThreadID: testHost, Sound: "default"}
	if payload.APS != wantAPS {
		t.Errorf("aps %+v", payload.APS)
	}
	if payload.Pico.Version != 1 || payload.Pico.Host != testHost || payload.Pico.KeyID != f.device.KeyID {
		t.Errorf("envelope %+v", payload.Pico)
	}
	if opened := openSealed(t, f.device.Key, testHost, payload.Pico.Ciphertext); opened != SealedNotice(notice) {
		t.Errorf("opened %+v", opened)
	}
	if strings.Contains(string(got.Body), "Mentioned") {
		t.Error("the notice text reached Apple in the clear")
	}
}

func TestAPNsReusesTheProviderTokenFor40Minutes(t *testing.T) {
	f := newAPNsFixture(t)
	send := func() string {
		t.Helper()
		if err := f.apns.Send(context.Background(), Notice{Title: "t", Body: "b"}); err != nil {
			t.Fatal(err)
		}
		requests := f.server.requests()
		return requests[len(requests)-1].Headers.Get("Authorization")
	}
	first := send()
	*f.now = apnsT0.Add(39 * time.Minute)
	if send() != first {
		t.Error("token refreshed before 40 minutes")
	}
	*f.now = apnsT0.Add(40 * time.Minute)
	if send() == first {
		t.Error("token not refreshed after 40 minutes")
	}
}

func TestAPNsErrorsNameTheFix(t *testing.T) {
	cases := []struct {
		status    int
		reply     string
		want      string
		permanent bool
	}{
		// A new registration fixes these, and every send re-reads it, so they are retried.
		{http.StatusGone, `{"reason":"Unregistered"}`, "its token changed", false},
		{http.StatusBadRequest, `{"reason":"BadDeviceToken"}`, "not a development token", false},
		{http.StatusBadRequest, `{"reason":"DeviceTokenNotForTopic"}`, "com.example.pico is not the app", false},
		{http.StatusForbidden, `{"reason":"InvalidProviderToken"}`, "apns.key_id", true},
		{http.StatusRequestEntityTooLarge, `{"reason":"PayloadTooLarge"}`, "HTTP 413 PayloadTooLarge", true},
		{http.StatusTooManyRequests, `{"reason":"TooManyRequests"}`, "HTTP 429 TooManyRequests", false},
		{http.StatusInternalServerError, `oops`, "HTTP 500 oops", false},
	}
	for _, tc := range cases {
		t.Run(tc.want, func(t *testing.T) {
			f := newAPNsFixture(t)
			f.server.status, f.server.reply = tc.status, tc.reply
			err := f.apns.Send(context.Background(), Notice{Title: "t", Body: "b"})
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v, want %q", err, tc.want)
			}
			if errors.Is(err, ErrPermanent) != tc.permanent {
				t.Errorf("permanent = %v, want %v", errors.Is(err, ErrPermanent), tc.permanent)
			}
			if errors.Is(err, ErrMaybeDelivered) {
				t.Error("an APNs refusal is a definite failure")
			}
		})
	}
}

func TestAPNsSendsWithTheActiveDeviceNotThePendingOne(t *testing.T) {
	f := newAPNsFixture(t)
	pending, err := NewDevice(strings.Repeat("ab", 32), testTopic, Development, apnsT0)
	if err != nil {
		t.Fatal(err)
	}
	if err := SaveRegistrations(f.apns.RegistrationPath, Registrations{Active: &f.device, Pending: &pending}); err != nil {
		t.Fatal(err)
	}
	if err := f.apns.Send(context.Background(), Notice{Title: "t", Body: "b"}); err != nil {
		t.Fatal(err)
	}
	var payload apnsPayload
	got := f.server.requests()[0]
	if err := json.Unmarshal(got.Body, &payload); err != nil {
		t.Fatal(err)
	}
	if got.Path != "/3/device/"+testToken || payload.Pico.KeyID != f.device.KeyID {
		t.Errorf("sent to %s with key %s", got.Path, payload.Pico.KeyID)
	}
}

func TestAPNsSignsANewTokenAfterARefusedOne(t *testing.T) {
	f := newAPNsFixture(t)
	f.server.status, f.server.reply = http.StatusForbidden, `{"reason":"ExpiredProviderToken"}`
	_ = f.apns.Send(context.Background(), Notice{Title: "t", Body: "b"})
	f.server.status, f.server.reply = http.StatusOK, ""
	*f.now = apnsT0.Add(time.Minute)
	if err := f.apns.Send(context.Background(), Notice{Title: "t", Body: "b"}); err != nil {
		t.Fatal(err)
	}
	requests := f.server.requests()
	if requests[0].Headers.Get("Authorization") == requests[1].Headers.Get("Authorization") {
		t.Error("reused the provider token APNs refused")
	}
}

func TestAPNsConnectionLostAfterTheRequestMayHaveDelivered(t *testing.T) {
	f := newAPNsFixture(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		conn.Close()
	}))
	t.Cleanup(server.Close)
	f.apns.Endpoints[Development] = server.URL
	f.apns.Client = server.Client()
	err := f.apns.Send(context.Background(), Notice{Title: "t", Body: "b"})
	if !errors.Is(err, ErrMaybeDelivered) {
		t.Fatalf("err = %v, want ErrMaybeDelivered", err)
	}
}

func TestAPNsWithoutARegistrationSendsNothing(t *testing.T) {
	f := newAPNsFixture(t)
	f.apns.RegistrationPath = filepath.Join(t.TempDir(), RegistrationFile)
	err := f.apns.Send(context.Background(), Notice{Title: "t", Body: "b"})
	if !errors.Is(err, ErrNotRegistered) {
		t.Fatalf("err = %v", err)
	}
	if len(f.server.requests()) != 0 {
		t.Error("sent without a registration")
	}
}

func TestLoadAPNsKey(t *testing.T) {
	path, _ := writeKeyFile(t, 0o600)
	if _, err := LoadAPNsKey(path); err != nil {
		t.Fatal(err)
	}
	open, _ := writeKeyFile(t, 0o644)
	if _, err := LoadAPNsKey(open); err == nil || !strings.Contains(err.Error(), "chmod 600") {
		t.Errorf("readable key: %v", err)
	}
	notKey := filepath.Join(t.TempDir(), "AuthKey.p8")
	if err := os.WriteFile(notKey, []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadAPNsKey(notKey); err == nil || !strings.Contains(err.Error(), "PRIVATE KEY") {
		t.Errorf("not a key: %v", err)
	}
}

// apnsVector is decrypted by the app's PicoPush tests, so both sides read the same bytes.
type apnsVector struct {
	Key     string          `json:"key"`
	Payload json.RawMessage `json:"payload"`
	Notice  SealedNotice    `json:"notice"`
}

const vectorPath = "../../testdata/contract/apns_payload.json"

func TestAPNsPayloadVector(t *testing.T) {
	if *updateVector {
		key := make([]byte, PushKeyLength)
		_, _ = rand.Read(key)
		notice := Notice{Title: "owner/repo", Body: "Mentioned: “Fix” 1", URL: "pico://host-event/mac-mini/01JS0000000000000000000001"}
		device := Device{KeyID: "0123456789abcdef", Key: key}
		payload, err := (&APNs{HostName: testHost}).payload(device, notice)
		if err != nil {
			t.Fatal(err)
		}
		data, err := json.MarshalIndent(apnsVector{Key: base64.StdEncoding.EncodeToString(key), Payload: payload, Notice: SealedNotice(notice)}, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(vectorPath, append(data, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	data, err := os.ReadFile(vectorPath)
	if err != nil {
		t.Fatal(err)
	}
	var vector apnsVector
	if err := json.Unmarshal(data, &vector); err != nil {
		t.Fatal(err)
	}
	key, err := base64.StdEncoding.DecodeString(vector.Key)
	if err != nil {
		t.Fatal(err)
	}
	var payload apnsPayload
	if err := json.Unmarshal(vector.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	if opened := openSealed(t, key, payload.Pico.Host, payload.Pico.Ciphertext); opened != vector.Notice {
		t.Errorf("opened %+v, want %+v", opened, vector.Notice)
	}
}
