// Package cli implements the minis-hostd commands. Every output is one JSON line: the app parses
// it over SSH (spec §8), so nothing else may reach stdout.
package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"
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

type Env struct {
	Version string
	Stdout  io.Writer
	Stderr  io.Writer
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
	default:
		return fail(env, CodeBadRequest, fmt.Sprintf("unknown command %q", strings.Join(args, " ")))
	}
}

func emit(env Env, value any) int {
	line, err := json.Marshal(value)
	if err != nil {
		fmt.Fprintf(env.Stderr, "minis-hostd: encoding output: %v\n", err)
		return ExitError
	}
	fmt.Fprintf(env.Stdout, "%s\n", line)
	return ExitOK
}

// fail writes the error object for the app and the same message on stderr for a person.
func fail(env Env, code ErrorCode, message string) int {
	fmt.Fprintf(env.Stderr, "minis-hostd: %s\n", message)
	emit(env, errorOutput{SchemaVersion: SchemaVersion, Error: errorBody{Code: code, Message: message}})
	return ExitError
}
