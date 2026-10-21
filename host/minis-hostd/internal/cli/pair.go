package cli

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"net"
	"os"
	"os/user"
	"strconv"
	"strings"
	"time"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/pairing"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/service"
)

const (
	usagePair      = "minis-hostd pair [--name <name>] [--ssh-port <port>]"
	hostKeyPath    = "/etc/ssh/ssh_host_ed25519_key.pub"
	pairTimeout    = 5 * time.Minute
	pairMaxBadMACs = 5
	sshDialTimeout = time.Second
)

// pairDeps holds what pair reads from the machine, so tests run it against a temp home and a
// loopback listener.
type pairDeps struct {
	Hostname  func() (string, error)
	Username  func() (string, error)
	Addresses func() ([]net.IP, error)
	ReadFile  func(path string) ([]byte, error)
	DialSSH   func(port int) error
	Listen    func() (net.Listener, error)
	Random    func([]byte) error
	Timeout   time.Duration
	// Ready receives the listener's port once the code is printed; tests use it to connect.
	Ready func(port int)
}

func productionPairDeps() pairDeps {
	return pairDeps{
		Hostname: os.Hostname,
		Username: func() (string, error) {
			current, err := user.Current()
			if err != nil {
				return "", err
			}
			return current.Username, nil
		},
		Addresses: upInterfaceIPs,
		ReadFile:  os.ReadFile,
		DialSSH: func(port int) error {
			conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), sshDialTimeout)
			if err != nil {
				return err
			}
			return conn.Close()
		},
		Listen:  func() (net.Listener, error) { return net.Listen("tcp4", ":0") },
		Random:  func(b []byte) error { _, err := rand.Read(b); return err },
		Timeout: pairTimeout,
		Ready:   func(int) {},
	}
}

func upInterfaceIPs() ([]net.IP, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	var ips []net.IP
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			return nil, err
		}
		for _, addr := range addrs {
			if network, ok := addr.(*net.IPNet); ok {
				ips = append(ips, network.IP)
			}
		}
	}
	return ips, nil
}

type pairOptions struct {
	Name    string
	SSHPort int
}

func parsePairArgs(args []string) (pairOptions, error) {
	options := pairOptions{SSHPort: 22}
	seen := map[string]bool{}
	for i := 0; i < len(args); i++ {
		flag := args[i]
		if (flag != "--name" && flag != "--ssh-port") || seen[flag] || i+1 == len(args) {
			return pairOptions{}, errors.New("usage: " + usagePair)
		}
		seen[flag] = true
		value := args[i+1]
		i++
		switch flag {
		case "--name":
			if pairing.CleanName(value) != value {
				return pairOptions{}, fmt.Errorf("%q is not a valid Minis host name. Use 1–32 letters, digits, “-” or “_”.", value)
			}
			options.Name = value
		case "--ssh-port":
			port, err := strconv.Atoi(value)
			if err != nil || port < 1 || port > 65535 {
				return pairOptions{}, fmt.Errorf("%q is not a valid port. Use a number from 1 to 65535.", value)
			}
			options.SSHPort = port
		}
	}
	return options, nil
}

func runPair(env Env, args []string, deps pairDeps) int {
	options, err := parsePairArgs(args)
	if err != nil {
		return plainFail(env, err.Error())
	}
	session, err := preparePairing(env, options, deps)
	if err != nil {
		return plainFail(env, err.Error())
	}
	payload := session.Payload
	drawn, err := drawPayload(payload)
	if err != nil {
		session.Listener.Close()
		return plainFail(env, err.Error())
	}
	fmt.Fprint(env.Stdout, drawn)
	fmt.Fprintf(env.Stdout, "\n%s: %s@%s\n", payload.Name, payload.User, strings.Join(payload.Addresses, ", "))
	fmt.Fprintf(env.Stdout, "Scan this code in Minis: Settings → Remote Hosts → Add Host. Waiting up to %s…\n",
		formatMinutes(deps.Timeout))
	deps.Ready(payload.PairPort)

	ctx, cancel := context.WithTimeout(context.Background(), deps.Timeout)
	defer cancel()
	key, err := pairing.Serve(ctx, session.Listener, session.Secret, pairMaxBadMACs, func(key pairing.AuthorizedKey) error {
		_, err := pairing.AddAuthorizedKey(env.Setup.Home, key)
		return err
	})
	switch {
	case errors.Is(err, pairing.ErrTimedOut):
		return plainFail(env, fmt.Sprintf("No phone paired within %s. Run `minis-hostd pair` again.", formatMinutes(deps.Timeout)))
	case errors.Is(err, pairing.ErrTooManyBadMACs):
		return plainFail(env, fmt.Sprintf("Stopped after %d pairing attempts with the wrong code; nothing was written. Run `minis-hostd pair` again and scan the new code.", pairMaxBadMACs))
	case err != nil:
		return plainFail(env, err.Error())
	}
	comment := key.Comment
	if comment == "" {
		comment = "a phone"
	}
	return plain(env, "Paired "+comment+".")
}

type pairingSession struct {
	Payload  pairing.Payload
	Secret   []byte
	Listener net.Listener
}

func drawPayload(payload pairing.Payload) (string, error) {
	text, err := payload.Text()
	if err != nil {
		return "", err
	}
	return pairing.RenderQR(text)
}

// preparePairing runs every check before the listener opens, so a host that cannot pair never shows
// a code that would not work.
func preparePairing(env Env, options pairOptions, deps pairDeps) (pairingSession, error) {
	if err := deps.DialSSH(options.SSHPort); err != nil {
		return pairingSession{}, errors.New(sshOffMessage(env.Setup.GOOS, options.SSHPort))
	}
	hostKeyFile, err := deps.ReadFile(hostKeyPath)
	if err != nil {
		return pairingSession{}, fmt.Errorf("cannot read the host key %s: %v. Minis pins this Ed25519 key; generate it with `sudo ssh-keygen -A`.", hostKeyPath, err)
	}
	hostKey, err := pairing.HostKeyLine(string(hostKeyFile))
	if err != nil {
		return pairingSession{}, fmt.Errorf("%s: %v", hostKeyPath, err)
	}
	ips, err := deps.Addresses()
	if err != nil {
		return pairingSession{}, fmt.Errorf("cannot list this computer's network addresses: %v", err)
	}
	addresses := pairing.OrderAddresses(ips)
	if len(addresses) == 0 {
		return pairingSession{}, errors.New("this computer has no Tailscale or private network address the phone could reach. Connect it to Tailscale or Wi-Fi, then run `minis-hostd pair` again.")
	}
	username, err := deps.Username()
	if err != nil {
		return pairingSession{}, fmt.Errorf("cannot find the current user: %v", err)
	}
	name, err := pairName(env, options.Name, deps)
	if err != nil {
		return pairingSession{}, err
	}
	secret := make([]byte, pairing.SecretSize)
	if err := deps.Random(secret); err != nil {
		return pairingSession{}, fmt.Errorf("cannot generate the pairing secret: %v", err)
	}
	listener, err := deps.Listen()
	if err != nil {
		return pairingSession{}, fmt.Errorf("cannot open the pairing port: %v", err)
	}
	payload := pairing.Payload{
		V: pairing.PayloadVersion, Name: name, User: username, Port: options.SSHPort, Addresses: addresses,
		PairPort: listener.Addr().(*net.TCPAddr).Port, HostKey: hostKey, Secret: pairing.EncodeSecret(secret),
	}
	return pairingSession{Payload: payload, Secret: secret, Listener: listener}, nil
}

// pairName prefers config.toml's host_name: push links carry that name, and Minis opens them only
// when it matches the host's name in the app.
func pairName(env Env, requested string, deps pairDeps) (string, error) {
	configPath := service.DefaultPaths(env.Setup.Home).Config
	configured, found, err := config.ReadHostName(configPath)
	if err != nil {
		return "", fmt.Errorf("%v\nFix the file, or move it aside, then run `minis-hostd pair` again.", err)
	}
	switch {
	case found && requested != "" && requested != configured:
		return "", fmt.Errorf("%s names this host %q, so its pushes open only a host named %q in Minis. Pair without --name, or change host_name first.",
			configPath, configured, configured)
	case found:
		return configured, nil
	case requested != "":
		return requested, nil
	}
	hostname, err := deps.Hostname()
	if err != nil {
		return "", fmt.Errorf("cannot read the host name: %v; pass --name", err)
	}
	return pairing.CleanName(hostname), nil
}

func sshOffMessage(goos string, port int) string {
	if goos == "darwin" {
		return fmt.Sprintf("Remote Login is off (nothing listens on port %d). Turn it on in System Settings → General → Sharing → Remote Login, then run `minis-hostd pair` again.", port)
	}
	return fmt.Sprintf("sshd is not running (nothing listens on port %d). Start it, for example `sudo systemctl enable --now ssh`, then run `minis-hostd pair` again.", port)
}

func formatMinutes(d time.Duration) string {
	switch {
	case d == time.Minute:
		return "1 minute"
	case d > time.Minute && d%time.Minute == 0:
		return fmt.Sprintf("%d minutes", int(d/time.Minute))
	}
	return d.String()
}
