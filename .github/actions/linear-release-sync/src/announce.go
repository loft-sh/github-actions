package main

import (
	"context"
	"fmt"
	"log/slog"
	"regexp"
	"strings"

	semver "github.com/Masterminds/semver/v3"
	"github.com/shurcooL/graphql"
)

// announceTaskTitlePrefix starts the title of the post-release checklist task
// whose start makes linear-webhook-service post the customer announcement in
// #customer-engineering (rule R8). Keep it in step with R8.
const announceTaskTitlePrefix = "Announce in #customer-engineering"

// checklistTitleSuffix ends the title of the checklist the announce task sits
// under: "<pipeline> vX.Y.Z Post Release Activities".
const checklistTitleSuffix = "Post Release Activities"

// announceRemedy is what a person does when the task could not be started.
const announceRemedy = "move the announce task to In Progress by hand to post the announcement"

// missingTaskRemedy is what a person does when no announce task matched.
const missingTaskRemedy = "check that the release's \"" + checklistTitleSuffix + "\" checklist exists with an \"" +
	announceTaskTitlePrefix + "\" task, then move that task to In Progress by hand to post the announcement"

// releasePipelineByRepo maps a repository to the Linear release pipeline its
// tags ship. Repositories not listed here have no customer announcement.
var releasePipelineByRepo = map[string]string{
	"loft-enterprise": "vCluster Platform",
	"vcluster-pro":    "vCluster",
}

// unstartedStateTypes are the state types an announce task is moved out of.
// A started, completed or canceled task is left alone, so a re-run of the
// release workflow or a person who already started it posts nothing new.
var unstartedStateTypes = map[string]bool{"triage": true, "backlog": true, "unstarted": true}

// announceTask is an announce task found under some release checklist.
type announceTask struct {
	ID          string
	Identifier  string
	StateType   string
	TeamID      string
	ParentTitle string
}

// StartAnnounceTask moves the announce task of a stable patch release to a
// started state, which is what triggers the customer announcement. It never
// fails the sync: every miss is logged with the manual remedy.
func (l *LinearClient) StartAnnounceTask(ctx context.Context, repo, releaseTag string, dryRun bool) {
	logger := l.logger.With("releaseTag", releaseTag)

	if !releaseIsStable(releaseTag) {
		logger.Debug("Not starting the announce task for a prerelease")
		return
	}
	pipeline, ok := releasePipelineByRepo[repo]
	if !ok {
		logger.Debug("Not starting the announce task: the repository has no release pipeline", "repo", repo)
		return
	}
	v, err := semver.NewVersion(releaseTag)
	if err != nil {
		return
	}
	if v.Patch() == 0 {
		logger.Info("Not starting the announce task for a minor release")
		return
	}
	version := fmt.Sprintf("%d.%d.%d", v.Major(), v.Minor(), v.Patch())
	logger = logger.With("pipeline", pipeline, "version", version)

	tasks, err := l.findAnnounceTasks(ctx, version+" "+checklistTitleSuffix)
	if err != nil {
		logger.Warn("Cannot search for the announce task", "error", err, "remedy", announceRemedy)
		return
	}

	found := false
	for _, task := range tasks {
		if !isReleaseChecklist(task.ParentTitle, pipeline, version) {
			continue
		}
		found = true
		l.startTask(ctx, logger.With("task", task.Identifier), task, dryRun)
	}
	if !found {
		logger.Warn("No announce task found under the release checklist", "remedy", missingTaskRemedy)
	}
}

// startTask moves one announce task to its team's first started state.
func (l *LinearClient) startTask(ctx context.Context, logger *slog.Logger, task announceTask, dryRun bool) {
	if !unstartedStateTypes[task.StateType] {
		logger.Info("Announce task is already started or closed, leaving it", "stateType", task.StateType)
		return
	}
	stateID, err := l.firstStartedStateID(ctx, task.TeamID)
	if err != nil {
		logger.Warn("Cannot find a started state for the announce task", "error", err, "remedy", announceRemedy)
		return
	}
	if dryRun {
		logger.Info("Would start the announce task", "stateID", stateID)
		return
	}
	if err := l.updateIssueState(ctx, task.ID, stateID); err != nil {
		logger.Warn("Cannot start the announce task", "error", err, "remedy", announceRemedy)
		return
	}
	logger.Info("Started the announce task", "stateID", stateID)
}

// isReleaseChecklist reports whether title is the post-release checklist of
// this pipeline and version: "<pipeline> vX.Y.Z Post Release Activities",
// where the pipeline and the "v" are optional. The same match as R8.
func isReleaseChecklist(title, pipeline, version string) bool {
	pattern := `(?i)^(?:` + regexp.QuoteMeta(pipeline) + `\s+)?v?` + regexp.QuoteMeta(version) + `\s+` + checklistTitleSuffix + `$`
	return regexp.MustCompile(pattern).MatchString(strings.TrimSpace(title))
}

// findAnnounceTasks returns every announce task whose parent title contains
// checklist, reading all pages.
func (l *LinearClient) findAnnounceTasks(ctx context.Context, checklist string) ([]announceTask, error) {
	var tasks []announceTask
	var after *graphql.String
	for {
		var query struct {
			Issues struct {
				Nodes []struct {
					Id         string
					Identifier string
					State      struct{ Type string }
					Team       struct{ Id string }
					Parent     *struct{ Title string }
				}
				PageInfo struct {
					HasNextPage bool
					EndCursor   string
				}
			} `graphql:"issues(filter: { title: { startsWith: $prefix }, parent: { title: { containsIgnoreCase: $checklist } } }, first: 50, after: $after)"`
		}
		variables := map[string]any{
			"prefix":    graphql.String(announceTaskTitlePrefix),
			"checklist": graphql.String(checklist),
			"after":     after,
		}
		if err := l.client.Query(ctx, &query, variables); err != nil {
			return nil, fmt.Errorf("query failed: %w", err)
		}
		for _, n := range query.Issues.Nodes {
			task := announceTask{ID: n.Id, Identifier: n.Identifier, StateType: n.State.Type, TeamID: n.Team.Id}
			if n.Parent != nil {
				task.ParentTitle = n.Parent.Title
			}
			tasks = append(tasks, task)
		}
		if !query.Issues.PageInfo.HasNextPage {
			return tasks, nil
		}
		cursor := graphql.String(query.Issues.PageInfo.EndCursor)
		after = &cursor
	}
}

// firstStartedStateID returns the team's started state with the lowest
// position, normally "In Progress".
func (l *LinearClient) firstStartedStateID(ctx context.Context, teamID string) (string, error) {
	var query struct {
		WorkflowStates struct {
			Nodes []struct {
				Id       string
				Position float64
			}
		} `graphql:"workflowStates(filter: { team: { id: { eq: $teamID } }, type: { eq: \"started\" } })"`
	}
	variables := map[string]any{"teamID": graphql.ID(teamID)}
	if err := l.client.Query(ctx, &query, variables); err != nil {
		return "", fmt.Errorf("query failed: %w", err)
	}
	if len(query.WorkflowStates.Nodes) == 0 {
		return "", fmt.Errorf("team %s has no started state", teamID)
	}
	first := query.WorkflowStates.Nodes[0]
	for _, n := range query.WorkflowStates.Nodes[1:] {
		if n.Position < first.Position {
			first = n
		}
	}
	return first.Id, nil
}
