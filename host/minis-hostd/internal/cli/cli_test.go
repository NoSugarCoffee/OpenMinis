package cli

import (
	"bytes"
	"testing"
)

func run(args ...string) (status int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	status = Run(Env{Version: "1.2.3", Stdout: &out, Stderr: &errOut}, args)
	return status, out.String(), errOut.String()
}

func TestVersionPrintsOneJSONLine(t *testing.T) {
	status, stdout, stderr := run("version", "--json")
	if status != ExitOK || stdout != `{"schemaVersion":1,"version":"1.2.3"}`+"\n" || stderr != "" {
		t.Fatalf("status %d stdout %q stderr %q", status, stdout, stderr)
	}
}

func TestUnknownCommandIsBadRequest(t *testing.T) {
	status, stdout, stderr := run("frobnicate", "--json")
	want := `{"schemaVersion":1,"error":{"code":"bad_request","message":"unknown command \"frobnicate --json\""}}` + "\n"
	if status != ExitError || stdout != want {
		t.Fatalf("status %d stdout %q", status, stdout)
	}
	if stderr != "minis-hostd: unknown command \"frobnicate --json\"\n" {
		t.Errorf("stderr %q", stderr)
	}
}

func TestNoCommandIsBadRequest(t *testing.T) {
	if status, _, _ := run(); status != ExitError {
		t.Fatalf("status %d", status)
	}
}
