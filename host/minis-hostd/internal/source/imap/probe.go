package imap

import (
	"context"
	"errors"
	"fmt"

	goimap "github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
)

// ErrIdleUnsupported means the server cannot push new mail, which the source depends on.
var ErrIdleUnsupported = errors.New("the server does not support IDLE")

type ProbeResult struct {
	Messages uint32
}

// Probe runs the start of a watch (connect, login, IDLE capability, EXAMINE INBOX) and logs out, so
// `doctor` exercises the same code path as the daemon without recording anything.
func (s *Source) Probe(ctx context.Context) (ProbeResult, error) {
	client, err := s.dial(&imapclient.Options{})
	if err != nil {
		return ProbeResult{}, fmt.Errorf("connect: %w", err)
	}
	defer client.Close()
	defer context.AfterFunc(ctx, func() { client.Close() })()

	if err := login(client, s.account); err != nil {
		return ProbeResult{}, unwrapFatal(err)
	}
	// Servers may advertise fewer capabilities before login than after, so ask again now.
	caps, err := client.Capability().Wait()
	if err != nil {
		return ProbeResult{}, fmt.Errorf("capability: %w", err)
	}
	if !caps.Has(goimap.CapIdle) {
		return ProbeResult{}, ErrIdleUnsupported
	}
	selected, err := client.Select(mailbox, &goimap.SelectOptions{ReadOnly: true}).Wait()
	if err != nil {
		return ProbeResult{}, fmt.Errorf("examine %s: %w", mailbox, err)
	}
	if err := client.Logout().Wait(); err != nil {
		return ProbeResult{}, fmt.Errorf("logout: %w", err)
	}
	return ProbeResult{Messages: selected.NumMessages}, nil
}

func unwrapFatal(err error) error {
	if fe := (fatalError{}); errors.As(err, &fe) {
		return fe.err
	}
	return err
}
