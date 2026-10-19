package cli

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/daemon"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/notify"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/service"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/source/github"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/source/imap"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/store"
)

const (
	httpTimeout   = 30 * time.Second
	shutdownGrace = 10 * time.Second
)

// runDaemon is what launchd or systemd starts. It logs to stderr, which the service manager keeps.
func runDaemon(env Env, args []string) int {
	if len(args) != 0 {
		return plainFail(env, "usage: minis-hostd run")
	}
	paths := service.DefaultPaths(env.Setup.Home)
	cfg, err := config.Load(paths.Config)
	if err != nil {
		return plainFail(env, err.Error())
	}
	mail, err := mailSources(cfg.Mail)
	if err != nil {
		return plainFail(env, err.Error())
	}
	st, err := store.Open(filepath.Join(env.StateDir, databaseName), false)
	if err != nil {
		return plainFail(env, err.Error())
	}
	defer st.Close()

	client := newHTTPClient()
	deps := daemon.Deps{
		Config:        cfg,
		Store:         st,
		Notifier:      notify.NewBark(cfg.Bark, client),
		Clock:         daemon.SystemClock(),
		Mail:          mail,
		NewID:         daemon.ULIDs(time.Now),
		Logger:        slog.New(slog.NewTextHandler(env.Stderr, nil)),
		ShutdownGrace: shutdownGrace,
	}
	if cfg.GitHub != nil {
		deps.GitHub = &github.Source{Token: cfg.GitHub.Token, BaseURL: github.DefaultBaseURL, Client: client}
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := daemon.Run(ctx, deps); err != nil {
		return plainFail(env, fmt.Sprintf("stopped: %v", err))
	}
	return ExitOK
}

func newHTTPClient() *http.Client {
	return &http.Client{Timeout: httpTimeout}
}

func mailSources(accounts []config.MailAccount) ([]daemon.MailSource, error) {
	sources := make([]daemon.MailSource, 0, len(accounts))
	for _, account := range accounts {
		src, err := imap.New(account, imap.DialGmail, imap.ProductionTiming(), imap.SleepContext)
		if err != nil {
			return nil, err
		}
		sources = append(sources, src)
	}
	return sources, nil
}
