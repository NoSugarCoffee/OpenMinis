package cli

import (
	"encoding/base64"
	"fmt"
	"net/http"
	"path/filepath"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/notify"
)

const usageAPNsRegister = "minis-hostd apns register <device token> --topic <bundle id> --environment development|production --json"

type apnsRegisterOutput struct {
	SchemaVersion int    `json:"schemaVersion"`
	Key           string `json:"key"`
}

func runAPNs(env Env, args []string) int {
	if len(args) == 0 || args[0] != "register" {
		return fail(env, CodeBadRequest, "usage: "+usageAPNsRegister)
	}
	return apnsRegister(env, args[1:])
}

// apnsRegister is called by the app over SSH. The key goes back on stdout, so it never appears in a
// command line on the host (apns spec §4).
func apnsRegister(env Env, args []string) int {
	parsed, err := parseArgs(args, []string{"--topic", "--environment"}, usageAPNsRegister)
	if err != nil {
		return failWith(env, err)
	}
	topic, hasTopic := parsed.Values["--topic"]
	environment, hasEnvironment := parsed.Values["--environment"]
	if len(parsed.Positional) != 1 || !hasTopic || !hasEnvironment {
		return fail(env, CodeBadRequest, "usage: "+usageAPNsRegister)
	}
	registration, err := notify.NewRegistration(parsed.Positional[0], topic, notify.Environment(environment), env.Now())
	if err != nil {
		return fail(env, CodeBadRequest, err.Error())
	}
	if err := notify.SaveRegistration(registrationPath(env), registration); err != nil {
		return fail(env, CodeStoreUnavailable, fmt.Sprintf("cannot save the registration: %v", err))
	}
	return emit(env, apnsRegisterOutput{SchemaVersion: SchemaVersion, Key: base64.StdEncoding.EncodeToString(registration.Key)})
}

func registrationPath(env Env) string {
	return filepath.Join(env.StateDir, notify.RegistrationFile)
}

// newNotifier builds the channel config.toml names; it reads the APNs key file, so a bad key fails
// here rather than on the first notice.
func newNotifier(env Env, cfg config.Config, client *http.Client) (notify.Notifier, error) {
	if cfg.APNs != nil {
		return notify.NewAPNs(*cfg.APNs, cfg.HostName, registrationPath(env), client)
	}
	return notify.NewBark(*cfg.Bark, client), nil
}
