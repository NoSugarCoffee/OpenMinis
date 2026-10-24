// Package notify delivers notices to the user's phone.
package notify

import (
	"context"
	"errors"
)

type Notice struct {
	Title string
	Body  string
	URL   string // the pico:// link opened on tap; empty for none
}

type Notifier interface {
	Send(ctx context.Context, n Notice) error
}

// ErrMaybeDelivered marks a failure after the request reached the wire. Retrying it could push the
// same notice twice, so callers must not retry it.
var ErrMaybeDelivered = errors.New("notifier: request may have been delivered")

// ErrPermanent marks a refusal that resending the same notice cannot fix, so callers fail it at once
// instead of retrying for the whole window.
var ErrPermanent = errors.New("notifier: permanent failure")
