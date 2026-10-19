package imap

import (
	"bytes"
	"fmt"
	"io"
	"log"
	"net"
	"slices"
	"sync"
	"testing"
	"time"

	goimap "github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/emersion/go-imap/v2/imapserver"
	"github.com/emersion/go-imap/v2/imapserver/imapmemserver"
)

const (
	testAddress  = "me@gmail.com"
	testPassword = "abcd efgh ijkl mnop"
)

// guard sits between the IMAP server and the in-memory mailbox and records anything that could
// change the mailbox, so a test fails on it even if the change itself would be harmless.
type guard struct {
	mu         sync.Mutex
	violations []string
	idles      int
	searches   int
}

func (g *guard) violate(violation string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.violations = append(g.violations, violation)
}

func (g *guard) snapshot() (violations []string, idles, searches int) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return slices.Clone(g.violations), g.idles, g.searches
}

type guardedSession struct {
	imapserver.Session
	guard *guard
}

var _ imapserver.SessionMove = (*guardedSession)(nil)

func (s *guardedSession) Select(mailbox string, options *goimap.SelectOptions) (*goimap.SelectData, error) {
	if options == nil || !options.ReadOnly {
		s.guard.violate("SELECT " + mailbox + " without read-only (EXAMINE)")
	}
	return s.Session.Select(mailbox, options)
}

func (s *guardedSession) Fetch(w *imapserver.FetchWriter, numSet goimap.NumSet, options *goimap.FetchOptions) error {
	for _, section := range options.BodySection {
		if !section.Peek {
			s.guard.violate("FETCH BODY[" + string(section.Specifier) + "] without PEEK")
		}
	}
	for _, section := range options.BinarySection {
		if !section.Peek {
			s.guard.violate("FETCH BINARY[] without PEEK")
		}
	}
	return s.Session.Fetch(w, numSet, options)
}

func (s *guardedSession) Store(*imapserver.FetchWriter, goimap.NumSet, *goimap.StoreFlags, *goimap.StoreOptions) error {
	s.guard.violate("STORE")
	return fmt.Errorf("test server refuses STORE")
}

func (s *guardedSession) Copy(goimap.NumSet, string) (*goimap.CopyData, error) {
	s.guard.violate("COPY")
	return nil, fmt.Errorf("test server refuses COPY")
}

func (s *guardedSession) Move(*imapserver.MoveWriter, goimap.NumSet, string) error {
	s.guard.violate("MOVE")
	return fmt.Errorf("test server refuses MOVE")
}

func (s *guardedSession) Expunge(*imapserver.ExpungeWriter, *goimap.UIDSet) error {
	s.guard.violate("EXPUNGE")
	return fmt.Errorf("test server refuses EXPUNGE")
}

func (s *guardedSession) Idle(w *imapserver.UpdateWriter, stop <-chan struct{}) error {
	s.guard.mu.Lock()
	s.guard.idles++
	s.guard.mu.Unlock()
	return s.Session.Idle(w, stop)
}

func (s *guardedSession) Search(kind imapserver.NumKind, criteria *goimap.SearchCriteria, options *goimap.SearchOptions) (*goimap.SearchData, error) {
	s.guard.mu.Lock()
	s.guard.searches++
	s.guard.mu.Unlock()
	return s.Session.Search(kind, criteria, options)
}

// trackingListener remembers accepted connections so a test can cut them all.
type trackingListener struct {
	net.Listener
	mu    sync.Mutex
	conns []net.Conn
}

func (l *trackingListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err == nil {
		l.mu.Lock()
		l.conns = append(l.conns, conn)
		l.mu.Unlock()
	}
	return conn, err
}

func (l *trackingListener) dropAll() {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, conn := range l.conns {
		conn.Close()
	}
	l.conns = nil
}

type testServer struct {
	user     *imapmemserver.User
	guard    *guard
	listener *trackingListener
}

func newTestServer(t *testing.T) *testServer {
	t.Helper()
	memServer := imapmemserver.New()
	user := imapmemserver.NewUser(testAddress, testPassword)
	if err := user.Create(mailbox, nil); err != nil {
		t.Fatal(err)
	}
	memServer.AddUser(user)
	g := &guard{}
	server := imapserver.New(&imapserver.Options{
		NewSession: func(*imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			return &guardedSession{Session: memServer.NewSession(), guard: g}, nil, nil
		},
		InsecureAuth: true,
		Caps:         goimap.CapSet{goimap.CapIMAP4rev1: {}, goimap.CapIdle: {}, goimap.CapMove: {}, goimap.CapUIDPlus: {}},
		Logger:       log.New(io.Discard, "", 0),
	})
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	listener := &trackingListener{Listener: ln}
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	return &testServer{user: user, guard: g, listener: listener}
}

func (s *testServer) dial(options *imapclient.Options) (*imapclient.Client, error) {
	return imapclient.DialInsecure(s.listener.Addr().String(), options)
}

func (s *testServer) deliver(t *testing.T, raw []byte) uint32 {
	t.Helper()
	appended, err := s.user.Append(mailbox, bytes.NewReader(raw), &goimap.AppendOptions{Time: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	return uint32(appended.UID)
}

// recreateInbox is how a test gets Gmail to change UIDVALIDITY.
func (s *testServer) recreateInbox(t *testing.T) {
	t.Helper()
	if err := s.user.Delete(mailbox); err != nil {
		t.Fatal(err)
	}
	if err := s.user.Create(mailbox, nil); err != nil {
		t.Fatal(err)
	}
}

func (s *testServer) uidValidity(t *testing.T) uint32 {
	t.Helper()
	status, err := s.user.Status(mailbox, &goimap.StatusOptions{UIDValidity: true})
	if err != nil {
		t.Fatal(err)
	}
	return status.UIDValidity
}

func (s *testServer) assertUntouched(t *testing.T) {
	t.Helper()
	if violations, _, _ := s.guard.snapshot(); len(violations) > 0 {
		t.Errorf("the source tried to change the mailbox: %q", violations)
	}
}

func textMessage(messageID, subject string) []byte {
	return crlf([]byte(fmt.Sprintf("From: Alice Example <alice@example.com>\nTo: me@gmail.com\n"+
		"Subject: %s\nMessage-ID: %s\nDate: Mon, 19 Oct 2026 18:14:00 +0200\n"+
		"Content-Type: text/plain; charset=UTF-8\n\nHello from %s\n", subject, messageID, subject)))
}
