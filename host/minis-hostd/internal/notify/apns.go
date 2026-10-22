package notify

import (
	"bytes"
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
	"fmt"
	"io"
	"net/http"
	"net/http/httptrace"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/config"
)

const (
	SandboxEndpoint    = "https://api.sandbox.push.apple.com"
	ProductionEndpoint = "https://api.push.apple.com"
)

// APNs refuses a provider token refreshed more than once in 20 minutes and one older than an hour.
const providerTokenLifetime = 40 * time.Minute

// A phone that is off gets the notice when it comes back within this window.
const noticeExpiry = 24 * time.Hour

const payloadVersion = 1

// The alert Apple sees; the Notification Service Extension replaces it with the decrypted notice.
const (
	placeholderTitle = "New event"
	placeholderBody  = "Open Pico to read it."
)

// APNs sends notices straight to Apple's push service with the user's own key (apns spec §3).
type APNs struct {
	KeyID            string
	TeamID           string
	Key              *ecdsa.PrivateKey
	HostName         string
	RegistrationPath string
	Endpoints        map[Environment]string
	Client           *http.Client
	Now              func() time.Time

	mu            sync.Mutex
	providerToken string
	issuedAt      time.Time
}

func NewAPNs(cfg config.APNs, hostName, registrationPath string, client *http.Client) (*APNs, error) {
	key, err := LoadAPNsKey(cfg.KeyFile)
	if err != nil {
		return nil, err
	}
	return &APNs{
		KeyID:            cfg.KeyID,
		TeamID:           cfg.TeamID,
		Key:              key,
		HostName:         hostName,
		RegistrationPath: registrationPath,
		Endpoints:        map[Environment]string{Development: SandboxEndpoint, Production: ProductionEndpoint},
		Client:           client,
		Now:              time.Now,
	}, nil
}

// LoadAPNsKey reads the .p8 file from the Apple Developer site: a PKCS #8 P-256 key in PEM.
func LoadAPNsKey(path string) (*ecdsa.PrivateKey, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("apns: key file: %w", err)
	}
	if info.Mode().Perm()&0o077 != 0 {
		return nil, fmt.Errorf("apns: %s is mode %#o but can push to every app of the team; run `chmod 600 %s`",
			path, info.Mode().Perm(), path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("apns: key file: %w", err)
	}
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "PRIVATE KEY" {
		return nil, fmt.Errorf("apns: %s is not the AuthKey .p8 file (no PRIVATE KEY block)", path)
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("apns: %s: %w", path, err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, fmt.Errorf("apns: %s is not a P-256 key; download an APNs key, not another kind", path)
	}
	return key, nil
}

type apnsAlert struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

type apnsAPS struct {
	Alert          apnsAlert `json:"alert"`
	MutableContent int       `json:"mutable-content"`
	ThreadID       string    `json:"thread-id"`
	Sound          string    `json:"sound"`
}

// PicoEnvelope is what the extension decrypts; the app's PicoPush package reads the same fields.
type PicoEnvelope struct {
	Version    int    `json:"v"`
	Host       string `json:"host"`
	KeyID      string `json:"k"`
	Ciphertext string `json:"c"`
}

type apnsPayload struct {
	APS  apnsAPS      `json:"aps"`
	Pico PicoEnvelope `json:"pico"`
}

// SealedNotice is the plaintext inside PicoEnvelope.Ciphertext.
type SealedNotice struct {
	Title string `json:"title"`
	Body  string `json:"body"`
	URL   string `json:"url,omitempty"`
}

type apnsErrorReply struct {
	Reason string `json:"reason"`
}

func (a *APNs) Send(ctx context.Context, n Notice) error {
	device, err := ActiveDevice(a.RegistrationPath)
	if err != nil {
		return fmt.Errorf("apns: %w", err)
	}
	endpoint, ok := a.Endpoints[device.Environment]
	if !ok {
		return fmt.Errorf("apns: %w: registration names environment %q; register the iPhone again",
			ErrPermanent, device.Environment)
	}
	body, err := a.payload(device, n)
	if err != nil {
		return err
	}
	providerToken, err := a.currentProviderToken()
	if err != nil {
		return err
	}

	var wrote atomic.Bool
	trace := &httptrace.ClientTrace{
		WroteRequest: func(info httptrace.WroteRequestInfo) { wrote.Store(info.Err == nil) },
	}
	request, err := http.NewRequestWithContext(httptrace.WithClientTrace(ctx, trace),
		http.MethodPost, endpoint+"/3/device/"+device.Token, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("apns: build request: %w", err)
	}
	request.Header.Set("authorization", "bearer "+providerToken)
	request.Header.Set("apns-topic", device.Topic)
	request.Header.Set("apns-push-type", "alert")
	request.Header.Set("apns-priority", "10")
	request.Header.Set("apns-expiration", strconv.FormatInt(a.Now().Add(noticeExpiry).Unix(), 10))

	response, err := a.Client.Do(request)
	if err != nil {
		if wrote.Load() {
			return fmt.Errorf("apns: %w: %w", ErrMaybeDelivered, err)
		}
		return fmt.Errorf("apns: send: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusForbidden {
		// The provider token was refused (expired, revoked or wrong); the next send must sign a new one.
		a.dropProviderToken()
	}
	return apnsResult(response, device)
}

func (a *APNs) payload(device Device, n Notice) ([]byte, error) {
	plaintext, err := json.Marshal(SealedNotice(n))
	if err != nil {
		return nil, fmt.Errorf("apns: encode notice: %w", err)
	}
	sealed, err := SealNotice(device.Key, a.HostName, plaintext)
	if err != nil {
		return nil, err
	}
	return json.Marshal(apnsPayload{
		APS: apnsAPS{
			Alert:          apnsAlert{Title: placeholderTitle, Body: placeholderBody},
			MutableContent: 1,
			ThreadID:       a.HostName,
			Sound:          "default",
		},
		Pico: PicoEnvelope{Version: payloadVersion, Host: a.HostName, KeyID: device.KeyID, Ciphertext: sealed},
	})
}

// SealNotice returns base64(nonce ‖ ciphertext ‖ tag), the layout CryptoKit's AES.GCM.SealedBox(combined:)
// reads. The additional data ties the notice to its host, so one host's key cannot open another's.
func SealNotice(key []byte, hostName string, plaintext []byte) (string, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", fmt.Errorf("apns: push key: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", fmt.Errorf("apns: %w", err)
	}
	nonce := make([]byte, gcm.NonceSize())
	_, _ = rand.Read(nonce) // crypto/rand.Read never returns an error; it crashes the program instead.
	return base64.StdEncoding.EncodeToString(gcm.Seal(nonce, nonce, plaintext, AdditionalData(hostName))), nil
}

func AdditionalData(hostName string) []byte {
	return []byte("pico-push-v1:" + hostName)
}

func (a *APNs) dropProviderToken() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.providerToken = ""
}

func (a *APNs) currentProviderToken() (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	// Wall-clock time, as APNs checks iat: a monotonic reading stops while the host sleeps.
	now := a.Now().Round(0)
	if a.providerToken != "" && now.Sub(a.issuedAt) < providerTokenLifetime {
		return a.providerToken, nil
	}
	token, err := ProviderToken(a.Key, a.KeyID, a.TeamID, now)
	if err != nil {
		return "", err
	}
	a.providerToken, a.issuedAt = token, now
	return token, nil
}

// ProviderToken is the ES256 JWT APNs takes as a bearer token. JWS wants the raw 64-byte r ‖ s
// signature, not the ASN.1 form crypto/ecdsa produces by default.
func ProviderToken(key *ecdsa.PrivateKey, keyID, teamID string, now time.Time) (string, error) {
	encode := base64.RawURLEncoding.EncodeToString
	header, err := json.Marshal(map[string]string{"alg": "ES256", "kid": keyID})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{"iss": teamID, "iat": now.Unix()})
	if err != nil {
		return "", err
	}
	signingInput := encode(header) + "." + encode(claims)
	digest := sha256.Sum256([]byte(signingInput))
	r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		return "", fmt.Errorf("apns: sign provider token: %w", err)
	}
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])
	return signingInput + "." + encode(signature), nil
}

// registrationReasons are refusals that tapping Send to This iPhone again fixes.
var registrationReasons = map[string]bool{"Unregistered": true, "BadDeviceToken": true, "DeviceTokenNotForTopic": true, "BadTopic": true}

const reRegister = "in Pico open Settings → Remote Hosts → this host → Notifications and tap Send to This iPhone"

// apnsResult names the cause of each refusal (apns spec §3). 429 and 5xx are retried, and so are the
// refusals a new registration fixes, since every send re-reads it. Any other 4xx is permanent: resending
// cannot fix it, and a config change needs a restart.
func apnsResult(response *http.Response, device Device) error {
	raw, readErr := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	status := response.StatusCode
	if status == http.StatusOK {
		return nil
	}
	reason := truncate(string(raw))
	var reply apnsErrorReply
	if readErr == nil && json.Unmarshal(raw, &reply) == nil && reply.Reason != "" {
		reason = reply.Reason
	}
	var hint string
	switch reply.Reason {
	case "Unregistered":
		hint = "the app was removed or its token changed; " + reRegister
	case "BadDeviceToken":
		hint = fmt.Sprintf("the token is not a %s token; %s", device.Environment, reRegister)
	case "DeviceTokenNotForTopic", "BadTopic", "TopicDisallowed":
		hint = fmt.Sprintf("%s is not the app this token belongs to, or apns.team_id does not sign it", device.Topic)
	case "InvalidProviderToken", "ExpiredProviderToken", "MissingProviderToken":
		hint = "check apns.key_id, apns.team_id and the key file in config.toml"
	}
	message := fmt.Sprintf("HTTP %d %s", status, reason)
	if hint != "" {
		message += ": " + hint
	}
	// An expired provider token was dropped in Send, so the outbox's next attempt signs a fresh one.
	retryable := registrationReasons[reply.Reason] || reply.Reason == "ExpiredProviderToken"
	if status == http.StatusTooManyRequests || status >= http.StatusInternalServerError || retryable {
		return fmt.Errorf("apns: %s", message)
	}
	return fmt.Errorf("apns: %w: %s", ErrPermanent, message)
}

var _ Notifier = (*APNs)(nil)
