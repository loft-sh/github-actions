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

// duplicateTaskRemedy is what a person does when several announce tasks matched.
const duplicateTaskRemedy = "cancel the duplicate checklist; if the announcement has not been posted yet, " +
	"move the remaining announce task to In Progress by hand"

// unattachedRemedy is what a person does when the task under the checklist is
// not attached to this release, so R8 would not announce this release.
const unattachedRemedy = "attach the announce task to this release in Linear, then move it to In Progress by hand"

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

	// R8 announces the release the task is attached to, not the one its
	// checklist names, so a task is only started when R8 would pick this
	// pipeline's release for this version.
	var matches []announceTask
	unattached := 0
	for _, task := range tasks {
		if !isReleaseChecklist(task.ParentTitle, pipeline, version) {
			continue
		}
		attached, err := l.taskReleases(ctx, task.ID)
		if err != nil {
			logger.Warn("Cannot read the releases of the announce task", "task", task.Identifier, "error", err, "remedy", announceRemedy)
			return
		}
		if r := announcedRelease(task.ParentTitle, attached); r != nil && r.Pipeline == pipeline && r.Version == version {
			matches = append(matches, task)
		} else {
			unattached++
			logger.Warn("Announce task is not attached to this release, not starting it",
				"task", task.Identifier, "remedy", unattachedRemedy)
		}
	}

	switch len(matches) {
	case 0:
		if unattached == 0 {
			logger.Warn("No announce task found under the release checklist", "remedy", missingTaskRemedy)
		}
	case 1:
		l.startTask(ctx, logger.With("task", matches[0].Identifier), matches[0], dryRun)
	default:
		// Starting more than one could post the announcement twice, so a
		// person picks the right task.
		identifiers := make([]string, len(matches))
		for i, task := range matches {
			identifiers[i] = task.Identifier
		}
		logger.Warn("More than one announce task found for this release, starting none",
			"tasks", strings.Join(identifiers, ","), "remedy", duplicateTaskRemedy)
	}
}

// startTask moves one announce task to its team's "In Progress" state.
func (l *LinearClient) startTask(ctx context.Context, logger *slog.Logger, task announceTask, dryRun bool) {
	if !unstartedStateTypes[task.StateType] {
		logger.Info("Announce task is already started or closed, leaving it", "stateType", task.StateType)
		return
	}
	stateID, err := l.inProgressStateID(ctx, task.TeamID)
	if err != nil {
		logger.Warn("Cannot find the In Progress state for the announce task", "error", err, "remedy", announceRemedy)
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
	return matchesChecklist(title, pipeline, version, `?`)
}

// checklistNamesPipeline is isReleaseChecklist with the pipeline required.
func checklistNamesPipeline(title, pipeline, version string) bool {
	return matchesChecklist(title, pipeline, version, ``)
}

func matchesChecklist(title, pipeline, version, pipelineQuantifier string) bool {
	if pipeline == "" || version == "" {
		return false
	}
	pattern := `(?i)^(?:` + regexp.QuoteMeta(pipeline) + `\s+)` + pipelineQuantifier + `v?` + regexp.QuoteMeta(version) + `\s+` + checklistTitleSuffix + `$`
	return regexp.MustCompile(pattern).MatchString(strings.TrimSpace(title))
}

// linearRelease is a Linear release an announce task is attached to.
type linearRelease struct {
	Pipeline  string
	Version   string // "X.Y.Z", empty when neither version nor name has one
	StageType string
}

// leadingFullVersion matches an "X.Y.Z" or "vX.Y.Z" at the start of a string.
var leadingFullVersion = regexp.MustCompile(`^v?(\d+)\.(\d+)\.(\d+)`)

// releaseVersion returns the release's "X.Y.Z" from its version, or from its
// name when the version has none, as R8 does.
func releaseVersion(version, name string) string {
	for _, s := range []string{version, name} {
		if m := leadingFullVersion.FindStringSubmatch(strings.TrimSpace(s)); m != nil {
			return m[1] + "." + m[2] + "." + m[3]
		}
	}
	return ""
}

// announcedRelease returns the release R8 announces when the task under
// parentTitle starts: the first attached, not canceled release of an
// announced pipeline whose checklist names it, else the one release the
// title matches without a pipeline. Nil when none matches, or when a title
// without a pipeline matches releases of more than one pipeline. Keep it in
// step with R8's announceTaskRelease.
func announcedRelease(parentTitle string, attached []linearRelease) *linearRelease {
	var match *linearRelease
	for i := range attached {
		r := attached[i]
		if r.StageType == "canceled" || !isAnnouncedPipeline(r.Pipeline) {
			continue
		}
		if checklistNamesPipeline(parentTitle, r.Pipeline, r.Version) {
			return &r
		}
		if isReleaseChecklist(parentTitle, r.Pipeline, r.Version) {
			if match != nil && match.Pipeline != r.Pipeline {
				return nil
			}
			match = &r
		}
	}
	return match
}

func isAnnouncedPipeline(name string) bool {
	for _, pipeline := range releasePipelineByRepo {
		if pipeline == name {
			return true
		}
	}
	return false
}

// taskReleases returns every release the issue is attached to, reading all
// pages.
func (l *LinearClient) taskReleases(ctx context.Context, issueID string) ([]linearRelease, error) {
	var releases []linearRelease
	var after *graphql.String
	for {
		var query struct {
			Issue struct {
				Releases struct {
					Nodes []struct {
						Name     string
						Version  string
						Stage    struct{ Type string }
						Pipeline struct{ Name string }
					}
					PageInfo struct {
						HasNextPage bool
						EndCursor   string
					}
				} `graphql:"releases(first: 50, after: $after)"`
			} `graphql:"issue(id: $id)"`
		}
		variables := map[string]any{"id": graphql.String(issueID), "after": after}
		if err := l.client.Query(ctx, &query, variables); err != nil {
			return nil, fmt.Errorf("query failed: %w", err)
		}
		for _, n := range query.Issue.Releases.Nodes {
			releases = append(releases, linearRelease{
				Pipeline:  n.Pipeline.Name,
				Version:   releaseVersion(n.Version, n.Name),
				StageType: n.Stage.Type,
			})
		}
		if !query.Issue.Releases.PageInfo.HasNextPage {
			return releases, nil
		}
		cursor := graphql.String(query.Issue.Releases.PageInfo.EndCursor)
		after = &cursor
	}
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

// inProgressStateID returns the team's "In Progress" state. It is looked up
// by name because the started state with the lowest position can be one that
// reads as on hold, such as "Parked" in the ENG team.
func (l *LinearClient) inProgressStateID(ctx context.Context, teamID string) (string, error) {
	var query struct {
		WorkflowStates struct {
			Nodes []struct {
				Id string
			}
		} `graphql:"workflowStates(filter: { team: { id: { eq: $teamID } }, type: { eq: \"started\" }, name: { eq: \"In Progress\" } })"`
	}
	variables := map[string]any{"teamID": graphql.ID(teamID)}
	if err := l.client.Query(ctx, &query, variables); err != nil {
		return "", fmt.Errorf("query failed: %w", err)
	}
	if len(query.WorkflowStates.Nodes) == 0 {
		return "", fmt.Errorf("team %s has no started state named In Progress", teamID)
	}
	return query.WorkflowStates.Nodes[0].Id, nil
}
