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
	"syscall"
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
	deviceTokenPattern = regexp.MustCompile(`^([0-9a-f]{2})+$`)
	topicPattern       = regexp.MustCompile(`^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$`)
	keyIDPattern       = regexp.MustCompile(`^[0-9a-f]{16}$`)
)

// NewDevice validates what the app sent and draws a fresh key and key id for it.
func NewDevice(token, topic string, environment Environment, now time.Time) (Device, error) {
	if !deviceTokenPattern.MatchString(token) {
		return Device{}, fmt.Errorf("device token %q is not an even number of lower-case hex digits", token)
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
	if err := r.Pending.check(); err != nil {
		return Registrations{}, fmt.Errorf("the pending registration is unusable (%w); tap Send to This iPhone again", err)
	}
	return Registrations{Active: r.Pending}, nil
}

// SaveRegistrations replaces the file atomically with mode 0600, because it holds the push keys. The
// directory must not be writable by others, or another user could swap in a key they control.
func SaveRegistrations(path string, registrations Registrations) error {
	data, err := json.Marshal(registrations)
	if err != nil {
		return fmt.Errorf("encode registrations: %w", err)
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := checkPrivateDir(dir); err != nil {
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
	// Without the sync a crash after the rename can leave an empty file in place of the registration.
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return fmt.Errorf("sync %s: %w", temp.Name(), err)
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(temp.Name(), path)
}

func checkPrivateDir(dir string) error {
	info, err := os.Stat(dir)
	if err != nil {
		return err
	}
	if info.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("%s is mode %#o, so other users could replace the push registration; run `chmod 700 %s`",
			dir, info.Mode().Perm(), dir)
	}
	return nil
}

// LoadRegistrations returns no registrations, not an error, when the file does not exist yet. Only the
// active device is checked here; a pending one is checked when it is activated.
func LoadRegistrations(path string) (Registrations, error) {
	info, err := os.Stat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Registrations{}, nil
	}
	if err != nil {
		return Registrations{}, err
	}
	if info.Mode().Perm()&0o077 != 0 {
		return Registrations{}, fmt.Errorf("%s is mode %#o but holds push keys; run `chmod 600 %s`",
			path, info.Mode().Perm(), path)
	}
	if err := checkPrivateDir(filepath.Dir(path)); err != nil {
		return Registrations{}, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return Registrations{}, err
	}
	var registrations Registrations
	if err := json.Unmarshal(data, &registrations); err != nil {
		return Registrations{}, fmt.Errorf("%s is unreadable (%w); tap Send to This iPhone in Pico to replace it", path, err)
	}
	if registrations.Active != nil {
		if err := registrations.Active.check(); err != nil {
			return Registrations{}, fmt.Errorf("%s: %w; tap Send to This iPhone in Pico to replace it", path, err)
		}
	}
	return registrations, nil
}

func (d Device) check() error {
	if !deviceTokenPattern.MatchString(d.Token) {
		return fmt.Errorf("the device token %q is not an even number of lower-case hex digits", d.Token)
	}
	if !topicPattern.MatchString(d.Topic) {
		return fmt.Errorf("the topic %q is not a bundle id", d.Topic)
	}
	if !keyIDPattern.MatchString(d.KeyID) {
		return fmt.Errorf("the key id %q is not 16 lower-case hex digits", d.KeyID)
	}
	if len(d.Key) != PushKeyLength {
		return fmt.Errorf("the key is %d bytes, want %d", len(d.Key), PushKeyLength)
	}
	if d.Environment != Development && d.Environment != Production {
		return fmt.Errorf("environment %q must be %q or %q", d.Environment, Development, Production)
	}
	return nil
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

// WithRegistrationLock serializes `apns register` and `apns activate`: each reads, changes and rewrites
// the file, and a launch-time re-registration can overlap one the user started.
func WithRegistrationLock(path string, change func() error) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return fmt.Errorf("lock %s: %w", lock.Name(), err)
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	return change()
}
