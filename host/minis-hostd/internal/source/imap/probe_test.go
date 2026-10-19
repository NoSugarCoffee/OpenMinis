package imap

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"strings"
	"testing"

	"github.com/emersion/go-imap/v2/imapclient"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/config"
)

func probeSource(t *testing.T, password string, dial Dialer) *Source {
	t.Helper()
	src, err := New(config.MailAccount{Name: "personal", Address: testAddress, AppPassword: password}, dial, quietTiming(), SleepContext)
	if err != nil {
		t.Fatal(err)
	}
	return src
}

func TestProbeLogsInAndExaminesInbox(t *testing.T) {
	server := newTestServer(t)
	server.deliver(t, textMessage("<a@example.com>", "one"))
	server.deliver(t, textMessage("<b@example.com>", "two"))

	result, err := probeSource(t, testPassword, server.dial).Probe(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.Messages != 2 {
		t.Errorf("messages %d, want 2", result.Messages)
	}
	server.assertUntouched(t)
}

func TestProbeReportsARejectedPassword(t *testing.T) {
	server := newTestServer(t)
	_, err := probeSource(t, "wrong", server.dial).Probe(context.Background())
	if !errors.Is(err, ErrLoginRejected) || !strings.Contains(err.Error(), testAddress) {
		t.Fatalf("err %v, want ErrLoginRejected naming %s", err, testAddress)
	}
	if fe := (fatalError{}); errors.As(err, &fe) {
		t.Errorf("Probe leaked the daemon's fatalError wrapper: %v", err)
	}
}

// imapserver always advertises IDLE once logged in, so a server without it is scripted by hand.
func serveWithoutIdle(t *testing.T) net.Listener {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		io.WriteString(conn, "* OK [CAPABILITY IMAP4rev1] ready\r\n")
		lines := bufio.NewScanner(conn)
		for lines.Scan() {
			tag, command, _ := strings.Cut(lines.Text(), " ")
			verb, _, _ := strings.Cut(command, " ")
			switch strings.ToUpper(verb) {
			case "LOGIN":
				io.WriteString(conn, tag+" OK logged in\r\n")
			case "CAPABILITY":
				io.WriteString(conn, "* CAPABILITY IMAP4rev1\r\n"+tag+" OK done\r\n")
			default:
				io.WriteString(conn, tag+" BAD unexpected\r\n")
			}
		}
	}()
	return ln
}

func TestProbeRequiresIdle(t *testing.T) {
	ln := serveWithoutIdle(t)
	dial := func(options *imapclient.Options) (*imapclient.Client, error) {
		return imapclient.DialInsecure(ln.Addr().String(), options)
	}
	if _, err := probeSource(t, testPassword, dial).Probe(context.Background()); !errors.Is(err, ErrIdleUnsupported) {
		t.Fatalf("err %v, want ErrIdleUnsupported", err)
	}
}

func TestProbeReportsAConnectFailure(t *testing.T) {
	dial := func(*imapclient.Options) (*imapclient.Client, error) { return nil, errors.New("no route to host") }
	if _, err := probeSource(t, testPassword, dial).Probe(context.Background()); err == nil ||
		!strings.Contains(err.Error(), "connect: no route to host") {
		t.Fatalf("err %v", err)
	}
}
