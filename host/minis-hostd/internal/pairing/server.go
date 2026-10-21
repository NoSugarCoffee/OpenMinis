package pairing

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"time"
)

const (
	maxRequestBytes = 4 << 10
	// A connection that sends nothing must not hold the one-at-a-time listener for long.
	connectionTimeout = 10 * time.Second
)

type ErrorCode string

const (
	CodeBadMAC     ErrorCode = "bad_mac"
	CodeBadKey     ErrorCode = "bad_key"
	CodeBadRequest ErrorCode = "bad_request"
	// CodeHostError is sent when the key was accepted but could not be written; the reason is on
	// the host's terminal.
	CodeHostError ErrorCode = "host_error"
)

type request struct {
	V         int    `json:"v"`
	PublicKey string `json:"publicKey"`
	MAC       string `json:"mac"`
}

type Reply struct {
	OK    bool      `json:"ok"`
	Error ErrorCode `json:"error,omitempty"`
}

// Check decides one request line. A key is returned only with an OK reply.
func Check(line []byte, secret []byte) (*AuthorizedKey, Reply) {
	var req request
	if err := json.Unmarshal(line, &req); err != nil || req.V != PayloadVersion || req.PublicKey == "" || req.MAC == "" {
		return nil, Reply{Error: CodeBadRequest}
	}
	if !validMAC(secret, req.PublicKey, req.MAC) {
		return nil, Reply{Error: CodeBadMAC}
	}
	key, err := ParseAuthorizedKey(req.PublicKey)
	if err != nil {
		return nil, Reply{Error: CodeBadKey}
	}
	return &key, Reply{OK: true}
}

var (
	ErrTimedOut       = errors.New("no phone paired in time")
	ErrTooManyBadMACs = errors.New("too many pairing attempts with the wrong code")
)

// Serve answers connections one at a time until a request passes Check and install succeeds, the
// context ends, or maxBadMACs requests fail the MAC. It closes the listener before returning, so
// the code cannot be used twice.
func Serve(
	ctx context.Context, listener net.Listener, secret []byte, maxBadMACs int, install func(AuthorizedKey) error,
) (AuthorizedKey, error) {
	stop := context.AfterFunc(ctx, func() { listener.Close() })
	defer stop()
	defer listener.Close()
	badMACs := 0
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return AuthorizedKey{}, ErrTimedOut
			}
			return AuthorizedKey{}, fmt.Errorf("pairing listener failed: %w", err)
		}
		key, reply, installErr := answer(conn, secret, install)
		conn.Close()
		switch {
		case installErr != nil:
			return AuthorizedKey{}, installErr
		case reply.OK:
			return *key, nil
		case reply.Error == CodeBadMAC:
			badMACs++
			if badMACs >= maxBadMACs {
				return AuthorizedKey{}, ErrTooManyBadMACs
			}
		}
	}
}

func answer(conn net.Conn, secret []byte, install func(AuthorizedKey) error) (*AuthorizedKey, Reply, error) {
	conn.SetDeadline(time.Now().Add(connectionTimeout))
	line, err := readLine(conn)
	if err != nil {
		reply := Reply{Error: CodeBadRequest}
		writeReply(conn, reply)
		return nil, reply, nil
	}
	key, reply := Check(line, secret)
	var installErr error
	if reply.OK {
		if installErr = install(*key); installErr != nil {
			reply = Reply{Error: CodeHostError}
		}
	}
	writeReply(conn, reply)
	return key, reply, installErr
}

func readLine(conn io.Reader) ([]byte, error) {
	reader := bufio.NewReaderSize(io.LimitReader(conn, maxRequestBytes+1), maxRequestBytes+1)
	line, err := reader.ReadSlice('\n')
	if err != nil {
		return nil, err
	}
	return line[:len(line)-1], nil
}

func writeReply(conn net.Conn, reply Reply) {
	encoded, _ := json.Marshal(reply)
	conn.Write(append(encoded, '\n'))
}
