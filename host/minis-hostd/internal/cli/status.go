package cli

import (
	"time"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/store"
)

const usageStatus = "minis-hostd status --json"

type SourceState string

const (
	SourceStateOK    SourceState = "ok"
	SourceStateError SourceState = "error"
)

type sourceOutput struct {
	Name      string      `json:"name"`
	Kind      string      `json:"kind"`
	State     SourceState `json:"state"`
	LastOKAt  *string     `json:"lastOkAt"`
	LastError string      `json:"lastError"`
}

type statusOutput struct {
	SchemaVersion int            `json:"schemaVersion"`
	Version       string         `json:"version"`
	HeartbeatAt   *string        `json:"heartbeatAt"`
	Sources       []sourceOutput `json:"sources"`
}

// encodeStatus takes heartbeat as nil when the daemon has never stamped one.
func encodeStatus(version string, heartbeat *time.Time, sources []store.SourceStatus) statusOutput {
	encoded := make([]sourceOutput, 0, len(sources))
	for _, src := range sources {
		state, lastError := SourceStateOK, ""
		if !src.OK {
			state, lastError = SourceStateError, src.Detail
		}
		encoded = append(encoded, sourceOutput{
			Name: src.Name, Kind: src.Kind, State: state, LastOKAt: formatOptionalTime(src.LastOKAt), LastError: lastError,
		})
	}
	return statusOutput{
		SchemaVersion: SchemaVersion, Version: version, HeartbeatAt: formatOptionalTime(heartbeat), Sources: encoded,
	}
}

func runStatus(env Env, args []string) int {
	parsed, err := parseArgs(args, nil, usageStatus)
	if err != nil {
		return failWith(env, err)
	}
	if len(parsed.Positional) != 0 {
		return failWith(env, badRequest(usageStatus))
	}
	s, err := openStore(env, true)
	if err != nil {
		return failWith(env, err)
	}
	defer s.Close()
	at, beaten, err := s.Heartbeat()
	if err != nil {
		return failWith(env, err)
	}
	var heartbeat *time.Time
	if beaten {
		heartbeat = &at
	}
	sources, err := s.Sources()
	if err != nil {
		return failWith(env, err)
	}
	return emit(env, encodeStatus(env.Version, heartbeat, sources))
}
