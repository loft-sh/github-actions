package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/shurcooL/graphql"
)

type fakeTask struct {
	id          string
	parentTitle string
	noParent    bool
	stateType   string
}

// fakeAnnounceLinear serves the announce-task search, the started-state lookup
// and the state update, and records what was asked.
type fakeAnnounceLinear struct {
	mu         sync.Mutex
	tasks      []fakeTask
	pageSize   int
	failSearch bool
	failStates bool
	// updateResult is "" for success, "error" or "unsuccessful".
	updateResult string
	searches     []map[string]any
	updates      []map[string]any
}

func (f *fakeAnnounceLinear) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Query     string         `json:"query"`
		Variables map[string]any `json:"variables"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")

	switch {
	case strings.Contains(req.Query, "issueUpdate"):
		f.updates = append(f.updates, req.Variables)
		switch f.updateResult {
		case "error":
			_, _ = fmt.Fprint(w, `{"errors":[{"message":"Entity not found: Issue"}],"data":null}`)
		case "unsuccessful":
			_, _ = fmt.Fprint(w, `{"data":{"issueUpdate":{"success":false}}}`)
		default:
			_, _ = fmt.Fprint(w, `{"data":{"issueUpdate":{"success":true}}}`)
		}
	case strings.Contains(req.Query, "workflowStates"):
		if f.failStates {
			_, _ = fmt.Fprint(w, `{"errors":[{"message":"rate limited"}],"data":null}`)
			return
		}
		_, _ = fmt.Fprint(w, `{"data":{"workflowStates":{"nodes":[`+
			`{"id":"in-review","position":3},`+
			`{"id":"in-progress","position":2}]}}}`)
	case strings.Contains(req.Query, "issues("):
		f.searches = append(f.searches, req.Variables)
		if f.failSearch {
			_, _ = fmt.Fprint(w, `{"errors":[{"message":"rate limited"}],"data":null}`)
			return
		}
		start := 0
		if after, ok := req.Variables["after"].(string); ok {
			_, _ = fmt.Sscanf(after, "%d", &start)
		}
		end := len(f.tasks)
		if f.pageSize > 0 && start+f.pageSize < end {
			end = start + f.pageSize
		}
		nodes := []map[string]any{}
		for _, task := range f.tasks[start:end] {
			var parent any = map[string]string{"title": task.parentTitle}
			if task.noParent {
				parent = nil
			}
			nodes = append(nodes, map[string]any{
				"id":         "uuid-" + task.id,
				"identifier": task.id,
				"state":      map[string]string{"type": task.stateType},
				"team":       map[string]string{"id": "team-eng"},
				"parent":     parent,
			})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"issues": map[string]any{
			"nodes":    nodes,
			"pageInfo": map[string]any{"hasNextPage": end < len(f.tasks), "endCursor": fmt.Sprint(end)},
		}}})
	default:
		http.Error(w, "unexpected query: "+req.Query, http.StatusBadRequest)
	}
}

func newAnnounceClient(t *testing.T, fake *fakeAnnounceLinear) (*LinearClient, *bytes.Buffer) {
	t.Helper()
	server := httptest.NewServer(fake)
	t.Cleanup(server.Close)
	var logs bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logs, nil))
	return &LinearClient{client: graphql.NewClient(server.URL, server.Client()), logger: logger}, &logs
}

const platformChecklist = "vCluster Platform v4.12.7 Post Release Activities"

func TestStartAnnounceTaskMovesTheUnstartedTask(t *testing.T) {
	for _, stateType := range []string{"backlog", "unstarted", "triage"} {
		t.Run(stateType, func(t *testing.T) {
			fake := &fakeAnnounceLinear{tasks: []fakeTask{{id: "ENG-1", parentTitle: platformChecklist, stateType: stateType}}}
			client, _ := newAnnounceClient(t, fake)

			client.StartAnnounceTask(context.Background(), "loft-enterprise", "v4.12.7", false)

			if len(fake.updates) != 1 {
				t.Fatalf("updates = %d, want 1", len(fake.updates))
			}
			if got := fake.updates[0]["issueID"]; got != "uuid-ENG-1" {
				t.Errorf("updated issue = %v, want uuid-ENG-1", got)
			}
			if got := fake.updates[0]["stateID"]; got != "in-progress" {
				t.Errorf("state = %v, want the lowest-position started state in-progress", got)
			}
			if got := fake.searches[0]["checklist"]; got != "4.12.7 Post Release Activities" {
				t.Errorf("checklist search = %v", got)
			}
		})
	}
}

func TestStartAnnounceTaskLeavesStartedOrClosedTasks(t *testing.T) {
	for _, stateType := range []string{"started", "completed", "canceled"} {
		t.Run(stateType, func(t *testing.T) {
			fake := &fakeAnnounceLinear{tasks: []fakeTask{{id: "ENG-1", parentTitle: platformChecklist, stateType: stateType}}}
			client, _ := newAnnounceClient(t, fake)

			client.StartAnnounceTask(context.Background(), "loft-enterprise", "v4.12.7", false)

			if len(fake.updates) != 0 {
				t.Errorf("updates = %d, want 0", len(fake.updates))
			}
		})
	}
}

func TestStartAnnounceTaskMatchesTheChecklistOfThisPipeline(t *testing.T) {
	testCases := []struct {
		name        string
		repo        string
		tag         string
		parentTitle string
		wantUpdate  bool
	}{
		{"platform checklist", "loft-enterprise", "v4.12.7", platformChecklist, true},
		{"checklist without pipeline", "loft-enterprise", "v4.12.7", "v4.12.7 Post Release Activities", true},
		{"checklist without v", "loft-enterprise", "v4.12.7", "vCluster Platform 4.12.7 Post Release Activities", true},
		{"vcluster checklist", "vcluster-pro", "v0.30.1", "vCluster v0.30.1 Post Release Activities", true},
		{"other pipeline", "vcluster-pro", "v4.12.7", platformChecklist, false},
		{"other version", "loft-enterprise", "v4.12.7", "vCluster Platform v4.12.17 Post Release Activities", false},
		{"not a checklist", "loft-enterprise", "v4.12.7", "vCluster Platform v4.12.7 Post Release Activities follow-ups", false},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			fake := &fakeAnnounceLinear{tasks: []fakeTask{{id: "ENG-1", parentTitle: tc.parentTitle, stateType: "backlog"}}}
			client, _ := newAnnounceClient(t, fake)

			client.StartAnnounceTask(context.Background(), tc.repo, tc.tag, false)

			if got := len(fake.updates) == 1; got != tc.wantUpdate {
				t.Errorf("updated = %v, want %v", got, tc.wantUpdate)
			}
		})
	}
}

func TestStartAnnounceTaskSkipsWithoutLookingUp(t *testing.T) {
	testCases := []struct {
		name string
		repo string
		tag  string
	}{
		{"release candidate", "loft-enterprise", "v4.12.7-rc.1"},
		{"alpha", "loft-enterprise", "v4.13.0-alpha.2"},
		{"next", "loft-enterprise", "v4.12.7-next.1"},
		{"minor release", "loft-enterprise", "v4.13.0"},
		{"repo without a pipeline", "vcluster-docs", "v4.12.7"},
		{"not a version", "loft-enterprise", "nightly"},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			fake := &fakeAnnounceLinear{tasks: []fakeTask{{id: "ENG-1", parentTitle: platformChecklist, stateType: "backlog"}}}
			client, _ := newAnnounceClient(t, fake)

			client.StartAnnounceTask(context.Background(), tc.repo, tc.tag, false)

			if len(fake.searches) != 0 || len(fake.updates) != 0 {
				t.Errorf("searches=%d updates=%d, want none", len(fake.searches), len(fake.updates))
			}
		})
	}
}

func TestStartAnnounceTaskUsesTheVersionOfAPatchBuild(t *testing.T) {
	fake := &fakeAnnounceLinear{tasks: []fakeTask{{id: "ENG-1", parentTitle: "vCluster v0.28.2 Post Release Activities", stateType: "backlog"}}}
	client, _ := newAnnounceClient(t, fake)

	client.StartAnnounceTask(context.Background(), "vcluster-pro", "v0.28.2-patch.1", false)

	if len(fake.updates) != 1 {
		t.Errorf("updates = %d, want 1", len(fake.updates))
	}
}

func TestStartAnnounceTaskDryRunMakesNoChange(t *testing.T) {
	fake := &fakeAnnounceLinear{tasks: []fakeTask{{id: "ENG-1", parentTitle: platformChecklist, stateType: "backlog"}}}
	client, logs := newAnnounceClient(t, fake)

	client.StartAnnounceTask(context.Background(), "loft-enterprise", "v4.12.7", true)

	if len(fake.searches) != 1 {
		t.Errorf("searches = %d, want 1", len(fake.searches))
	}
	if len(fake.updates) != 0 {
		t.Errorf("updates = %d, want 0", len(fake.updates))
	}
	if !strings.Contains(logs.String(), "Would start the announce task") {
		t.Errorf("dry run did not log the move:\n%s", logs.String())
	}
}

func TestStartAnnounceTaskWarnsWhenNothingIsFound(t *testing.T) {
	testCases := []struct {
		name string
		fake *fakeAnnounceLinear
		want string
	}{
		{"no task", &fakeAnnounceLinear{}, "No announce task found"},
		{"search fails", &fakeAnnounceLinear{failSearch: true}, "Cannot search for the announce task"},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			client, logs := newAnnounceClient(t, tc.fake)

			client.StartAnnounceTask(context.Background(), "loft-enterprise", "v4.12.7", false)

			if len(tc.fake.updates) != 0 {
				t.Errorf("updates = %d, want 0", len(tc.fake.updates))
			}
			out := logs.String()
			if !strings.Contains(out, "level=WARN") || !strings.Contains(out, tc.want) {
				t.Errorf("want a warning containing %q, got:\n%s", tc.want, out)
			}
			if !strings.Contains(out, "remedy=") {
				t.Errorf("warning does not name the remedy:\n%s", out)
			}
		})
	}
}

func TestStartAnnounceTaskReadsEveryPage(t *testing.T) {
	fake := &fakeAnnounceLinear{pageSize: 1, tasks: []fakeTask{
		{id: "ENG-1", parentTitle: "vCluster Platform v4.11.7 Post Release Activities", stateType: "backlog"},
		{id: "ENG-2", parentTitle: platformChecklist, stateType: "backlog"},
	}}
	client, _ := newAnnounceClient(t, fake)

	client.StartAnnounceTask(context.Background(), "loft-enterprise", "v4.12.7", false)

	if len(fake.searches) != 2 {
		t.Errorf("searches = %d, want 2 pages", len(fake.searches))
	}
	if len(fake.updates) != 1 || fake.updates[0]["issueID"] != "uuid-ENG-2" {
		t.Errorf("updates = %v, want only uuid-ENG-2", fake.updates)
	}
}

func TestStartAnnounceTaskWarnsWhenTheMoveFails(t *testing.T) {
	testCases := []struct {
		name string
		fake *fakeAnnounceLinear
		want string
	}{
		{"started state lookup fails", &fakeAnnounceLinear{failStates: true}, "Cannot find a started state"},
		{"update fails", &fakeAnnounceLinear{updateResult: "error"}, "Cannot start the announce task"},
		{"update unsuccessful", &fakeAnnounceLinear{updateResult: "unsuccessful"}, "Cannot start the announce task"},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			tc.fake.tasks = []fakeTask{{id: "ENG-1", parentTitle: platformChecklist, stateType: "backlog"}}
			client, logs := newAnnounceClient(t, tc.fake)

			client.StartAnnounceTask(context.Background(), "loft-enterprise", "v4.12.7", false)

			out := logs.String()
			if !strings.Contains(out, "level=WARN") || !strings.Contains(out, tc.want) || !strings.Contains(out, "remedy=") {
				t.Errorf("want a warning containing %q and a remedy, got:\n%s", tc.want, out)
			}
			if strings.Contains(out, "Started the announce task") {
				t.Errorf("logged a start that did not happen:\n%s", out)
			}
		})
	}
}

func TestStartAnnounceTaskIgnoresATaskWithoutAParent(t *testing.T) {
	fake := &fakeAnnounceLinear{tasks: []fakeTask{{id: "ENG-1", noParent: true, stateType: "backlog"}}}
	client, logs := newAnnounceClient(t, fake)

	client.StartAnnounceTask(context.Background(), "loft-enterprise", "v4.12.7", false)

	if len(fake.updates) != 0 {
		t.Errorf("updates = %d, want 0", len(fake.updates))
	}
	if !strings.Contains(logs.String(), "No announce task found") {
		t.Errorf("want the no-task warning, got:\n%s", logs.String())
	}
}

// fakeGitHub answers the release-by-tag query with releaseTag and fails every
// other query, so the sync stops right after it has confirmed the release.
type fakeGitHub struct {
	releaseTag string
}

func (f *fakeGitHub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Query string `json:"query"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	w.Header().Set("Content-Type", "application/json")
	if strings.Contains(req.Query, "release(tagName:") {
		_, _ = fmt.Fprintf(w, `{"data":{"repository":{"release":{"publishedAt":"2026-11-17T20:00:00Z","description":"","name":%q,"tagName":%q,"databaseId":1}}}}`, f.releaseTag, f.releaseTag)
		return
	}
	_, _ = fmt.Fprint(w, `{"errors":[{"message":"API rate limit exceeded"}],"data":null}`)
}

func runAgainstFakes(t *testing.T, gh *fakeGitHub, linear *fakeAnnounceLinear) error {
	t.Helper()
	ghServer := httptest.NewServer(gh)
	t.Cleanup(ghServer.Close)
	linearServer := httptest.NewServer(linear)
	t.Cleanup(linearServer.Close)

	prevGitHub, prevLinear := githubGraphQLURL, linearGraphQLURL
	githubGraphQLURL, linearGraphQLURL = ghServer.URL, linearServer.URL
	t.Cleanup(func() { githubGraphQLURL, linearGraphQLURL = prevGitHub, prevLinear })

	return run(context.Background(), &bytes.Buffer{}, []string{"linear-release-sync",
		"-token", "gh-token", "-linear-token", "linear-token",
		"-repo", "loft-enterprise", "-release-tag", "v4.12.7"})
}

func TestRunStartsTheAnnounceTaskWhenTheSyncFailsEarly(t *testing.T) {
	linear := &fakeAnnounceLinear{tasks: []fakeTask{{id: "ENG-1", parentTitle: platformChecklist, stateType: "backlog"}}}

	err := runAgainstFakes(t, &fakeGitHub{releaseTag: "v4.12.7"}, linear)

	if err == nil {
		t.Fatal("run succeeded, want the previous-release lookup to fail")
	}
	if len(linear.updates) != 1 || linear.updates[0]["issueID"] != "uuid-ENG-1" {
		t.Errorf("updates = %v, want the announce task started", linear.updates)
	}
}

func TestRunDoesNotStartTheAnnounceTaskForAnUnknownRelease(t *testing.T) {
	linear := &fakeAnnounceLinear{tasks: []fakeTask{{id: "ENG-1", parentTitle: platformChecklist, stateType: "backlog"}}}

	err := runAgainstFakes(t, &fakeGitHub{releaseTag: "v4.12.6"}, linear)

	if err == nil {
		t.Fatal("run succeeded, want release not found")
	}
	if len(linear.searches) != 0 || len(linear.updates) != 0 {
		t.Errorf("searches=%d updates=%d, want no Linear calls", len(linear.searches), len(linear.updates))
	}
}

func TestStartAnnounceTaskStartsNothingWhenSeveralTasksMatch(t *testing.T) {
	testCases := []struct {
		name  string
		tasks []fakeTask
	}{
		{"two unstarted", []fakeTask{
			{id: "ENG-1", parentTitle: platformChecklist, stateType: "backlog"},
			{id: "ENG-2", parentTitle: "v4.12.7 Post Release Activities", stateType: "backlog"},
		}},
		{"one already announced, one unstarted", []fakeTask{
			{id: "ENG-1", parentTitle: platformChecklist, stateType: "completed"},
			{id: "ENG-2", parentTitle: platformChecklist, stateType: "backlog"},
		}},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			fake := &fakeAnnounceLinear{tasks: tc.tasks}
			client, logs := newAnnounceClient(t, fake)

			client.StartAnnounceTask(context.Background(), "loft-enterprise", "v4.12.7", false)

			if len(fake.updates) != 0 {
				t.Errorf("updates = %d, want 0", len(fake.updates))
			}
			out := logs.String()
			if !strings.Contains(out, "level=WARN") || !strings.Contains(out, "More than one announce task") ||
				!strings.Contains(out, "ENG-1") || !strings.Contains(out, "ENG-2") || !strings.Contains(out, "remedy=") {
				t.Errorf("want a warning naming both tasks and the remedy, got:\n%s", out)
			}
		})
	}
}
