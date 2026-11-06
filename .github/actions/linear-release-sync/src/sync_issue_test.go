package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/shurcooL/graphql"
)

const fakeReleasedStateID = "released-state"

type fakeIssue struct {
	team     string
	project  string
	state    string
	stateID  string
	comments []string
}

// fakeLinear is a minimal Linear GraphQL server that records lookups and mutations.
type fakeLinear struct {
	mu            sync.Mutex
	issues        map[string]fakeIssue
	failComment   map[string]bool
	stateLookups  int
	mutatedIssues []string
}

func (f *fakeLinear) ServeHTTP(w http.ResponseWriter, r *http.Request) {
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
	case strings.Contains(req.Query, "issueUpdate"), strings.Contains(req.Query, "commentCreate"):
		id, _ := req.Variables["issueID"].(string)
		f.mutatedIssues = append(f.mutatedIssues, id)
		if strings.Contains(req.Query, "commentCreate") && f.failComment[id] {
			fmt.Fprint(w, `{"errors":[{"message":"Entity not found: Issue"}],"data":null}`)
			return
		}
		name := "issueUpdate"
		if strings.Contains(req.Query, "commentCreate") {
			name = "commentCreate"
		}
		fmt.Fprintf(w, `{"data":{"%s":{"success":true}}}`, name)
	case strings.Contains(req.Query, "workflowStates"):
		f.stateLookups++
		fmt.Fprintf(w, `{"data":{"workflowStates":{"nodes":[{"id":%q}]}}}`, fakeReleasedStateID)
	case strings.Contains(req.Query, "comments("):
		issue := f.issues[strings.TrimPrefix(req.Variables["id"].(string), "uuid-")]
		nodes := make([]map[string]string, 0, len(issue.comments))
		for _, body := range issue.comments {
			nodes = append(nodes, map[string]string{"body": body})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"issue": map[string]any{
			"comments": map[string]any{"nodes": nodes, "pageInfo": map[string]any{"hasNextPage": false, "endCursor": ""}},
		}}})
	default:
		id := req.Variables["id"].(string)
		issue, ok := f.issues[id]
		if !ok {
			fmt.Fprint(w, `{"errors":[{"message":"Entity not found: Issue"}],"data":null}`)
			return
		}
		var project any
		if issue.project != "" {
			project = map[string]string{"name": issue.project}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"issue": map[string]any{
			"id":      "uuid-" + id,
			"state":   map[string]string{"id": issue.stateID, "name": issue.state},
			"team":    map[string]string{"name": issue.team},
			"project": project,
		}}})
	}
}

func newTestSyncer(t *testing.T, fake *fakeLinear, teams, projects, releaseTag string, isStable bool) *issueSyncer {
	t.Helper()
	server := httptest.NewServer(fake)
	t.Cleanup(server.Close)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	return &issueSyncer{
		client:                   &LinearClient{client: graphql.NewClient(server.URL, server.Client()), logger: logger},
		logger:                   logger,
		teamFilter:               parseCSV(teams),
		projectFilter:            parseCSV(projects),
		teamFilterRaw:            teams,
		projectFilterRaw:         projects,
		releasedStateName:        "Released",
		readyForReleaseStateName: "Ready for Release",
		releaseTag:               releaseTag,
		releaseDate:              "2026-11-02",
		isStable:                 isStable,
	}
}

func readyIssue(team, project string) fakeIssue {
	return fakeIssue{team: team, project: project, state: "Ready for Release", stateID: "ready-state"}
}

func TestSyncIssueSkipsFilteredIssues(t *testing.T) {
	testCases := []struct {
		name     string
		teams    string
		projects string
		issue    fakeIssue
	}{
		{"team not in filter", "Engineering", "", readyIssue("Docs", "vCluster")},
		{"project not in filter", "", "vCluster", readyIssue("Engineering", "Platform")},
		{"issue without project under project filter", "", "vCluster", readyIssue("Engineering", "")},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			fake := &fakeLinear{issues: map[string]fakeIssue{"eng-1": tc.issue}}
			syncer := newTestSyncer(t, fake, tc.teams, tc.projects, "v4.9.7", true)

			if err := syncer.syncIssue(context.Background(), "eng-1"); err != nil {
				t.Fatalf("filtered issue returned error: %v", err)
			}
			if syncer.skipped != 1 || syncer.released != 0 {
				t.Errorf("skipped=%d released=%d, want skipped=1 released=0", syncer.skipped, syncer.released)
			}
			if fake.stateLookups != 0 || len(fake.mutatedIssues) != 0 {
				t.Errorf("filtered issue reached Linear: stateLookups=%d mutations=%v", fake.stateLookups, fake.mutatedIssues)
			}
		})
	}
}

func TestSyncIssueLeavesUnchangedIssuesAlone(t *testing.T) {
	testCases := []struct {
		name       string
		releaseTag string
		isStable   bool
		issue      fakeIssue
	}{
		{
			name:       "already released on a prerelease",
			releaseTag: "v4.9.7-rc.2",
			issue:      fakeIssue{team: "Engineering", state: "Released", stateID: fakeReleasedStateID},
		},
		{
			name:       "stable comment already posted for this tag",
			releaseTag: "v4.9.7",
			isStable:   true,
			issue: fakeIssue{team: "Engineering", state: "Released", stateID: fakeReleasedStateID,
				comments: []string{"Now available in stable release v4.9.7 (released 2026-11-02)"}},
		},
		{
			name:       "shipped comment already posted for this tag",
			releaseTag: "v4.9.7",
			isStable:   true,
			issue: fakeIssue{team: "Engineering", state: "In Review", stateID: "review-state",
				comments: []string{`Shipped in v4.9.7 (released 2026-11-02). This issue is not in "Ready for Release", so it was not moved to the released state.`}},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			fake := &fakeLinear{issues: map[string]fakeIssue{"eng-1": tc.issue}}
			syncer := newTestSyncer(t, fake, "", "", tc.releaseTag, tc.isStable)

			if err := syncer.syncIssue(context.Background(), "eng-1"); err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(fake.mutatedIssues) != 0 {
				t.Errorf("expected no mutations, got %v", fake.mutatedIssues)
			}
		})
	}
}

func TestSyncIssuesCountsSkipsSeparatelyFromFailures(t *testing.T) {
	fake := &fakeLinear{
		issues: map[string]fakeIssue{
			"doc-1": readyIssue("Docs", ""),
			"eng-1": readyIssue("Engineering", ""),
			"eng-2": readyIssue("Engineering", ""),
		},
		failComment: map[string]bool{"uuid-eng-1": true},
	}
	syncer := newTestSyncer(t, fake, "Engineering", "", "v4.9.7", true)

	failed, err := processIssues([]string{"doc-1", "eng-1", "eng-2"}, func(id string) error {
		return syncer.syncIssue(context.Background(), id)
	})

	if err == nil || failed != 1 {
		t.Fatalf("failed=%d err=%v, want one failure and an error", failed, err)
	}
	if syncer.skipped != 1 || syncer.released != 1 {
		t.Errorf("skipped=%d released=%d, want skipped=1 released=1", syncer.skipped, syncer.released)
	}
	for _, id := range fake.mutatedIssues {
		if id == "uuid-doc-1" {
			t.Errorf("filtered issue was mutated: %v", fake.mutatedIssues)
		}
	}
	if !strings.Contains(strings.Join(fake.mutatedIssues, ","), "uuid-eng-2") {
		t.Errorf("issue after the failure was not processed: %v", fake.mutatedIssues)
	}
	if fake.stateLookups != 1 {
		t.Errorf("released state looked up %d times, want 1 (cached per team)", fake.stateLookups)
	}
}
