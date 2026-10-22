package notify

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"time"
)

// RegistrationFile sits next to config.toml; the app writes it through `apns register` and `apns activate`.
const RegistrationFile = "apns-device.json"

// PushKeyLength is AES-256's key size.
const PushKeyLength = 32

const keyIDLength = 8

type Environment string

const (
	Development Environment = "development"
	Production  Environment = "production"
)

// Device is one phone and the key its notices are sealed with.
type Device struct {
	Token        string      `json:"token"`
	Topic        string      `json:"topic"`
	Environment  Environment `json:"environment"`
	KeyID        string      `json:"keyId"`
	Key          []byte      `json:"key"`
	RegisteredAt time.Time   `json:"registeredAt"`
}

// Registrations holds the phone notices go to and the one waiting for the app to confirm it saved
// its key (apns spec §4). Only Active is ever used to send.
type Registrations struct {
	Active  *Device `json:"active,omitempty"`
	Pending *Device `json:"pending,omitempty"`
}

var ErrNotRegistered = errors.New("no iPhone is registered for Pico notifications; " +
	"in Pico open Settings → Remote Hosts → this host → Notifications and tap Send to This iPhone")

var (
	// APNs tokens are 32 bytes today; Apple says not to rely on the length, so any even run of hex is taken.
	deviceTokenPattern = regexp.MustCompile(`^([0-9a-f]{2}){32,100}$`)
	topicPattern       = regexp.MustCompile(`^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$`)
)

// NewDevice validates what the app sent and draws a fresh key and key id for it.
func NewDevice(token, topic string, environment Environment, now time.Time) (Device, error) {
	if !deviceTokenPattern.MatchString(token) {
		return Device{}, fmt.Errorf("device token %q is not lower-case hex", token)
	}
	if !topicPattern.MatchString(topic) {
		return Device{}, fmt.Errorf("topic %q is not a bundle id such as com.example.pico", topic)
	}
	if environment != Development && environment != Production {
		return Device{}, fmt.Errorf("environment %q must be %q or %q", environment, Development, Production)
	}
	key := make([]byte, PushKeyLength)
	keyID := make([]byte, keyIDLength)
	// crypto/rand.Read never returns an error; it crashes the program instead.
	_, _ = rand.Read(key)
	_, _ = rand.Read(keyID)
	return Device{
		Token: token, Topic: topic, Environment: environment,
		KeyID: hex.EncodeToString(keyID), Key: key, RegisteredAt: now.UTC(),
	}, nil
}

// WithPending replaces any earlier pending device; the active one keeps receiving notices.
func (r Registrations) WithPending(device Device) Registrations {
	return Registrations{Active: r.Active, Pending: &device}
}

// Activated promotes the pending device, but only the one whose key the app says it saved.
func (r Registrations) Activated(keyID string) (Registrations, error) {
	if r.Pending == nil || r.Pending.KeyID != keyID {
		return Registrations{}, fmt.Errorf("key %q is not the pending registration; tap Send to This iPhone again", keyID)
	}
	return Registrations{Active: r.Pending}, nil
}

// SaveRegistrations replaces the file atomically with mode 0600, because it holds the push keys.
func SaveRegistrations(path string, registrations Registrations) error {
	data, err := json.Marshal(registrations)
	if err != nil {
		return fmt.Errorf("encode registrations: %w", err)
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	temp, err := os.CreateTemp(dir, RegistrationFile+".*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if _, err := temp.Write(data); err != nil {
		_ = temp.Close()
		return fmt.Errorf("write %s: %w", temp.Name(), err)
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(temp.Name(), path)
}

// LoadRegistrations returns no registrations, not an error, when the file does not exist yet.
func LoadRegistrations(path string) (Registrations, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Registrations{}, nil
	}
	if err != nil {
		return Registrations{}, err
	}
	var registrations Registrations
	if err := json.Unmarshal(data, &registrations); err != nil {
		return Registrations{}, fmt.Errorf("%s is unreadable (%w); register the iPhone again", path, err)
	}
	for _, device := range []*Device{registrations.Active, registrations.Pending} {
		if device != nil && len(device.Key) != PushKeyLength {
			return Registrations{}, fmt.Errorf("%s holds a %d-byte key, want %d; register the iPhone again",
				path, len(device.Key), PushKeyLength)
		}
	}
	return registrations, nil
}

// ActiveDevice is the phone notices go to now.
func ActiveDevice(path string) (Device, error) {
	registrations, err := LoadRegistrations(path)
	if err != nil {
		return Device{}, err
	}
	if registrations.Active == nil {
		return Device{}, ErrNotRegistered
	}
	return *registrations.Active, nil
}
