package notify

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"strings"
	"sync/atomic"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/config"
)

const ivLength = 12

const ivAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

const barkGroup = "minis"

// maxResponseBytes bounds how much of Bark's reply is read; its replies are a few dozen bytes.
const maxResponseBytes = 64 << 10

// Bark sends notices through a Bark server with Bark's push encryption, so the server and APNs see
// only the device key and timing.
type Bark struct {
	Server    string
	DeviceKey string
	Key       string
	Client    *http.Client
	NewIV     func() string
}

type barkPayload struct {
	Title string `json:"title"`
	Body  string `json:"body"`
	URL   string `json:"url,omitempty"`
	Group string `json:"group"`
}

type barkResponse struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func NewBark(cfg config.Bark, client *http.Client) *Bark {
	return &Bark{
		Server:    cfg.Server,
		DeviceKey: cfg.DeviceKey,
		Key:       cfg.EncryptionKey,
		Client:    client,
		NewIV:     RandomIV,
	}
}

// RandomIV returns a fresh GCM nonce. Bark takes the IV as text and uses its UTF-8 bytes, so it is
// drawn from ASCII letters and digits to keep 12 characters equal to 12 bytes.
func RandomIV() string {
	return randomString(ivAlphabet, ivLength)
}

func GenerateKey() string {
	return randomString(config.BarkKeyAlphabet, config.BarkKeyLength)
}

// randomString uses rejection sampling so every character of the alphabet is equally likely.
func randomString(alphabet string, length int) string {
	limit := 256 - 256%len(alphabet)
	out := make([]byte, 0, length)
	buffer := make([]byte, length)
	for len(out) < length {
		_, _ = rand.Read(buffer) // crypto/rand.Read never returns an error; it crashes the program instead.
		for _, b := range buffer {
			if int(b) < limit && len(out) < length {
				out = append(out, alphabet[int(b)%len(alphabet)])
			}
		}
	}
	return string(out)
}

func (b *Bark) Send(ctx context.Context, n Notice) error {
	iv := b.NewIV()
	plaintext, err := json.Marshal(barkPayload{Title: n.Title, Body: n.Body, URL: n.URL, Group: barkGroup})
	if err != nil {
		return fmt.Errorf("bark: encode notice: %w", err)
	}
	ciphertext, err := encrypt(b.Key, iv, plaintext)
	if err != nil {
		return err
	}
	form := url.Values{"ciphertext": {ciphertext}, "iv": {iv}}

	var wrote atomic.Bool
	trace := &httptrace.ClientTrace{
		WroteRequest: func(httptrace.WroteRequestInfo) { wrote.Store(true) },
	}
	endpoint := b.Server + "/" + url.PathEscape(b.DeviceKey)
	request, err := http.NewRequestWithContext(httptrace.WithClientTrace(ctx, trace),
		http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return fmt.Errorf("bark: build request: %w", err)
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	response, err := b.Client.Do(request)
	if err != nil {
		if wrote.Load() {
			return fmt.Errorf("bark: %w: %w", ErrMaybeDelivered, err)
		}
		return fmt.Errorf("bark: send: %w", err)
	}
	defer response.Body.Close()
	return checkResponse(response)
}

func checkResponse(response *http.Response) error {
	raw, readErr := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if response.StatusCode >= http.StatusBadRequest {
		return fmt.Errorf("bark: server returned HTTP %d: %s", response.StatusCode, barkMessage(raw))
	}
	if readErr != nil {
		return fmt.Errorf("bark: %w: reading HTTP %d response: %w", ErrMaybeDelivered, response.StatusCode, readErr)
	}
	var reply barkResponse
	if err := json.Unmarshal(raw, &reply); err != nil {
		// The server accepted the request but the reply is not Bark's, so whether it pushed is unknown.
		return fmt.Errorf("bark: %w: HTTP %d with an unreadable reply %q: %w",
			ErrMaybeDelivered, response.StatusCode, truncate(string(raw)), err)
	}
	if response.StatusCode != http.StatusOK || reply.Code != http.StatusOK {
		return fmt.Errorf("bark: server returned HTTP %d, code %d: %s", response.StatusCode, reply.Code, reply.Message)
	}
	return nil
}

func barkMessage(raw []byte) string {
	var reply barkResponse
	if err := json.Unmarshal(raw, &reply); err == nil && reply.Message != "" {
		return reply.Message
	}
	return truncate(string(raw))
}

func truncate(s string) string {
	const limit = 200
	runes := []rune(s)
	if len(runes) <= limit {
		return s
	}
	return string(runes[:limit]) + "…"
}

// encrypt matches Bark's CryptoSwift setup (AES-256-GCM, combined mode): key and IV are the UTF-8
// bytes of the strings, and the output is base64 of the sealed text followed by the 16-byte tag.
func encrypt(key, iv string, plaintext []byte) (string, error) {
	block, err := aes.NewCipher([]byte(key))
	if err != nil {
		return "", fmt.Errorf("bark: encryption key must be %d bytes: %w", config.BarkKeyLength, err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", fmt.Errorf("bark: %w", err)
	}
	if len(iv) != gcm.NonceSize() {
		return "", fmt.Errorf("bark: IV %q is %d bytes, want %d", iv, len(iv), gcm.NonceSize())
	}
	return base64.StdEncoding.EncodeToString(gcm.Seal(nil, []byte(iv), plaintext, nil)), nil
}
