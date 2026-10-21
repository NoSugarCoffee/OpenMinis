package cli

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/service"
)

const testHostKeyFile = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKZLkiISgErH3yhnlmPsTraduwwNsQAXgtmW88hYus50 root@mini\n"

// Same vector as internal/pairing and the app's tests.
const (
	pairVectorPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKn78iqpSP+qI9YVAkEx9IFgvGfJNWffdtQLrSCdKh8p minis@iPhone"
	pairVectorMAC       = "c9b6420d8207f338f2ce7ecbd4aff2f43e3cc8656524f10881dcfa45fc836611"
)

func fakePairDeps(t *testing.T, ready func(port int)) pairDeps {
	t.Helper()
	return pairDeps{
		Hostname: func() (string, error) { return "Mac-mini.local", nil },
		Username: func() (string, error) { return "light", nil },
		Addresses: func() ([]net.IP, error) {
			return []net.IP{net.ParseIP("192.168.1.5"), net.ParseIP("100.81.208.83")}, nil
		},
		ReadFile: func(path string) ([]byte, error) {
			if path != hostKeyPath {
				t.Errorf("read %s", path)
			}
			return []byte(testHostKeyFile), nil
		},
		DialSSH: func(int) error { return nil },
		Listen:  func() (net.Listener, error) { return net.Listen("tcp4", "127.0.0.1:0") },
		Random: func(b []byte) error {
			for i := range b {
				b[i] = byte(i)
			}
			return nil
		},
		Timeout: time.Minute,
		Ready:   ready,
	}
}

func sendPairRequest(port int, publicKey, mac string) (string, error) {
	conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		return "", err
	}
	defer conn.Close()
	line, _ := json.Marshal(map[string]any{"v": 1, "publicKey": publicKey, "mac": mac})
	conn.Write(append(line, '\n'))
	return bufio.NewReader(conn).ReadString('\n')
}

func TestPairPrintsTheCodeAndInstallsTheKey(t *testing.T) {
	env, out, errOut, home := setupEnv(t, &recordingRunner{})
	replies := make(chan string, 1)
	deps := fakePairDeps(t, func(port int) {
		go func() {
			reply, err := sendPairRequest(port, pairVectorPublicKey, pairVectorMAC)
			if err != nil {
				reply = "error: " + err.Error()
			}
			replies <- reply
		}()
	})
	if status := runPair(env, nil, deps); status != ExitOK {
		t.Fatalf("status %d stderr %q", status, errOut)
	}
	text := out.String()
	for _, want := range []string{
		"Mac-mini: light@100.81.208.83, 192.168.1.5\n",
		"Settings → Remote Hosts → Add Host. Waiting up to 1 minute…",
		"Paired minis@iPhone.\n",
		"█",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("stdout lacks %q:\n%s", want, text)
		}
	}
	contents, err := os.ReadFile(filepath.Join(home, ".ssh", "authorized_keys"))
	if err != nil || string(contents) != pairVectorPublicKey+"\n" {
		t.Errorf("authorized_keys %q %v", contents, err)
	}
	if reply := <-replies; reply != `{"ok":true}`+"\n" {
		t.Errorf("reply %q", reply)
	}
}

func TestPairPayloadCarriesTheContract(t *testing.T) {
	env, _, _, _ := setupEnv(t, &recordingRunner{})
	session, err := preparePairing(env, pairOptions{Name: "", SSHPort: 2222}, fakePairDeps(t, func(int) {}))
	if err != nil {
		t.Fatal(err)
	}
	defer session.Listener.Close()
	text, _ := session.Payload.Text()
	var decoded map[string]any
	if err := json.Unmarshal([]byte(strings.TrimPrefix(text, "minis-pair:")), &decoded); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"v": 1.0, "name": "Mac-mini", "user": "light", "port": 2222.0,
		"hostKey": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKZLkiISgErH3yhnlmPsTraduwwNsQAXgtmW88hYus50",
		"secret":  "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
	}
	for k, v := range want {
		if decoded[k] != v {
			t.Errorf("%s = %v, want %v", k, decoded[k], v)
		}
	}
	if fmt.Sprint(decoded["addresses"]) != "[100.81.208.83 192.168.1.5]" {
		t.Errorf("addresses %v", decoded["addresses"])
	}
	if decoded["pairPort"] != float64(session.Listener.Addr().(*net.TCPAddr).Port) {
		t.Errorf("pairPort %v", decoded["pairPort"])
	}
	if len(decoded) != 8 {
		t.Errorf("fields %v", decoded)
	}
}

func TestPairPreflightFailuresNameTheFix(t *testing.T) {
	cases := []struct {
		name   string
		goos   string
		change func(*pairDeps)
		want   string
	}{
		{"remote login off", "darwin", func(d *pairDeps) { d.DialSSH = func(int) error { return errors.New("refused") } },
			"Turn it on in System Settings → General → Sharing → Remote Login"},
		{"sshd off", "linux", func(d *pairDeps) { d.DialSSH = func(int) error { return errors.New("refused") } },
			"sshd is not running"},
		{"no host key", "darwin", func(d *pairDeps) { d.ReadFile = func(string) ([]byte, error) { return nil, os.ErrNotExist } },
			"sudo ssh-keygen -A"},
		{"rsa host key", "darwin", func(d *pairDeps) {
			d.ReadFile = func(string) ([]byte, error) { return []byte("ssh-rsa AAAAB3Nza root@mini"), nil }
		}, "not an ssh-ed25519 public key"},
		{"no addresses", "darwin", func(d *pairDeps) {
			d.Addresses = func() ([]net.IP, error) { return []net.IP{net.ParseIP("127.0.0.1")}, nil }
		}, "no Tailscale or private network address"},
	}
	for _, c := range cases {
		env, out, errOut, _ := setupEnv(t, &recordingRunner{})
		env.Setup.GOOS = c.goos
		deps := fakePairDeps(t, func(int) { t.Errorf("%s: code shown", c.name) })
		listened := false
		deps.Listen = func() (net.Listener, error) { listened = true; return net.Listen("tcp4", "127.0.0.1:0") }
		c.change(&deps)
		if status := runPair(env, nil, deps); status != ExitError || !strings.Contains(errOut.String(), c.want) {
			t.Errorf("%s: status %d stderr %q", c.name, status, errOut)
		}
		if out.Len() != 0 || listened {
			t.Errorf("%s: stdout %q listened %v", c.name, out, listened)
		}
	}
}

func writePairConfig(t *testing.T, home, text string) string {
	t.Helper()
	path := service.DefaultPaths(home).Config
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestPairNameFollowsTheConfig(t *testing.T) {
	cases := []struct {
		name      string
		config    string
		requested string
		want      string
		wantErr   string
	}{
		{name: "no config uses the computer name", want: "Mac-mini"},
		{name: "no config takes --name", requested: "mini", want: "mini"},
		{name: "config host_name wins", config: "host_name = \"macmini\"\n[bark]\n", want: "macmini"},
		{name: "matching --name", config: "host_name = \"macmini\"\n", requested: "macmini", want: "macmini"},
		{name: "conflicting --name", config: "host_name = \"macmini\"\n", requested: "mini",
			wantErr: `names this host "macmini", so its pushes open only a host named "macmini" in Minis`},
		{name: "bad host_name", config: "host_name = \"my mac\"\n", wantErr: "host_name: must be the host's name"},
		{name: "broken TOML", config: "host_name = \"macmini\"\ndevice_key = abc\n", wantErr: "Fix the file, or move it aside"},
	}
	for _, c := range cases {
		env, _, _, home := setupEnv(t, &recordingRunner{})
		if c.config != "" {
			writePairConfig(t, home, c.config)
		}
		session, err := preparePairing(env, pairOptions{Name: c.requested, SSHPort: 22}, fakePairDeps(t, func(int) {}))
		if c.wantErr != "" {
			if err == nil || !strings.Contains(err.Error(), c.wantErr) {
				t.Errorf("%s: err %v", c.name, err)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: %v", c.name, err)
			continue
		}
		session.Listener.Close()
		if session.Payload.Name != c.want {
			t.Errorf("%s: name %q, want %q", c.name, session.Payload.Name, c.want)
		}
	}
}

func TestPairTimeoutWritesNothing(t *testing.T) {
	env, _, errOut, home := setupEnv(t, &recordingRunner{})
	deps := fakePairDeps(t, func(int) {})
	deps.Timeout = 50 * time.Millisecond
	if status := runPair(env, nil, deps); status != ExitError || !strings.Contains(errOut.String(), "No phone paired within") {
		t.Errorf("status %d stderr %q", status, errOut)
	}
	if _, err := os.Stat(filepath.Join(home, ".ssh")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf(".ssh exists: %v", err)
	}
}

func TestPairArgs(t *testing.T) {
	good := map[string]pairOptions{
		"":                             {SSHPort: 22},
		"--name mini":                  {Name: "mini", SSHPort: 22},
		"--ssh-port 2222 --name mac_1": {Name: "mac_1", SSHPort: 2222},
	}
	for args, want := range good {
		got, err := parsePairArgs(strings.Fields(args))
		if err != nil || got != want {
			t.Errorf("%q: %+v %v", args, got, err)
		}
	}
	for _, args := range []string{"--name", "--name a --name b", "--ssh-port 0", "--ssh-port x", "--name my.mac", "--json"} {
		if _, err := parsePairArgs(strings.Fields(args)); err == nil {
			t.Errorf("%q accepted", args)
		}
	}
}
