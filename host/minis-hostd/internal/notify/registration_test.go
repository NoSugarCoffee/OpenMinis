package notify

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestDevice(t *testing.T) Device {
	t.Helper()
	device, err := NewDevice(testToken, testTopic, Production, apnsT0)
	if err != nil {
		t.Fatal(err)
	}
	return device
}

func TestRegistrationsRoundTripWithMode600(t *testing.T) {
	active, pending := newTestDevice(t), newTestDevice(t)
	path := filepath.Join(t.TempDir(), "hostd", RegistrationFile)
	if err := SaveRegistrations(path, Registrations{Active: &active, Pending: &pending}); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("mode %#o", info.Mode().Perm())
	}
	loaded, err := LoadRegistrations(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Active.KeyID != active.KeyID || string(loaded.Pending.Key) != string(pending.Key) ||
		loaded.Active.Environment != Production || !loaded.Active.RegisteredAt.Equal(apnsT0) {
		t.Errorf("loaded %+v %+v", loaded.Active, loaded.Pending)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Errorf("left a temp file: %v", entries)
	}
}

func TestEachDeviceGetsAFreshKeyAndKeyID(t *testing.T) {
	first, second := newTestDevice(t), newTestDevice(t)
	if len(first.Key) != PushKeyLength || string(first.Key) == string(second.Key) ||
		len(first.KeyID) != 2*keyIDLength || first.KeyID == second.KeyID {
		t.Errorf("first %+v second %+v", first, second)
	}
}

func TestOnlyThePendingKeyActivates(t *testing.T) {
	active, pending := newTestDevice(t), newTestDevice(t)
	staged := Registrations{Active: &active}.WithPending(pending)
	if staged.Active.KeyID != active.KeyID {
		t.Fatal("staging replaced the active device")
	}
	if _, err := staged.Activated(active.KeyID); err == nil {
		t.Error("activated a key that is not pending")
	}
	activated, err := staged.Activated(pending.KeyID)
	if err != nil {
		t.Fatal(err)
	}
	if activated.Active.KeyID != pending.KeyID || activated.Pending != nil {
		t.Errorf("activated %+v", activated)
	}
	if _, err := activated.Activated(pending.KeyID); err == nil {
		t.Error("activated the same key twice")
	}
}

func TestNewDeviceRejectsBadInput(t *testing.T) {
	cases := []struct {
		token, topic string
		environment  Environment
		want         string
	}{
		{"ABCD" + testToken[4:], testTopic, Development, "lower-case hex"},
		{testToken[:62], testTopic, Development, "lower-case hex"},
		{testToken, "pico", Development, "bundle id"},
		{testToken, testTopic, "staging", "environment"},
	}
	for _, tc := range cases {
		if _, err := NewDevice(tc.token, tc.topic, tc.environment, apnsT0); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%q %q %q: err = %v, want %q", tc.token, tc.topic, tc.environment, err, tc.want)
		}
	}
}

func TestNoActiveDeviceIsNotRegistered(t *testing.T) {
	dir := t.TempDir()
	if _, err := ActiveDevice(filepath.Join(dir, RegistrationFile)); !errors.Is(err, ErrNotRegistered) {
		t.Fatalf("missing file: err = %v", err)
	}
	pending := newTestDevice(t)
	path := filepath.Join(dir, RegistrationFile)
	if err := SaveRegistrations(path, Registrations{Pending: &pending}); err != nil {
		t.Fatal(err)
	}
	if _, err := ActiveDevice(path); !errors.Is(err, ErrNotRegistered) {
		t.Fatalf("only pending: err = %v", err)
	}
}
