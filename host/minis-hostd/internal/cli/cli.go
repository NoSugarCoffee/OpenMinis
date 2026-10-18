// Package cli implements the minis-hostd commands. Every output is one JSON line: the app parses
// it over SSH (spec §8), so nothing else may reach stdout.
package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/store"
)

const SchemaVersion = 1

// Exit statuses the app maps (spec §9.4); 127 comes from the shell when the binary is missing.
const (
	ExitOK    = 0
	ExitError = 2
)

type ErrorCode string

const (
	CodeNotFound         ErrorCode = "not_found"
	CodeBadRequest       ErrorCode = "bad_request"
	CodeStoreUnavailable ErrorCode = "store_unavailable"
	CodeSchemaMismatch   ErrorCode = "schema_mismatch"
)

const databaseName = "state.db"

type Env struct {
	Version  string
	Stdout   io.Writer
	Stderr   io.Writer
	StateDir string
	Now      func() time.Time
	Setup    Setup
}

type versionOutput struct {
	SchemaVersion int    `json:"schemaVersion"`
	Version       string `json:"version"`
}

type errorBody struct {
	Code    ErrorCode `json:"code"`
	Message string    `json:"message"`
}

type errorOutput struct {
	SchemaVersion int       `json:"schemaVersion"`
	Error         errorBody `json:"error"`
}

// commandError is a failure whose code and wording the command has already decided.
type commandError struct {
	Code    ErrorCode
	Message string
}

func (e *commandError) Error() string { return e.Message }

func badRequest(usage string) error {
	return &commandError{Code: CodeBadRequest, Message: "usage: " + usage}
}

// Run dispatches args (without the program name) and returns the exit status.
func Run(env Env, args []string) int {
	if len(args) == 0 {
		return fail(env, CodeBadRequest, "no command given; try `minis-hostd version --json`")
	}
	switch args[0] {
	case "version":
		if len(args) != 2 || args[1] != "--json" {
			return fail(env, CodeBadRequest, "usage: minis-hostd version --json")
		}
		return emit(env, versionOutput{SchemaVersion: SchemaVersion, Version: env.Version})
	case "events":
		return runEvents(env, args[1:])
	case "batches":
		return runBatches(env, args[1:])
	case "status":
		return runStatus(env, args[1:])
	case "new-config":
		return runNewConfig(env, args[1:])
	case "install-service":
		return runInstallService(env, args[1:])
	case "uninstall-service":
		return runUninstallService(env, args[1:])
	default:
		return fail(env, CodeBadRequest, fmt.Sprintf("unknown command %q", strings.Join(args, " ")))
	}
}

func emit(env Env, value any) int {
	var line strings.Builder
	encoder := json.NewEncoder(&line)
	// Event bodies hold addresses like <alice@example.com>; escaping them only makes stdout harder
	// for a person to read, and the app's decoder accepts both forms.
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		fmt.Fprintf(env.Stderr, "minis-hostd: encoding output: %v\n", err)
		return ExitError
	}
	io.WriteString(env.Stdout, line.String())
	return ExitOK
}

// fail writes the error object for the app and the same message on stderr for a person.
func fail(env Env, code ErrorCode, message string) int {
	fmt.Fprintf(env.Stderr, "minis-hostd: %s\n", message)
	emit(env, errorOutput{SchemaVersion: SchemaVersion, Error: errorBody{Code: code, Message: message}})
	return ExitError
}

func failWith(env Env, err error) int {
	var cmdErr *commandError
	switch {
	case errors.As(err, &cmdErr):
		return fail(env, cmdErr.Code, cmdErr.Message)
	case errors.Is(err, store.ErrSchemaVersion):
		return fail(env, CodeSchemaMismatch, fmt.Sprintf(
			"minis-hostd cannot read its database: %s. Update minis-hostd.", strings.TrimPrefix(err.Error(), "store: ")))
	default:
		return fail(env, CodeStoreUnavailable, fmt.Sprintf("minis-hostd cannot read its database: %v", err))
	}
}

// notFound names the missing ids so the app can tell the user which event was pruned.
func notFound(kind string, err error) error {
	var missing *store.NotFoundError
	if !errors.As(err, &missing) {
		return err
	}
	return &commandError{Code: CodeNotFound, Message: fmt.Sprintf("No %s %s.", kind, strings.Join(missing.IDs, ", "))}
}

// openStore refuses to create the database: only the daemon does that, and a missing one means it
// never ran here, which the app reports differently from an empty history.
func openStore(env Env, readOnly bool) (*store.Store, error) {
	path := filepath.Join(env.StateDir, databaseName)
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return nil, &commandError{
			Code:    CodeStoreUnavailable,
			Message: fmt.Sprintf("minis-hostd has not run on this host yet (no %s).", path),
		}
	} else if err != nil {
		return nil, &commandError{Code: CodeStoreUnavailable, Message: fmt.Sprintf("cannot open %s: %v", path, err)}
	}
	s, err := store.Open(path, readOnly)
	if errors.Is(err, store.ErrSchemaVersion) {
		return nil, err
	}
	if err != nil {
		return nil, &commandError{Code: CodeStoreUnavailable, Message: fmt.Sprintf("cannot open %s: %v", path, err)}
	}
	return s, nil
}

type invocation struct {
	Positional []string
	Values     map[string]string
}

// parseArgs accepts flags in any position because the app appends --json after the ids. --json is
// required so a later output format can be added without changing what existing callers get.
func parseArgs(args []string, valueFlags []string, usage string) (invocation, error) {
	parsed := invocation{Values: map[string]string{}}
	sawJSON := false
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--json":
			if sawJSON {
				return invocation{}, badRequest(usage)
			}
			sawJSON = true
		case slices.Contains(valueFlags, arg):
			_, seen := parsed.Values[arg]
			if seen || i+1 == len(args) || strings.HasPrefix(args[i+1], "--") {
				return invocation{}, badRequest(usage)
			}
			parsed.Values[arg] = args[i+1]
			i++
		case strings.HasPrefix(arg, "-"):
			return invocation{}, badRequest(usage)
		default:
			parsed.Positional = append(parsed.Positional, arg)
		}
	}
	if !sawJSON {
		return invocation{}, badRequest(usage)
	}
	return parsed, nil
}

func formatTime(t time.Time) string { return t.UTC().Format(time.RFC3339) }

func formatOptionalTime(t *time.Time) *string {
	if t == nil {
		return nil
	}
	formatted := formatTime(*t)
	return &formatted
}
