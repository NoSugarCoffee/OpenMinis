package notify

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"time"
)

// RegistrationFile sits next to config.toml; the app writes it through `apns register`.
const RegistrationFile = "apns-device.json"

// PushKeyLength is AES-256's key size.
const PushKeyLength = 32

type Environment string

const (
	Development Environment = "development"
	Production  Environment = "production"
)

// Registration is the one phone that receives this host's notices (apns spec §4).
type Registration struct {
	Token        string      `json:"token"`
	Topic        string      `json:"topic"`
	Environment  Environment `json:"environment"`
	Key          []byte      `json:"key"`
	RegisteredAt time.Time   `json:"registeredAt"`
}

var ErrNotRegistered = errors.New("no iPhone is registered for Pico notifications; " +
	"in Pico open Settings → Remote Hosts → this host → Notifications and tap Send to This iPhone")

var (
	// APNs tokens are 32 bytes today; Apple says not to rely on the length, so any even run of hex is taken.
	deviceTokenPattern = regexp.MustCompile(`^([0-9a-f]{2}){32,100}$`)
	topicPattern       = regexp.MustCompile(`^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$`)
)

// NewRegistration validates what the app sent and draws a fresh key for it.
func NewRegistration(token, topic string, environment Environment, now time.Time) (Registration, error) {
	if !deviceTokenPattern.MatchString(token) {
		return Registration{}, fmt.Errorf("device token %q is not lower-case hex", token)
	}
	if !topicPattern.MatchString(topic) {
		return Registration{}, fmt.Errorf("topic %q is not a bundle id such as com.example.pico", topic)
	}
	if environment != Development && environment != Production {
		return Registration{}, fmt.Errorf("environment %q must be %q or %q", environment, Development, Production)
	}
	key := make([]byte, PushKeyLength)
	_, _ = rand.Read(key) // crypto/rand.Read never returns an error; it crashes the program instead.
	return Registration{Token: token, Topic: topic, Environment: environment, Key: key, RegisteredAt: now.UTC()}, nil
}

// SaveRegistration replaces the file atomically with mode 0600, because it holds the push key.
func SaveRegistration(path string, registration Registration) error {
	data, err := json.Marshal(registration)
	if err != nil {
		return fmt.Errorf("encode registration: %w", err)
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

func LoadRegistration(path string) (Registration, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Registration{}, ErrNotRegistered
	}
	if err != nil {
		return Registration{}, err
	}
	var registration Registration
	if err := json.Unmarshal(data, &registration); err != nil {
		return Registration{}, fmt.Errorf("%s is unreadable (%w); register the iPhone again", path, err)
	}
	if len(registration.Key) != PushKeyLength {
		return Registration{}, fmt.Errorf("%s holds a %d-byte key, want %d; register the iPhone again",
			path, len(registration.Key), PushKeyLength)
	}
	return registration, nil
}
