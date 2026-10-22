package notify

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRegistrationRoundTripsWithMode600(t *testing.T) {
	registration, err := NewRegistration(testToken, testTopic, Production, apnsT0)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "hostd", RegistrationFile)
	if err := SaveRegistration(path, registration); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("mode %#o", info.Mode().Perm())
	}
	loaded, err := LoadRegistration(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Token != testToken || loaded.Topic != testTopic || loaded.Environment != Production ||
		string(loaded.Key) != string(registration.Key) || !loaded.RegisteredAt.Equal(apnsT0) {
		t.Errorf("loaded %+v", loaded)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Errorf("left a temp file: %v", entries)
	}
}

func TestEachRegistrationGetsAFreshKey(t *testing.T) {
	first, _ := NewRegistration(testToken, testTopic, Development, apnsT0)
	second, _ := NewRegistration(testToken, testTopic, Development, apnsT0)
	if len(first.Key) != PushKeyLength || string(first.Key) == string(second.Key) {
		t.Errorf("keys %x and %x", first.Key, second.Key)
	}
}

func TestNewRegistrationRejectsBadInput(t *testing.T) {
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
		if _, err := NewRegistration(tc.token, tc.topic, tc.environment, apnsT0); err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%q %q %q: err = %v, want %q", tc.token, tc.topic, tc.environment, err, tc.want)
		}
	}
}

func TestMissingRegistrationIsNotRegistered(t *testing.T) {
	_, err := LoadRegistration(filepath.Join(t.TempDir(), RegistrationFile))
	if !errors.Is(err, ErrNotRegistered) {
		t.Fatalf("err = %v", err)
	}
}
