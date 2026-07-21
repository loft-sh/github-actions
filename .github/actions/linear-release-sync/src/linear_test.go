package main

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"testing"

	pullrequests "github.com/loft-sh/github-actions/linear-release-sync/changelog/pull-requests"
)

func TestMoveIssueLogic(t *testing.T) {
	// Create mock issues with different states
	mockIssues := []struct {
		ID         string
		StateName  string
		StateID    string
		ShouldMove bool
	}{
		{ID: "ENG-1234", StateName: "Ready for Release", StateID: "ready-state-id", ShouldMove: true},
		{ID: "ENG-5678", StateName: "In Progress", StateID: "in-progress-id", ShouldMove: false},
		{ID: "ENG-9012", StateName: "Released", StateID: "released-id", ShouldMove: false},
		{ID: "CVE-1234", StateName: "Ready for Release", StateID: "ready-state-id", ShouldMove: false},
	}

	readyForReleaseStateID := "ready-state-id"
	releasedStateID := "released-id"

	for _, issue := range mockIssues {
		t.Run(issue.ID, func(t *testing.T) {
			shouldMoveIssue := false

			// Skip CVEs
			if issue.ID[:3] == "CVE" {
				shouldMoveIssue = false
			} else if issue.StateID == releasedStateID {
				// Already released
				shouldMoveIssue = false
			} else if issue.StateID == readyForReleaseStateID {
				// Ready for release
				shouldMoveIssue = true
			} else {
				// Not in correct state
				shouldMoveIssue = false
			}

			if shouldMoveIssue != issue.ShouldMove {
				t.Errorf("Issue %s: expected shouldMove=%v, got=%v", issue.ID, issue.ShouldMove, shouldMoveIssue)
			}
		})
	}
}

// MockLinearClient is a mock implementation of the LinearClient interface for testing
type MockLinearClient struct {
	mockIssueStates     map[string]string
	mockIssueStateNames map[string]string
	mockWorkflowIDs     map[string]string
}

func NewMockLinearClient() *MockLinearClient {
	return &MockLinearClient{
		mockIssueStates: map[string]string{
			"ENG-1234": "ready-state-id",
			"ENG-5678": "in-progress-id",
			"ENG-9012": "released-id",
			"CVE-1234": "ready-state-id",
		},
		mockIssueStateNames: map[string]string{
			"ENG-1234": "Ready for Release",
			"ENG-5678": "In Progress",
			"ENG-9012": "Released",
			"CVE-1234": "Ready for Release",
		},
		mockWorkflowIDs: map[string]string{
			"Ready for Release": "ready-state-id",
			"Released":          "released-id",
			"In Progress":       "in-progress-id",
		},
	}
}

func (m *MockLinearClient) WorkflowStateID(ctx context.Context, stateName, linearTeamName string) (string, error) {
	return m.mockWorkflowIDs[stateName], nil
}

func (m *MockLinearClient) IssueState(ctx context.Context, issueID string) (string, error) {
	return m.mockIssueStates[issueID], nil
}

func (m *MockLinearClient) IssueStateDetails(ctx context.Context, issueID string) (string, string, error) {
	return m.mockIssueStates[issueID], m.mockIssueStateNames[issueID], nil
}

func (m *MockLinearClient) IsIssueInState(ctx context.Context, issueID string, stateID string) (bool, error) {
	currentState, _ := m.IssueState(ctx, issueID)
	return currentState == stateID, nil
}

func (m *MockLinearClient) IsIssueInStateByName(ctx context.Context, issueID string, stateName string) (bool, error) {
	_, currentStateName, _ := m.IssueStateDetails(ctx, issueID)
	return currentStateName == stateName, nil
}

func TestIsIssueInState(t *testing.T) {
	mockClient := NewMockLinearClient()
	ctx := context.Background()

	testCases := []struct {
		IssueID        string
		StateID        string
		ExpectedResult bool
	}{
		{"ENG-1234", "ready-state-id", true},
		{"ENG-1234", "released-id", false},
		{"ENG-5678", "in-progress-id", true},
		{"ENG-9012", "released-id", true},
	}

	for _, tc := range testCases {
		t.Run(tc.IssueID+"_"+tc.StateID, func(t *testing.T) {
			result, err := mockClient.IsIssueInState(ctx, tc.IssueID, tc.StateID)
			if err != nil {
				t.Errorf("Unexpected error: %v", err)
			}
			if result != tc.ExpectedResult {
				t.Errorf("Expected IsIssueInState to return %v for issue %s and state %s, but got %v",
					tc.ExpectedResult, tc.IssueID, tc.StateID, result)
			}
		})
	}
}

func TestMoveIssueStateFiltering(t *testing.T) {
	// Create a custom mock client for this test
	mockClient := &MockLinearClient{
		mockIssueStates: map[string]string{
			"ENG-1234": "ready-state-id", // Ready for release
			"ENG-5678": "in-progress-id", // In progress
			"ENG-9012": "released-id",    // Already released
			"CVE-1234": "ready-state-id", // Ready but should be skipped as CVE
		},
		mockIssueStateNames: map[string]string{
			"ENG-1234": "Ready for Release",
			"ENG-5678": "In Progress",
			"ENG-9012": "Released",
			"CVE-1234": "Ready for Release",
		},
		mockWorkflowIDs: map[string]string{
			"Ready for Release": "ready-state-id",
			"Released":          "released-id",
			"In Progress":       "in-progress-id",
		},
	}

	ctx := context.Background()

	// Test cases for the overall filtering logic
	issueIDs := []string{"ENG-1234", "ENG-5678", "ENG-9012", "CVE-1234"}
	readyForReleaseStateName := "Ready for Release"
	releasedStateID := "released-id"

	expectedToMove := []string{"ENG-1234"}
	actualMoved := []string{}

	// Manually implement the filtering logic based on the actual conditions in LinearClient.MoveIssueToState
	for _, issueID := range issueIDs {
		// Skip CVEs
		if strings.HasPrefix(strings.ToLower(issueID), "cve") {
			continue
		}

		currentStateID, currentStateName, _ := mockClient.IssueStateDetails(ctx, issueID)

		// Skip if already in released state
		if currentStateID == releasedStateID {
			continue
		}

		// Skip if not in ready for release state
		if currentStateName != readyForReleaseStateName {
			continue
		}

		// This issue would be moved
		actualMoved = append(actualMoved, issueID)
	}

	// Verify correct issues were selected
	if len(actualMoved) != len(expectedToMove) {
		t.Errorf("Expected %d issues to move, but got %d", len(expectedToMove), len(actualMoved))
		t.Errorf("Expected: %v, Got: %v", expectedToMove, actualMoved)
	}

	// Check that each expected issue is in the actual moved set
	for _, expectedID := range expectedToMove {
		found := false
		for _, actualID := range actualMoved {
			if expectedID == actualID {
				found = true
				break
			}
		}

		if !found {
			t.Errorf("Expected issue %s to be moved, but it wasn't in the result set", expectedID)
		}
	}
}

func TestIssueIDsExtraction(t *testing.T) {
	// Save original regex and restore it after the test
	originalRegex := issuesInBodyREs
	defer func() {
		issuesInBodyREs = originalRegex
	}()

	// For testing, use a regex that matches team keys of 2-10 chars and issue numbers 1-5 digits
	issuesInBodyREs = []*regexp.Regexp{
		regexp.MustCompile(`(?P<issue>\w{2,10}-\d{1,5})`),
	}

	testCases := []struct {
		name        string
		body        string
		headRefName string
		expected    []string
	}{
		{
			name:        "No issue IDs",
			body:        "This is a regular PR",
			headRefName: "feature/new-thing",
			expected:    []string{},
		},
		{
			name:        "Issue ID in body",
			body:        "This PR fixes ENG-1234",
			headRefName: "feature/new-thing",
			expected:    []string{"eng-1234"},
		},
		{
			name:        "Issue ID in branch name",
			body:        "This is a regular PR",
			headRefName: "feature/ENG-1234-new-thing",
			expected:    []string{"eng-1234"},
		},
		{
			name:        "Multiple issue IDs",
			body:        "This PR fixes ENG-1234 and ENG-5678",
			headRefName: "feature/new-thing",
			expected:    []string{"eng-1234", "eng-5678"},
		},
		{
			name:        "Skip CVE IDs",
			body:        "This PR fixes CVE-1234",
			headRefName: "security/fix",
			expected:    []string{},
		},
		{
			name:        "Long team key (DEVOPS)",
			body:        "This PR fixes DEVOPS-471",
			headRefName: "feature/infra-update",
			expected:    []string{"devops-471"},
		},
		{
			name:        "Short team key (QA)",
			body:        "This PR fixes QA-42",
			headRefName: "feature/test-fix",
			expected:    []string{"qa-42"},
		},
		{
			name:        "Mixed team keys",
			body:        "This PR fixes ENG-1234 and DEVOPS-471",
			headRefName: "feature/QA-99-cross-team",
			expected:    []string{"eng-1234", "devops-471", "qa-99"},
		},
		{
			name:        "Issue with short number",
			body:        "This PR fixes ENG-1",
			headRefName: "feature/quick-fix",
			expected:    []string{"eng-1"},
		},
		{
			name:        "Issue with long number",
			body:        "This PR fixes ENG-12345",
			headRefName: "feature/big-project",
			expected:    []string{"eng-12345"},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			pr := LinearPullRequest{
				PullRequest: pullrequests.PullRequest{
					Body:        tc.body,
					HeadRefName: tc.headRefName,
				},
				validTeamKeys: nil, // nil disables team key filtering
			}

			result := pr.IssueIDs()

			if len(result) != len(tc.expected) {
				t.Errorf("Expected %d issues, got %d", len(tc.expected), len(result))
				t.Errorf("Expected: %v, Got: %v", tc.expected, result)
				return
			}

			// Check all expected IDs are found (ignoring order)
			for _, expectedID := range tc.expected {
				found := false
				for _, id := range result {
					if strings.EqualFold(id, expectedID) {
						found = true
						break
					}
				}
				if !found {
					t.Errorf("Expected to find issue ID %s but it was not found in %v", expectedID, result)
				}
			}
		})
	}
}

// TestReleaseIsStable drives the real production decision (releaseIsStable in main.go)
// that classifies a release from its tag name. vCluster publishes backport patches like
// v0.28.2-patch.1 that are semver-prereleases by suffix but are real releases; they must
// be treated as stable so already-released issues get a single "Now available in stable
// release" comment. -rc/-alpha/-beta/-dev/-pre/-next tags are prereleases and must be
// skipped, and a non-semver tag is not stable. Calling the production function with
// hardcoded expectations means an accidental inversion of the logic fails here. This is
// the DEVOPS-1006 regression guard.
func TestReleaseIsStable(t *testing.T) {
	testCases := []struct {
		name       string
		tag        string
		wantStable bool
	}{
		{"stable release", "v0.34.4", true},
		{"backport patch (DEVOPS-1006)", "v0.28.2-patch.1", true},
		{"release candidate", "v0.35.0-rc.9", false},
		{"alpha", "v0.35.0-alpha.8", false},
		{"beta", "v0.35.0-beta.2", false},
		{"dev", "v0.35.0-dev.1", false},
		{"pre", "v0.35.0-pre.1", false},
		{"next", "v0.35.0-next.0", false},
		{"patch-like prerelease is not a patch", "v0.35.0-patchset.1", false},
		{"non-semver tag", "latest", false},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			got := releaseIsStable(tc.tag)
			if got != tc.wantStable {
				t.Errorf("releaseIsStable(%q) = %v, want %v", tc.tag, got, tc.wantStable)
			}
		})
	}
}

func TestHasStableReleaseComment(t *testing.T) {
	testCases := []struct {
		name       string
		comments   []string
		releaseTag string
		expected   bool
	}{
		{
			name:       "no comments",
			comments:   nil,
			releaseTag: "v0.27.0",
			expected:   false,
		},
		{
			name:       "unrelated comments only",
			comments:   []string{"This issue was first released in v0.27.0-alpha.1 on 2025-01-15"},
			releaseTag: "v0.27.0",
			expected:   false,
		},
		{
			name:       "has matching stable release comment",
			comments:   []string{"Now available in stable release v0.27.0 (released 2025-02-01)"},
			releaseTag: "v0.27.0",
			expected:   true,
		},
		{
			name: "has stable release comment for different tag",
			comments: []string{
				"Now available in stable release v0.27.0 (released 2025-02-01)",
			},
			releaseTag: "v0.27.1",
			expected:   false,
		},
		{
			name: "mixed comments with matching stable release",
			comments: []string{
				"This issue was first released in v0.27.0-alpha.1 on 2025-01-15",
				"Now available in stable release v0.27.0 (released 2025-02-01)",
			},
			releaseTag: "v0.27.0",
			expected:   true,
		},
		{
			name:       "empty comments",
			comments:   []string{},
			releaseTag: "v0.27.0",
			expected:   false,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			result := hasStableReleaseComment(tc.comments, tc.releaseTag)
			if result != tc.expected {
				t.Errorf("hasStableReleaseComment(%v, %q) = %v, want %v", tc.comments, tc.releaseTag, result, tc.expected)
			}
		})
	}
}

// TestShippedCommentDedup drives the real dedup guard (hasReleaseComment in linear.go) for
// the DEVOPS-1099 "Shipped in" comment. Unlike actionMoveToReleased, the comment-only path
// leaves the issue in place, so this per-tag guard is the only thing preventing a repeat
// comment on every later sync of the same tag (and across vcluster + vcluster-pro, which cut
// identical tags against the same issue). Hardcoded expectations, so an inversion fails here.
func TestShippedCommentDedup(t *testing.T) {
	testCases := []struct {
		name       string
		comments   []string
		releaseTag string
		expected   bool
	}{
		{
			name:       "no comments",
			comments:   nil,
			releaseTag: "v0.27.0",
			expected:   false,
		},
		{
			name:       "has matching shipped comment",
			comments:   []string{"Shipped in v0.27.0 (released 2025-02-01). This issue is not in \"Ready for Release\", so it was not moved to the released state."},
			releaseTag: "v0.27.0",
			expected:   true,
		},
		{
			name:       "shipped comment for a different tag does not match",
			comments:   []string{"Shipped in v0.27.0 (released 2025-02-01)."},
			releaseTag: "v0.27.1",
			expected:   false,
		},
		{
			name:       "stable release comment is not a shipped comment",
			comments:   []string{"Now available in stable release v0.27.0 (released 2025-02-01)"},
			releaseTag: "v0.27.0",
			expected:   false,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			result := hasReleaseComment(tc.comments, shippedCommentPrefix, tc.releaseTag)
			if result != tc.expected {
				t.Errorf("hasReleaseComment(%v, %q, %q) = %v, want %v", tc.comments, shippedCommentPrefix, tc.releaseTag, result, tc.expected)
			}
		})
	}
}

func TestStableReleaseCommentText(t *testing.T) {
	// Test the comment text logic for different scenarios
	testCases := []struct {
		name             string
		alreadyReleased  bool
		isStable         bool
		releaseTag       string
		releaseDate      string
		expectedContains string
	}{
		{
			name:             "First release (pre-release)",
			alreadyReleased:  false,
			isStable:         false,
			releaseTag:       "v0.27.0-alpha.1",
			releaseDate:      "2025-01-15",
			expectedContains: "first released in",
		},
		{
			name:             "First release (stable)",
			alreadyReleased:  false,
			isStable:         true,
			releaseTag:       "v0.27.0",
			releaseDate:      "2025-02-01",
			expectedContains: "first released in",
		},
		{
			name:             "Stable release on already-released issue",
			alreadyReleased:  true,
			isStable:         true,
			releaseTag:       "v0.27.0",
			releaseDate:      "2025-02-01",
			expectedContains: "Now available in stable release",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			var releaseComment string
			if tc.alreadyReleased && tc.isStable {
				releaseComment = fmt.Sprintf("Now available in stable release %v (released %v)", tc.releaseTag, tc.releaseDate)
			} else {
				releaseComment = fmt.Sprintf("This issue was first released in %v on %v", tc.releaseTag, tc.releaseDate)
			}

			if !strings.Contains(releaseComment, tc.expectedContains) {
				t.Errorf("Comment %q does not contain expected text %q", releaseComment, tc.expectedContains)
			}
		})
	}
}

// TestDecideReleaseAction drives the real branch selection (decideReleaseAction in
// linear.go) that MoveIssueToState performs before any Linear API call. It is the
// DEVOPS-1006 regression guard: a -patch.N backport is published as prerelease=false
// (isStable=true), so an already-released issue must reach actionStableComment, not the
// prerelease skip. -rc/-alpha (isStable=false) on an already-released issue must skip.
// Because the test calls the production function, inverting the logic fails here.
func TestDecideReleaseAction(t *testing.T) {
	testCases := []struct {
		name              string
		issueID           string
		alreadyReleased   bool
		isStable          bool
		inReadyForRelease bool
		want              releaseAction
	}{
		{"cve is always skipped", "CVE-1234", false, true, true, actionSkip},
		{"cve not ready on stable release is still skipped", "CVE-9999", false, true, false, actionSkip},
		{"ready for release, stable -> move", "ENG-1", false, true, true, actionMoveToReleased},
		{"ready for release, prerelease -> move", "ENG-2", false, false, true, actionMoveToReleased},
		{"not ready, not released, stable -> comment only (DEVOPS-1099)", "ENG-3", false, true, false, actionCommentOnly},
		{"not ready, not released, prerelease -> skip (no RC spam)", "ENG-7", false, false, false, actionSkip},
		{"already released, prerelease (rc/alpha) -> skip", "ENG-4", true, false, false, actionSkip},
		{"already released, stable backport patch (DEVOPS-1006) -> stable comment", "ENG-5", true, true, false, actionStableComment},
		{"already released, stable -> stable comment", "ENG-6", true, true, true, actionStableComment},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			got := decideReleaseAction(tc.issueID, tc.alreadyReleased, tc.isStable, tc.inReadyForRelease)
			if got != tc.want {
				t.Errorf("decideReleaseAction(%q, alreadyReleased=%v, isStable=%v, inReadyForRelease=%v) = %v, want %v",
					tc.issueID, tc.alreadyReleased, tc.isStable, tc.inReadyForRelease, got, tc.want)
			}
		})
	}
}
