package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"

	pullrequests "github.com/loft-sh/github-actions/linear-release-sync/changelog/pull-requests"
	"github.com/loft-sh/github-actions/linear-release-sync/changelog/releases"
	"github.com/shurcooL/githubv4"
	"golang.org/x/oauth2"
)

var (
	ErrMissingGitHubToken = errors.New("github token must be set")
	ErrMissingLinearToken = errors.New("linear token must be set")
	ErrMissingReleaseTag  = errors.New("release tag must be set")
	ErrMissingRepo        = errors.New("repo must be set")
)

func main() {
	if err := run(context.Background(), io.Writer(os.Stderr), os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "%s\n", err)
		os.Exit(1)
	}
}

func run(
	ctx context.Context,
	stderr io.Writer,
	args []string,
) error {
	flagset := flag.NewFlagSet(args[0], flag.ExitOnError)
	var (
		owner                    = flagset.String("owner", "loft-sh", "The GitHub owner of the repository")
		repo                     = flagset.String("repo", "", "The GitHub repository name")
		githubToken              = flagset.String("token", "", "The GitHub token to use for authentication")
		previousTag              = flagset.String("previous-tag", "", "The previous tag to generate the changelog for (if not set, the last stable release will be used)")
		releaseTag               = flagset.String("release-tag", "", "The tag of the new release")
		debug                    = flagset.Bool("debug", false, "Enable debug logging")
		linearToken              = flagset.String("linear-token", "", "The Linear token to use for authentication")
		releasedStateName        = flagset.String("released-state-name", "Released", "The name of the state to use for the released state")
		readyForReleaseStateName = flagset.String("ready-for-release-state-name", "Ready for Release", "The name of the state that indicates an issue is ready to be released")
		dryRun                   = flagset.Bool("dry-run", false, "Do not actually move issues to the released state")
		strictFiltering          = flagset.Bool("strict-filtering", true, "Only include PRs that were actually merged before the release was published (recommended to avoid false positives)")
		linearTeams              = flagset.String("linear-teams", "", "Comma-separated list of Linear team names to process (optional, default: all)")
		linearProjects           = flagset.String("linear-projects", "", "Comma-separated list of Linear project names to process (optional, default: all)")
	)
	if err := flagset.Parse(args[1:]); err != nil {
		return fmt.Errorf("parse flags: %w", err)
	}

	if *githubToken == "" {
		*githubToken = os.Getenv("GITHUB_TOKEN")
	}

	if *linearToken == "" {
		*linearToken = os.Getenv("LINEAR_TOKEN")
	}

	if *githubToken == "" {
		return ErrMissingGitHubToken
	}

	if *repo == "" {
		return ErrMissingRepo
	}

	if *releaseTag == "" {
		return ErrMissingReleaseTag
	}

	if *linearToken == "" {
		return ErrMissingLinearToken
	}

	leveler := slog.LevelVar{}
	leveler.Set(slog.LevelInfo)
	if *debug {
		leveler.Set(slog.LevelDebug)
	}

	logger := slog.New(slog.NewTextHandler(stderr, &slog.HandlerOptions{
		Level: &leveler,
	}))

	teamFilter := parseCSV(*linearTeams)
	projectFilter := parseCSV(*linearProjects)

	if len(teamFilter) > 0 {
		logger.Info("Filtering by teams", "teams", *linearTeams)
	}
	if len(projectFilter) > 0 {
		logger.Info("Filtering by projects", "projects", *linearProjects)
	}

	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()

	httpClient := oauth2.NewClient(ctx, oauth2.StaticTokenSource(
		&oauth2.Token{
			AccessToken: *githubToken,
		},
	))

	gqlClient := githubv4.NewClient(httpClient)

	var stableTag string

	if *previousTag != "" {
		release, err := releases.FetchReleaseByTag(ctx, gqlClient, *owner, *repo, *previousTag)
		if err != nil {
			return fmt.Errorf("fetch release by tag: %w", err)
		}

		stableTag = release.TagName
	} else {
		if prevRelease, err := releases.LastStableReleaseBeforeTag(ctx, gqlClient, *owner, *repo, *releaseTag); err != nil {
			return fmt.Errorf("get last stable release before tag: %w", err)
		} else if prevRelease != "" {
			stableTag = prevRelease
		} else {
			stableTag, _, err = releases.LastStableRelease(ctx, gqlClient, *owner, *repo)
			if err != nil {
				return fmt.Errorf("get last stable release: %w", err)
			}
		}
	}

	if stableTag == "" {
		return errors.New("no stable release found")
	}

	logger.Info("Last stable release", "stableTag", stableTag)

	currentRelease, err := releases.FetchReleaseByTag(ctx, gqlClient, *owner, *repo, *releaseTag)
	if err != nil {
		return fmt.Errorf("fetch release by tag: %w", err)
	}

	if currentRelease.TagName != *releaseTag {
		return fmt.Errorf("release not found: %s", *releaseTag)
	}

	prs, err := pullrequests.FetchAllPRsBetween(ctx, gqlClient, *owner, *repo, stableTag, *releaseTag)
	if err != nil {
		return fmt.Errorf("fetch all PRs until: %w", err)
	}

	// Create Linear client and fetch valid team keys early to filter false positive issue IDs
	linearClient := NewLinearClient(ctx, *linearToken, logger)
	teams, err := linearClient.ListTeams(ctx)
	if err != nil {
		return fmt.Errorf("fetch linear teams: %w", err)
	}
	validTeamKeys := make(ValidTeamKeys)
	for _, team := range teams {
		validTeamKeys[strings.ToLower(team.Key)] = struct{}{}
	}
	logger.Debug("Loaded valid team keys", "count", len(validTeamKeys), "keys", teams)

	var pullRequests []LinearPullRequest
	if *strictFiltering {
		// Filter PRs to only include those that were actually part of this release
		filteredPRs, err := pullrequests.FetchPRsForRelease(ctx, gqlClient, *owner, *repo, stableTag, *releaseTag, currentRelease.PublishedAt.Time)
		if err != nil {
			return fmt.Errorf("filter PRs for release: %w", err)
		}
		pullRequests = NewLinearPullRequests(filteredPRs, validTeamKeys)
		logger.Info("Found merged pull requests for release", "total", len(prs), "filtered", len(pullRequests), "previous", stableTag, "current", *releaseTag)
	} else {
		// Use all PRs between tags (original behavior)
		pullRequests = NewLinearPullRequests(prs, validTeamKeys)
		logger.Info("Found merged pull requests between releases", "count", len(pullRequests), "previous", stableTag, "current", *releaseTag)
	}

	releasedIssues := []string{}

	for _, pr := range pullRequests {
		if issueIDs := pr.IssueIDs(); len(issueIDs) > 0 {
			for _, issueID := range issueIDs {
				releasedIssues = append(releasedIssues, issueID)
				logger.Debug("Found issue in pull request", "issueID", issueID, "pr", pr.Number)
			}
		}
	}

	// Deduplicate issue IDs - same issue can appear in both PR body and branch name,
	// or across multiple PRs referencing the same issue
	releasedIssues = deduplicateIssueIDs(releasedIssues)

	logger.Info("Found issues in pull requests", "count", len(releasedIssues))

	// Cache of team name -> released state ID (looked up on demand)
	releasedStateIDByTeam := make(map[string]string)

	// Helper to get released state ID for a team (with caching)
	getReleasedStateID := func(teamName string) (string, error) {
		if stateID, ok := releasedStateIDByTeam[teamName]; ok {
			return stateID, nil
		}
		stateID, err := linearClient.WorkflowStateID(ctx, *releasedStateName, teamName)
		if err != nil {
			return "", err
		}
		releasedStateIDByTeam[teamName] = stateID
		logger.Debug("Found released workflow ID for team", "team", teamName, "workflowID", stateID)
		return stateID, nil
	}

	currentReleaseDateStr := currentRelease.PublishedAt.Format("2006-01-02")

	releasedCount := 0
	skippedCount := 0

	for _, issueID := range releasedIssues {
		// Get issue details including team
		issueDetails, err := linearClient.GetIssueDetails(ctx, issueID)
		if err != nil {
			logger.Error("Failed to get issue details", "issueID", issueID, "error", err)
			skippedCount++
			continue
		}

		// Filter by team if specified
		if len(teamFilter) > 0 && !teamFilter.Contains(issueDetails.TeamName) {
			logger.Debug("Skipping issue from different team", "issueID", issueID, "team", issueDetails.TeamName, "filter", *linearTeams)
			continue
		}

		// Filter by project if specified
		if len(projectFilter) > 0 && !projectFilter.Contains(issueDetails.ProjectName) {
			logger.Debug("Skipping issue from different project", "issueID", issueID, "project", issueDetails.ProjectName, "filter", *linearProjects)
			continue
		}

		// Get the released state ID for this issue's team
		releasedStateID, err := getReleasedStateID(issueDetails.TeamName)
		if err != nil {
			logger.Error("Failed to get released state for team", "issueID", issueID, "team", issueDetails.TeamName, "error", err)
			skippedCount++
			continue
		}

		if err := linearClient.MoveIssueToState(ctx, *dryRun, issueID, issueDetails, releasedStateID, *readyForReleaseStateName, currentRelease.TagName, currentReleaseDateStr); err != nil {
			logger.Error("Failed to move issue to state", "issueID", issueID, "error", err)
			skippedCount++
		} else {
			releasedCount++
		}
	}

	logger.Info("Linear sync completed", "processed", len(releasedIssues), "released", releasedCount, "skipped", skippedCount)

	return nil
}

// caseInsensitiveSet is a set of strings that supports case-insensitive lookup.
type caseInsensitiveSet map[string]struct{}

// parseCSV parses a comma-separated string into a caseInsensitiveSet.
// Returns an empty set for empty input.
func parseCSV(csv string) caseInsensitiveSet {
	s := make(caseInsensitiveSet)
	for _, item := range strings.Split(csv, ",") {
		item = strings.TrimSpace(item)
		if item != "" {
			s[strings.ToLower(item)] = struct{}{}
		}
	}
	return s
}

// Contains checks if the set contains the given value (case-insensitive).
func (s caseInsensitiveSet) Contains(value string) bool {
	_, ok := s[strings.ToLower(value)]
	return ok
}

// deduplicateIssueIDs removes duplicate issue IDs from the slice while preserving order
func deduplicateIssueIDs(issueIDs []string) []string {
	seen := make(map[string]bool)
	result := make([]string, 0, len(issueIDs))
	for _, id := range issueIDs {
		if !seen[id] {
			seen[id] = true
			result = append(result, id)
		}
	}
	return result
}
