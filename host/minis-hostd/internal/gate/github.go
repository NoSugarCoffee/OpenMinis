package gate

import (
	"slices"
	"strings"
	"time"

	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/candidate"
	"github.com/NoSugarCoffee/OpenMinis/host/minis-hostd/internal/config"
)

// GitHub applies the same freshness limit as mail: the first poll returns every unread notification,
// months old included, and none of that backlog should push.
func GitHub(n candidate.GitHub, src config.GitHubSource, now time.Time) Decision {
	if now.Sub(n.UpdatedAt) > FreshnessLimit {
		return Decision{Action: ActionStoreOnly, Reason: ReasonTooOld}
	}
	if !slices.Contains(src.Reasons, n.Reason) {
		return Decision{Action: ActionStoreOnly, Reason: ReasonReasonNotKept}
	}
	if len(src.Repos) > 0 && !slices.ContainsFunc(src.Repos, func(filter string) bool { return repoMatches(filter, n.Repo) }) {
		return Decision{Action: ActionStoreOnly, Reason: ReasonRepoNotKept}
	}
	return Decision{Action: ActionPush, Reason: ReasonAllowed}
}

// repoMatches ignores case because GitHub owner and repository names are case-insensitive.
func repoMatches(filter string, repo string) bool {
	if owner, isWildcard := strings.CutSuffix(filter, "/*"); isWildcard {
		repoOwner, _, hasName := strings.Cut(repo, "/")
		return hasName && strings.EqualFold(owner, repoOwner)
	}
	return strings.EqualFold(filter, repo)
}
