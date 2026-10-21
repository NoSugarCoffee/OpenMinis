package cli

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/store"
)

var update = flag.Bool("update", false, "rewrite the golden files in testdata/contract")

const (
	goldenDir = "../../testdata/contract"
	// The golden files are shared with the app's tests, so they must not carry a temp path.
	goldenStateDir = "/home/me/.minis/hostd"

	mailEventID    = "01JS0000000000000000000001"
	githubEventID  = "01JS0000000000000000000002"
	batchedMailID  = "01JS0000000000000000000003"
	storedOnlyID   = "01JS0000000000000000000004"
	batchID        = "01JS00000000000000000000B1"
	unknownEventID = "01JS0000000000000000000099"
)

var (
	t0      = time.Date(2026, 10, 19, 9, 0, 0, 0, time.UTC)
	fixedAt = time.Date(2026, 10, 19, 10, 0, 0, 0, time.UTC)
)

const mailBody = `{"from":{"name":"Alice Chen","address":"alice@example.com"},` +
	`"to":[{"name":"","address":"me@gmail.com"}],"subject":"Re: 合同 “第三版”",` +
	`"date":"2026-10-19T08:59:12Z","messageId":"<CAF=abc123@mail.gmail.com>",` +
	`"text":"Hi,\n\nThe \"third\" draft is attached; please sign by Friday.\nCost: $HOME isn't a variable here.\n\n— Alice",` +
	`"truncated":false,"attachments":[{"name":"contract-v3.pdf","type":"application/pdf","size":182344}]}`

const githubBody = `{"repo":"NoSugarCoffee/OpenMinis","reason":"review_requested","subjectType":"PullRequest",` +
	`"subjectTitle":"feat(hostd): add the push gate","htmlUrl":"https://github.com/NoSugarCoffee/OpenMinis/pull/10",` +
	`"threadId":"14567890123","updatedAt":"2026-10-19T09:04:30Z"}`

const batchedMailBody = `{"from":{"name":"Bob Li","address":"bob@example.org"},` +
	`"to":[{"name":"","address":"me@gmail.com"}],"subject":"Lunch tomorrow?",` +
	`"date":"2026-10-19T09:05:40Z","messageId":"<20261019090540.1@example.org>",` +
	`"text":"Noodles at 12:30?","truncated":false,"attachments":[]}`

const storedOnlyBody = `{"from":{"name":"Shop","address":"news@shop.example"},` +
	`"to":[{"name":"","address":"me@gmail.com"}],"subject":"Autumn sale",` +
	`"date":"2026-10-19T09:20:00Z","messageId":"<sale-2026@shop.example>",` +
	`"text":"Everything 20% off.","truncated":true,"attachments":[]}`

func fixtureEvent(id string, source store.Source, createdAt time.Time, title, summary, body, decision, reason string) store.Event {
	return store.Event{
		ID: id, Key: string(source) + ":" + id, Source: source, CreatedAt: createdAt, Title: title,
		Summary: summary, URL: "pico://host-event/mac-mini/" + id, Body: json.RawMessage(body),
		Decision: decision, Reason: reason,
	}
}

// writeFixture builds the state a daemon would leave after a morning: a pushed mail the user
// opened, a batch of a GitHub review request and a mail, a stored-only newsletter, and two sources.
func writeFixture(t *testing.T, stateDir string) {
	t.Helper()
	s, err := store.Open(filepath.Join(stateDir, databaseName), false)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	batch := &store.BatchJoin{ID: batchID, FlushAt: t0.Add(7 * time.Minute)}
	records := []struct {
		event store.Event
		batch *store.BatchJoin
		now   time.Time
	}{
		{fixtureEvent(mailEventID, store.SourceMail, t0, "Alice Chen", "Re: 合同 “第三版”", mailBody, "push", "allowed"), nil, t0},
		{fixtureEvent(githubEventID, store.SourceGitHub, t0.Add(5*time.Minute), "NoSugarCoffee/OpenMinis",
			"Review requested: feat(hostd): add the push gate", githubBody, "push", "allowed"), batch, t0.Add(5 * time.Minute)},
		{fixtureEvent(batchedMailID, store.SourceMail, t0.Add(6*time.Minute), "Bob Li", "Lunch tomorrow?",
			batchedMailBody, "push", "allowed"), batch, t0.Add(6 * time.Minute)},
		{fixtureEvent(storedOnlyID, store.SourceMail, t0.Add(20*time.Minute), "Shop", "Autumn sale",
			storedOnlyBody, "store_only", "sender_not_allowed"), nil, t0.Add(20 * time.Minute)},
	}
	for _, r := range records {
		if _, err := s.RecordEvent(store.EventRecord{Event: r.event, Placement: store.Placement{Batch: r.batch}}, r.now); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.Ack([]string{mailEventID}, t0.Add(30*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := s.StampSource("mail:personal", "imap", true, "", t0.Add(55*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := s.StampSource("github", "github", true, "", t0.Add(10*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := s.StampSource("github", "github", false, "GitHub returned 401: Bad credentials", t0.Add(40*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := s.Beat(t0.Add(59 * time.Minute)); err != nil {
		t.Fatal(err)
	}
}

func fixtureDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	writeFixture(t, dir)
	return dir
}

func runIn(stateDir string, args ...string) (status int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	env := Env{Version: "1.2.3", Stdout: &out, Stderr: &errOut, StateDir: stateDir, Now: func() time.Time { return fixedAt }}
	status = Run(env, args)
	return status, out.String(), errOut.String()
}

func setSchemaVersion(t *testing.T, stateDir string, version int) {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+filepath.Join(stateDir, databaseName))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`UPDATE schema_version SET version = ?`, version); err != nil {
		t.Fatal(err)
	}
}

func checkGolden(t *testing.T, name, got string) {
	t.Helper()
	path := filepath.Join(goldenDir, name)
	if *update {
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run go test ./internal/cli/ -update to create it)", err)
	}
	if got != string(want) {
		t.Errorf("stdout differs from %s\n got: %s\nwant: %s", name, got, want)
	}
}

func TestOutputsMatchGoldenFiles(t *testing.T) {
	cases := []struct {
		golden string
		setup  func(t *testing.T) string
		args   []string
		status int
	}{
		{"events_list.json", fixtureDir, []string{"events", "list", "--limit", "50", "--json"}, ExitOK},
		{"events_get_mail.json", fixtureDir, []string{"events", "get", mailEventID, "--json"}, ExitOK},
		{"events_get_github.json", fixtureDir, []string{"events", "get", githubEventID, "--json"}, ExitOK},
		{"batches_get.json", fixtureDir, []string{"batches", "get", batchID, "--json"}, ExitOK},
		{"events_ack.json", fixtureDir, []string{"events", "ack", storedOnlyID, batchedMailID, "--json"}, ExitOK},
		{"status.json", fixtureDir, []string{"status", "--json"}, ExitOK},
		{"error_not_found.json", fixtureDir, []string{"events", "get", unknownEventID, "--json"}, ExitError},
		{"error_bad_request.json", fixtureDir, []string{"events", "list", "--json"}, ExitError},
		{"error_store_unavailable.json", func(t *testing.T) string { return t.TempDir() }, []string{"status", "--json"}, ExitError},
		{"error_schema_mismatch.json", func(t *testing.T) string {
			dir := fixtureDir(t)
			setSchemaVersion(t, dir, 2)
			return dir
		}, []string{"status", "--json"}, ExitError},
	}
	for _, c := range cases {
		t.Run(c.golden, func(t *testing.T) {
			stateDir := c.setup(t)
			status, stdout, stderr := runIn(stateDir, c.args...)
			stdout = strings.ReplaceAll(stdout, stateDir, goldenStateDir)
			stderr = strings.ReplaceAll(stderr, stateDir, goldenStateDir)
			if status != c.status {
				t.Fatalf("status %d, want %d; stdout %q stderr %q", status, c.status, stdout, stderr)
			}
			if strings.Count(stdout, "\n") != 1 || !strings.HasSuffix(stdout, "\n") {
				t.Fatalf("stdout is not one line: %q", stdout)
			}
			checkGolden(t, c.golden, stdout)
			if c.status == ExitOK && stderr != "" {
				t.Errorf("stderr %q on success", stderr)
			}
			if c.status == ExitError {
				var decoded errorOutput
				if err := json.Unmarshal([]byte(stdout), &decoded); err != nil {
					t.Fatal(err)
				}
				if stderr != "minis-hostd: "+decoded.Error.Message+"\n" {
					t.Errorf("stderr %q does not carry the message %q", stderr, decoded.Error.Message)
				}
			}
		})
	}
}

func TestReadCommandsLeaveTheDatabaseUnchanged(t *testing.T) {
	stateDir := fixtureDir(t)
	path := filepath.Join(stateDir, databaseName)
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	commands := [][]string{
		{"events", "list", "--limit", "200", "--json"},
		{"events", "get", mailEventID, "--json"},
		{"batches", "get", batchID, "--json"},
		{"status", "--json"},
	}
	for _, args := range commands {
		if status, stdout, _ := runIn(stateDir, args...); status != ExitOK {
			t.Fatalf("%v: status %d stdout %q", args, status, stdout)
		}
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Error("a read command changed state.db")
	}
	if wal, err := os.Stat(path + "-wal"); err == nil && wal.Size() > 0 {
		t.Errorf("a read command wrote %d bytes of WAL", wal.Size())
	}
}

func TestReadCommandsOpenTheStoreReadOnly(t *testing.T) {
	stateDir := fixtureDir(t)
	path := filepath.Join(stateDir, databaseName)
	if err := os.Chmod(path, 0o444); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(path, 0o644) })
	if status, stdout, _ := runIn(stateDir, "status", "--json"); status != ExitOK {
		t.Fatalf("status %d stdout %q", status, stdout)
	}
	if status, stdout, _ := runIn(stateDir, "events", "ack", storedOnlyID, "--json"); status != ExitError ||
		!strings.Contains(stdout, string(CodeStoreUnavailable)) {
		t.Fatalf("ack on a read-only file: status %d stdout %q", status, stdout)
	}
}

func TestAckMarksEveryEvent(t *testing.T) {
	stateDir := fixtureDir(t)
	if status, stdout, _ := runIn(stateDir, "events", "ack", storedOnlyID, batchedMailID, "--json"); status != ExitOK {
		t.Fatalf("status %d stdout %q", status, stdout)
	}
	s := openFixture(t, stateDir)
	for _, id := range []string{storedOnlyID, batchedMailID} {
		e, err := s.GetEvent(id)
		if err != nil || e.AckedAt == nil || !e.AckedAt.Equal(fixedAt) {
			t.Errorf("%s acked at %v err %v", id, e.AckedAt, err)
		}
	}
}

func TestAckOfAnUnknownIDAcksNothing(t *testing.T) {
	stateDir := fixtureDir(t)
	status, stdout, _ := runIn(stateDir, "events", "ack", storedOnlyID, unknownEventID, "--json")
	want := `{"schemaVersion":1,"error":{"code":"not_found","message":"No event ` + unknownEventID + `."}}` + "\n"
	if status != ExitError || stdout != want {
		t.Fatalf("status %d stdout %q", status, stdout)
	}
	e, err := openFixture(t, stateDir).GetEvent(storedOnlyID)
	if err != nil || e.AckedAt != nil {
		t.Errorf("acked at %v err %v", e.AckedAt, err)
	}
}

func TestMissingDatabaseIsNotCreated(t *testing.T) {
	stateDir := t.TempDir()
	for _, args := range [][]string{
		{"events", "list", "--limit", "1", "--json"},
		{"events", "get", mailEventID, "--json"},
		{"batches", "get", batchID, "--json"},
		{"events", "ack", mailEventID, "--json"},
	} {
		status, stdout, _ := runIn(stateDir, args...)
		if status != ExitError || !strings.Contains(stdout, `"code":"store_unavailable"`) {
			t.Errorf("%v: status %d stdout %q", args, status, stdout)
		}
	}
	if _, err := os.Stat(filepath.Join(stateDir, databaseName)); !os.IsNotExist(err) {
		t.Errorf("state.db exists after the commands: %v", err)
	}
}

func TestListPagesWithBefore(t *testing.T) {
	stateDir := fixtureDir(t)
	var ids []string
	before := ""
	for page := 0; page < 3; page++ {
		args := []string{"events", "list", "--limit", "2", "--json"}
		if before != "" {
			args = append(args, "--before", before)
		}
		status, stdout, _ := runIn(stateDir, args...)
		if status != ExitOK {
			t.Fatalf("status %d stdout %q", status, stdout)
		}
		var decoded eventsListOutput
		if err := json.Unmarshal([]byte(stdout), &decoded); err != nil {
			t.Fatal(err)
		}
		for _, e := range decoded.Events {
			ids = append(ids, e.ID)
		}
		if len(decoded.Events) == 0 {
			break
		}
		before = decoded.Events[len(decoded.Events)-1].ID
	}
	want := []string{storedOnlyID, batchedMailID, githubEventID, mailEventID}
	if strings.Join(ids, ",") != strings.Join(want, ",") {
		t.Errorf("paged ids %v, want %v", ids, want)
	}
}

func TestEmptyStoreListsAnEmptyArray(t *testing.T) {
	stateDir := t.TempDir()
	s, err := store.Open(filepath.Join(stateDir, databaseName), false)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	if _, stdout, _ := runIn(stateDir, "events", "list", "--limit", "5", "--json"); stdout != `{"schemaVersion":1,"events":[]}`+"\n" {
		t.Errorf("list %q", stdout)
	}
	want := `{"schemaVersion":1,"version":"1.2.3","heartbeatAt":null,"sources":[]}` + "\n"
	if _, stdout, _ := runIn(stateDir, "status", "--json"); stdout != want {
		t.Errorf("status %q", stdout)
	}
}

func TestUsageErrorsAreBadRequests(t *testing.T) {
	stateDir := fixtureDir(t)
	for _, args := range [][]string{
		{"events"},
		{"events", "delete", mailEventID, "--json"},
		{"events", "list", "--limit", "0", "--json"},
		{"events", "list", "--limit", "201", "--json"},
		{"events", "list", "--limit", "ten", "--json"},
		{"events", "list", "--limit", "5"},
		{"events", "list", "--limit", "5", "--limit", "6", "--json"},
		{"events", "list", "--limit", "5", "--before", "--json"},
		{"events", "list", "--limit", "5", "extra", "--json"},
		{"events", "get", "--json"},
		{"events", "get", mailEventID, githubEventID, "--json"},
		{"events", "get", mailEventID},
		{"events", "get", mailEventID, "--verbose", "--json"},
		{"events", "ack", "--json"},
		{"batches", "get", "--json"},
		{"batches", "list", "--json"},
		{"status"},
		{"status", "extra", "--json"},
	} {
		status, stdout, _ := runIn(stateDir, args...)
		if status != ExitError || !strings.Contains(stdout, `"code":"bad_request"`) {
			t.Errorf("%v: status %d stdout %q", args, status, stdout)
		}
	}
}

func TestUnknownBatchIsNotFound(t *testing.T) {
	status, stdout, _ := runIn(fixtureDir(t), "batches", "get", unknownEventID, "--json")
	want := `{"schemaVersion":1,"error":{"code":"not_found","message":"No batch ` + unknownEventID + `."}}` + "\n"
	if status != ExitError || stdout != want {
		t.Fatalf("status %d stdout %q", status, stdout)
	}
}

func openFixture(t *testing.T, stateDir string) *store.Store {
	t.Helper()
	s, err := store.Open(filepath.Join(stateDir, databaseName), true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}
