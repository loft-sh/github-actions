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
	// releases are the Linear releases the task is attached to. Nil means
	// the vCluster Platform 4.12.7 release; unattached means none.
	releases   []fakeRelease
	unattached bool
}

type fakeRelease struct {
	pipeline string
	version  string
	name     string
	stage    string
}

var platform4127 = fakeRelease{pipeline: "vCluster Platform", version: "4.12.7", stage: "started"}

func (t fakeTask) attachedReleases() []fakeRelease {
	if t.unattached {
		return nil
	}
	if t.releases == nil {
		return []fakeRelease{platform4127}
	}
	return t.releases
}

// fakeAnnounceLinear serves the announce-task search, the started-state lookup
// and the state update, and records what was asked.
type fakeAnnounceLinear struct {
	mu         sync.Mutex
	tasks      []fakeTask
	pageSize   int
	failSearch bool
	failStates bool
	// failReleases fails the lookup of a task's releases.
	failReleases bool
	// updateResult is "" for success, "error" or "unsuccessful".
	updateResult string
	searches       []map[string]any
	releaseLookups []map[string]any
	updates        []map[string]any
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
		// The ENG team's started states. Parked and Investigating sort
		// before In Progress, so only a name filter picks the right one.
		if strings.Contains(req.Query, `name: { eq: "In Progress" }`) {
			_, _ = fmt.Fprint(w, `{"data":{"workflowStates":{"nodes":[{"id":"in-progress"}]}}}`)
			return
		}
		_, _ = fmt.Fprint(w, `{"data":{"workflowStates":{"nodes":[`+
			`{"id":"parked","position":-2847.54},`+
			`{"id":"investigating","position":-1931.47},`+
			`{"id":"in-progress","position":2},`+
			`{"id":"in-review","position":3}]}}}`)
	case strings.Contains(req.Query, "issue(id:"):
		f.releaseLookups = append(f.releaseLookups, req.Variables)
		if f.failReleases {
			_, _ = fmt.Fprint(w, `{"errors":[{"message":"rate limited"}],"data":null}`)
			return
		}
		nodes := []map[string]any{}
		for _, task := range f.tasks {
			if "uuid-"+task.id != req.Variables["id"] {
				continue
			}
			for _, r := range task.attachedReleases() {
				nodes = append(nodes, map[string]any{
					"name":     r.name,
					"version":  r.version,
					"stage":    map[string]string{"type": r.stage},
					"pipeline": map[string]string{"name": r.pipeline},
				})
			}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"issue": map[string]any{"releases": map[string]any{
			"nodes":    nodes,
			"pageInfo": map[string]any{"hasNextPage": false, "endCursor": ""},
		}}}})
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
				t.Errorf("state = %v, want In Progress, not the lowest-position started state (Parked)", got)
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
		releases    []fakeRelease
		wantUpdate  bool
	}{
		{"platform checklist", "loft-enterprise", "v4.12.7", platformChecklist, nil, true},
		{"checklist without pipeline", "loft-enterprise", "v4.12.7", "v4.12.7 Post Release Activities", nil, true},
		{"checklist without v", "loft-enterprise", "v4.12.7", "vCluster Platform 4.12.7 Post Release Activities", nil, true},
		{"vcluster checklist", "vcluster-pro", "v0.30.1", "vCluster v0.30.1 Post Release Activities",
			[]fakeRelease{{pipeline: "vCluster", version: "0.30.1", stage: "started"}}, true},
		{"other pipeline", "vcluster-pro", "v4.12.7", platformChecklist, nil, false},
		{"other version", "loft-enterprise", "v4.12.7", "vCluster Platform v4.12.17 Post Release Activities", nil, false},
		{"not a checklist", "loft-enterprise", "v4.12.7", "vCluster Platform v4.12.7 Post Release Activities follow-ups", nil, false},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			fake := &fakeAnnounceLinear{tasks: []fakeTask{{id: "ENG-1", parentTitle: tc.parentTitle, stateType: "backlog", releases: tc.releases}}}
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
	fake := &fakeAnnounceLinear{tasks: []fakeTask{{id: "ENG-1", parentTitle: "vCluster v0.28.2 Post Release Activities", stateType: "backlog",
		releases: []fakeRelease{{pipeline: "vCluster", version: "0.28.2", stage: "started"}}}}}
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
		{"started state lookup fails", &fakeAnnounceLinear{failStates: true}, "Cannot find the In Progress state"},
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
	// draft answers with an unpublished release, as GitHub does for a draft.
	draft bool
}

func (f *fakeGitHub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Query string `json:"query"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	w.Header().Set("Content-Type", "application/json")
	if strings.Contains(req.Query, "release(tagName:") {
		publishedAt := `"2026-11-17T20:00:00Z"`
		if f.draft {
			publishedAt = "null"
		}
		_, _ = fmt.Fprintf(w, `{"data":{"repository":{"release":{"publishedAt":%s,"description":"","name":%q,"tagName":%q,"databaseId":1}}}}`, publishedAt, f.releaseTag, f.releaseTag)
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

func TestRunDoesNotStartTheAnnounceTaskForADraftRelease(t *testing.T) {
	linear := &fakeAnnounceLinear{tasks: []fakeTask{{id: "ENG-1", parentTitle: platformChecklist, stateType: "backlog"}}}

	_ = runAgainstFakes(t, &fakeGitHub{releaseTag: "v4.12.7", draft: true}, linear)

	if len(linear.searches) != 0 || len(linear.updates) != 0 {
		t.Errorf("searches=%d updates=%d, want no announce task lookup for a draft", len(linear.searches), len(linear.updates))
	}
}

// R8 announces the release the task is attached to, so the sync only starts
// a task attached to this pipeline's release for this version, matched the
// way R8 matches it.
func TestStartAnnounceTaskRequiresTheMatchingRelease(t *testing.T) {
	vcluster4127 := fakeRelease{pipeline: "vCluster", version: "4.12.7", stage: "started"}
	testCases := []struct {
		name        string
		parentTitle string
		releases    []fakeRelease
		unattached  bool
		wantUpdate  bool
	}{
		{"attached to this release", platformChecklist, nil, false, true},
		{"attached by name only", platformChecklist,
			[]fakeRelease{{pipeline: "vCluster Platform", name: "4.12.7", stage: "started"}}, false, true},
		{"attached to this and an unrelated release", platformChecklist,
			[]fakeRelease{{pipeline: "Docs", version: "4.12.7", stage: "started"}, platform4127}, false, true},
		{"moved to the next release", platformChecklist,
			[]fakeRelease{{pipeline: "vCluster Platform", version: "4.12.8", stage: "planned"}}, false, false},
		{"not attached", platformChecklist, nil, true, false},
		{"attached to a canceled release", platformChecklist,
			[]fakeRelease{{pipeline: "vCluster Platform", version: "4.12.7", stage: "canceled"}}, false, false},
		{"title without pipeline, other product's release", "v4.12.7 Post Release Activities",
			[]fakeRelease{vcluster4127}, false, false},
		{"title without pipeline, both products' releases", "v4.12.7 Post Release Activities",
			[]fakeRelease{vcluster4127, platform4127}, false, false},
		{"title naming the pipeline, both products' releases", platformChecklist,
			[]fakeRelease{vcluster4127, platform4127}, false, true},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			fake := &fakeAnnounceLinear{tasks: []fakeTask{{id: "ENG-1", parentTitle: tc.parentTitle, stateType: "backlog",
				releases: tc.releases, unattached: tc.unattached}}}
			client, logs := newAnnounceClient(t, fake)

			client.StartAnnounceTask(context.Background(), "loft-enterprise", "v4.12.7", false)

			if got := len(fake.updates) == 1; got != tc.wantUpdate {
				t.Fatalf("updated = %v, want %v\n%s", got, tc.wantUpdate, logs.String())
			}
			out := logs.String()
			if !tc.wantUpdate && (!strings.Contains(out, "level=WARN") ||
				!strings.Contains(out, "not attached to this release") || !strings.Contains(out, "remedy=")) {
				t.Errorf("want a not-attached warning with a remedy, got:\n%s", out)
			}
		})
	}
}

func TestStartAnnounceTaskWarnsWhenTheReleaseLookupFails(t *testing.T) {
	fake := &fakeAnnounceLinear{failReleases: true, tasks: []fakeTask{{id: "ENG-1", parentTitle: platformChecklist, stateType: "backlog"}}}
	client, logs := newAnnounceClient(t, fake)

	client.StartAnnounceTask(context.Background(), "loft-enterprise", "v4.12.7", false)

	if len(fake.updates) != 0 {
		t.Errorf("updates = %d, want 0", len(fake.updates))
	}
	out := logs.String()
	if !strings.Contains(out, "level=WARN") || !strings.Contains(out, "Cannot read the releases of the announce task") ||
		!strings.Contains(out, "remedy=") {
		t.Errorf("want a release-lookup warning with a remedy, got:\n%s", out)
	}
}
