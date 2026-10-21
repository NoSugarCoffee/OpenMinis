package notify

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/config"
)

const testKey = "k7m2pq9wxa4hnc3rts8vbe5fgjy6dz2u"

const testDeviceKey = "device123"

// referenceVector was produced once and decrypted by CryptoSwift 1.8.4, the version Bark uses.
type referenceVector struct {
	Key        string `json:"key"`
	IV         string `json:"iv"`
	Plaintext  string `json:"plaintext"`
	Ciphertext string `json:"ciphertext"`
}

type capturedRequest struct {
	Method      string
	Path        string
	ContentType string
	RawBody     string
	Form        url.Values
}

type recorder struct {
	mu       sync.Mutex
	requests []capturedRequest
}

func (r *recorder) add(request capturedRequest) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.requests = append(r.requests, request)
}

func (r *recorder) all() []capturedRequest {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]capturedRequest(nil), r.requests...)
}

func capture(t *testing.T, r *http.Request) capturedRequest {
	t.Helper()
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		t.Errorf("read request body: %v", err)
	}
	form, err := url.ParseQuery(string(raw))
	if err != nil {
		t.Errorf("parse request body %q: %v", raw, err)
	}
	return capturedRequest{
		Method:      r.Method,
		Path:        r.URL.Path,
		ContentType: r.Header.Get("Content-Type"),
		RawBody:     string(raw),
		Form:        form,
	}
}

func barkSuccess(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = io.WriteString(w, `{"code":200,"message":"success","timestamp":1760000000}`)
}

func newRecordingServer(t *testing.T) (*httptest.Server, *recorder) {
	t.Helper()
	rec := &recorder{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec.add(capture(t, r))
		barkSuccess(w)
	}))
	t.Cleanup(server.Close)
	return server, rec
}

func newTestBark(server string, newIV func() string) *Bark {
	return &Bark{
		Server:    server,
		DeviceKey: testDeviceKey,
		Key:       testKey,
		Client:    &http.Client{},
		NewIV:     newIV,
	}
}

func fixedIV(iv string) func() string {
	return func() string { return iv }
}

func decrypt(t *testing.T, key, iv, ciphertext string) []byte {
	t.Helper()
	sealed, err := base64.StdEncoding.DecodeString(ciphertext)
	if err != nil {
		t.Fatalf("ciphertext is not standard base64: %v", err)
	}
	block, err := aes.NewCipher([]byte(key))
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	plaintext, err := gcm.Open(nil, []byte(iv), sealed, nil)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	return plaintext
}

func loadReferenceVector(t *testing.T) referenceVector {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "testdata", "bark", "reference.json"))
	if err != nil {
		t.Fatal(err)
	}
	var vector referenceVector
	if err := json.Unmarshal(data, &vector); err != nil {
		t.Fatal(err)
	}
	return vector
}

func TestCiphertextMatchesBarkReferenceVector(t *testing.T) {
	vector := loadReferenceVector(t)
	var notice struct {
		Title string `json:"title"`
		Body  string `json:"body"`
		URL   string `json:"url"`
	}
	if err := json.Unmarshal([]byte(vector.Plaintext), &notice); err != nil {
		t.Fatal(err)
	}
	server, rec := newRecordingServer(t)
	bark := newTestBark(server.URL, fixedIV(vector.IV))
	bark.Key = vector.Key

	if err := bark.Send(context.Background(), Notice{Title: notice.Title, Body: notice.Body, URL: notice.URL}); err != nil {
		t.Fatal(err)
	}

	requests := rec.all()
	if len(requests) != 1 {
		t.Fatalf("got %d requests, want 1", len(requests))
	}
	if got := requests[0].Form.Get("ciphertext"); got != vector.Ciphertext {
		t.Errorf("ciphertext = %s\nwant       %s", got, vector.Ciphertext)
	}
	if got := requests[0].Form.Get("iv"); got != vector.IV {
		t.Errorf("iv = %q, want %q", got, vector.IV)
	}
}

func TestEachSendDrawsANewIV(t *testing.T) {
	server, rec := newRecordingServer(t)
	bark := newTestBark(server.URL, RandomIV)
	const sends = 1000

	for i := range sends {
		if err := bark.Send(context.Background(), Notice{Title: "t", Body: "b", URL: ""}); err != nil {
			t.Fatalf("send %d: %v", i, err)
		}
	}

	seen := map[string]bool{}
	for _, request := range rec.all() {
		iv := request.Form.Get("iv")
		if len(iv) != 12 {
			t.Errorf("iv %q has %d bytes, want 12", iv, len(iv))
		}
		if seen[iv] {
			t.Errorf("iv %q was used twice", iv)
		}
		seen[iv] = true
	}
	if len(seen) != sends {
		t.Errorf("got %d distinct IVs, want %d", len(seen), sends)
	}
}

func TestRequestCarriesOnlyCiphertextAndIV(t *testing.T) {
	server, rec := newRecordingServer(t)
	bark := newTestBark(server.URL, fixedIV("abcdefABCDEF"))
	notice := Notice{Title: "Alice Chen", Body: "合同 “第三版”", URL: "minis://host-event/mac/01J"}

	if err := bark.Send(context.Background(), notice); err != nil {
		t.Fatal(err)
	}

	request := rec.all()[0]
	if request.Method != http.MethodPost {
		t.Errorf("method = %s, want POST", request.Method)
	}
	if request.Path != "/"+testDeviceKey {
		t.Errorf("path = %s, want /%s", request.Path, testDeviceKey)
	}
	if request.ContentType != "application/x-www-form-urlencoded" {
		t.Errorf("content type = %q", request.ContentType)
	}
	if len(request.Form) != 2 || request.Form.Get("ciphertext") == "" || request.Form.Get("iv") == "" {
		t.Errorf("form = %v, want exactly ciphertext and iv", request.Form)
	}
	for _, plain := range []string{"Alice", "合同", url.QueryEscape("合同"), "minis", "host-event"} {
		if strings.Contains(request.RawBody, plain) {
			t.Errorf("request body contains plaintext %q: %s", plain, request.RawBody)
		}
	}
}

func TestCapturedCiphertextDecryptsToNoticeJSON(t *testing.T) {
	server, rec := newRecordingServer(t)
	bark := newTestBark(server.URL, RandomIV)

	if err := bark.Send(context.Background(), Notice{Title: "owner/repo", Body: "mention: Fix it", URL: "minis://host-event/mac/01J"}); err != nil {
		t.Fatal(err)
	}
	if err := bark.Send(context.Background(), Notice{Title: "Bob", Body: "Hello", URL: ""}); err != nil {
		t.Fatal(err)
	}

	requests := rec.all()
	want := []string{
		`{"title":"owner/repo","body":"mention: Fix it","url":"minis://host-event/mac/01J","group":"minis"}`,
		`{"title":"Bob","body":"Hello","group":"minis"}`,
	}
	for i, request := range requests {
		got := decrypt(t, testKey, request.Form.Get("iv"), request.Form.Get("ciphertext"))
		if string(got) != want[i] {
			t.Errorf("plaintext %d = %s\nwant          %s", i, got, want[i])
		}
	}
}

func TestServerErrorIsRetryable(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = io.WriteString(w, `{"code":500,"message":"push failed: apns down"}`)
	}))
	defer server.Close()

	err := newTestBark(server.URL, RandomIV).Send(context.Background(), Notice{Title: "t", Body: "b", URL: ""})

	if err == nil {
		t.Fatal("want an error")
	}
	if errors.Is(err, ErrMaybeDelivered) {
		t.Errorf("a 500 must be retryable, got %v", err)
	}
	if !strings.Contains(err.Error(), "500") || !strings.Contains(err.Error(), "apns down") {
		t.Errorf("error %q should name the status and Bark's message", err)
	}
}

func TestNonSuccessCodeIsRetryable(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"code":400,"message":"failed to get device token"}`)
	}))
	defer server.Close()

	err := newTestBark(server.URL, RandomIV).Send(context.Background(), Notice{Title: "t", Body: "b", URL: ""})

	if err == nil {
		t.Fatal("want an error")
	}
	if errors.Is(err, ErrMaybeDelivered) {
		t.Errorf("a non-200 code must be retryable, got %v", err)
	}
	if !strings.Contains(err.Error(), "400") || !strings.Contains(err.Error(), "failed to get device token") {
		t.Errorf("error %q should name the code and Bark's message", err)
	}
}

func TestUnreadableSuccessResponseMayHaveBeenDelivered(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `<html>ok</html>`)
	}))
	defer server.Close()

	err := newTestBark(server.URL, RandomIV).Send(context.Background(), Notice{Title: "t", Body: "b", URL: ""})

	if !errors.Is(err, ErrMaybeDelivered) {
		t.Errorf("want ErrMaybeDelivered, got %v", err)
	}
}

func TestConnectionClosedAfterBodyMayHaveBeenDelivered(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Errorf("hijack: %v", err)
			return
		}
		_ = conn.Close()
	}))
	defer server.Close()

	err := newTestBark(server.URL, RandomIV).Send(context.Background(), Notice{Title: "t", Body: "b", URL: ""})

	if !errors.Is(err, ErrMaybeDelivered) {
		t.Errorf("want ErrMaybeDelivered, got %v", err)
	}
}

func TestDialFailureIsRetryable(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}

	err = newTestBark("http://"+address, RandomIV).Send(context.Background(), Notice{Title: "t", Body: "b", URL: ""})

	if err == nil {
		t.Fatal("want an error")
	}
	if errors.Is(err, ErrMaybeDelivered) {
		t.Errorf("nothing was sent, so the error must be retryable, got %v", err)
	}
}

func TestTimeoutAfterWriteMayHaveBeenDelivered(t *testing.T) {
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	defer server.Close()
	defer close(release)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	err := newTestBark(server.URL, RandomIV).Send(ctx, Notice{Title: "t", Body: "b", URL: ""})

	if !errors.Is(err, ErrMaybeDelivered) {
		t.Errorf("want ErrMaybeDelivered, got %v", err)
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("want the deadline kept in the chain, got %v", err)
	}
}

func TestNewBarkUsesConfigAndRandomIVs(t *testing.T) {
	client := &http.Client{}
	bark := NewBark(config.Bark{Server: "https://bark.example", DeviceKey: testDeviceKey, EncryptionKey: testKey}, client)

	if bark.Server != "https://bark.example" || bark.DeviceKey != testDeviceKey || bark.Key != testKey || bark.Client != client {
		t.Errorf("NewBark did not copy the config: %+v", bark)
	}
	if first, second := bark.NewIV(), bark.NewIV(); len(first) != 12 || first == second {
		t.Errorf("NewIV gave %q then %q, want two different 12-character IVs", first, second)
	}
}

func TestRandomIVIsTwelveAlphanumericCharacters(t *testing.T) {
	for range 1000 {
		iv := RandomIV()
		if len(iv) != 12 {
			t.Fatalf("iv %q has length %d", iv, len(iv))
		}
		for _, r := range iv {
			if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9') {
				t.Fatalf("iv %q has non-alphanumeric %q", iv, r)
			}
		}
	}
}

func TestBadIVFailsBeforeSending(t *testing.T) {
	server, rec := newRecordingServer(t)

	err := newTestBark(server.URL, fixedIV("short")).Send(context.Background(), Notice{Title: "t", Body: "b", URL: ""})

	if err == nil || errors.Is(err, ErrMaybeDelivered) {
		t.Errorf("want a plain error, got %v", err)
	}
	if got := len(rec.all()); got != 0 {
		t.Errorf("server got %d requests, want 0", got)
	}
}

func TestGenerateKeyUsesOnlyTheAlphabet(t *testing.T) {
	seen := map[string]bool{}
	for range 1000 {
		key := GenerateKey()
		if len(key) != config.BarkKeyLength {
			t.Fatalf("key %q has length %d, want %d", key, len(key), config.BarkKeyLength)
		}
		for _, r := range key {
			if !strings.ContainsRune(config.BarkKeyAlphabet, r) {
				t.Fatalf("key %q has %q outside %q", key, r, config.BarkKeyAlphabet)
			}
		}
		seen[key] = true
	}
	if len(seen) != 1000 {
		t.Errorf("got %d distinct keys out of 1000", len(seen))
	}
}
