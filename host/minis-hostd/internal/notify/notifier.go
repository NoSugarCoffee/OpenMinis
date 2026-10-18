// Package notify delivers notices to the user's phone.
package notify

import (
	"context"
	"errors"
)

type Notice struct {
	Title string
	Body  string
	URL   string // the minis:// link opened on tap; empty for none
}

type Notifier interface {
	Send(ctx context.Context, n Notice) error
}

// ErrMaybeDelivered marks a failure after the request reached the wire. Retrying it could push the
// same notice twice, so callers must not retry it.
var ErrMaybeDelivered = errors.New("notifier: request may have been delivered")
