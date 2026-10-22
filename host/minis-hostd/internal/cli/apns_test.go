package cli

import (
	"encoding/base64"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/notify"
)

const deviceToken = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"

func TestAPNsRegisterSavesTheDeviceAndReturnsItsKey(t *testing.T) {
	dir := t.TempDir()
	status, stdout, stderr := runIn(dir, "apns", "register", deviceToken, "--topic", "com.example.pico", "--environment", "development", "--json")
	if status != ExitOK {
		t.Fatalf("status %d stderr %s", status, stderr)
	}
	var out apnsRegisterOutput
	if err := json.Unmarshal([]byte(stdout), &out); err != nil {
		t.Fatal(err)
	}
	key, err := base64.StdEncoding.DecodeString(out.Key)
	if err != nil || out.SchemaVersion != SchemaVersion {
		t.Fatalf("output %s", stdout)
	}
	saved, err := notify.LoadRegistration(filepath.Join(dir, notify.RegistrationFile))
	if err != nil {
		t.Fatal(err)
	}
	if saved.Token != deviceToken || saved.Topic != "com.example.pico" || saved.Environment != notify.Development ||
		string(saved.Key) != string(key) || !saved.RegisteredAt.Equal(fixedAt) {
		t.Errorf("saved %+v", saved)
	}
}

func TestAPNsRegisterRejectsBadInput(t *testing.T) {
	cases := [][]string{
		{"apns", "register", deviceToken, "--topic", "com.example.pico", "--json"},
		{"apns", "register", "XYZ", "--topic", "com.example.pico", "--environment", "development", "--json"},
		{"apns", "register", deviceToken, "--topic", "com.example.pico", "--environment", "staging", "--json"},
		{"apns", "unregister", "--json"},
	}
	for _, args := range cases {
		status, stdout, _ := runIn(t.TempDir(), args...)
		if status != ExitError || !strings.Contains(stdout, `"code":"bad_request"`) {
			t.Errorf("%v: status %d stdout %s", args, status, stdout)
		}
	}
}
