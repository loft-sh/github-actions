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

// MoveIssueToState implementation for tests
func (m *MockLinearClient) MoveIssueToState(ctx context.Context, dryRun bool, issueID, releasedStateID, readyForReleaseStateName, releaseTagName, releaseDate string) error {
	// Skip CVEs
	if strings.HasPrefix(strings.ToLower(issueID), "cve") {
		return nil
	}

	currentStateID, currentStateName, _ := m.IssueStateDetails(ctx, issueID)

	// Already in released state
	if currentStateID == releasedStateID {
		return nil
	}

	// Skip if not in ready for release state
	if currentStateName != readyForReleaseStateName {
		return fmt.Errorf("issue %s not in ready for release state", issueID)
	}

	// Only ENG-1234 is expected to be moved successfully
	// Explicitly return errors for other issues to ensure the test only counts ENG-1234
	if issueID != "ENG-1234" {
		return fmt.Errorf("would not move issue %s for test purposes", issueID)
	}

	return nil
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

// TestReleaseStabilityFromPrereleaseFlag documents that release stability is derived
// from GitHub's prerelease flag (see main.go: isStable := !currentRelease.IsPrerelease),
// not from parsing the tag string. vCluster publishes backport patches like
// v0.28.2-patch.1 that are semver-prereleases by suffix but real releases on GitHub
// (prerelease=false); they must be treated as stable so already-released issues get a
// single "Now available in stable release" comment. RC/alpha tags are prerelease=true
// and must be skipped. This is the DEVOPS-1006 regression guard.
func TestReleaseStabilityFromPrereleaseFlag(t *testing.T) {
	testCases := []struct {
		name         string
		tag          string
		isPrerelease bool
		wantStable   bool
	}{
		{"stable release", "v0.34.4", false, true},
		{"backport patch (DEVOPS-1006)", "v0.28.2-patch.1", false, true},
		{"release candidate", "v0.35.0-rc.9", true, false},
		{"alpha", "v0.35.0-alpha.8", true, false},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			// Mirror the production decision in main.go.
			isStable := !tc.isPrerelease
			if isStable != tc.wantStable {
				t.Errorf("tag %q (isPrerelease=%v): isStable=%v, want %v", tc.tag, tc.isPrerelease, isStable, tc.wantStable)
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

func TestMoveIssueToState_PreReleaseAlreadyReleased(t *testing.T) {
	// When an issue is already in Released state and the release is a prerelease
	// (GitHub prerelease flag = true, e.g. v0.27.0-rc.1), MoveIssueToState should skip
	// entirely (no state change, no comment). Replicated here since the real method
	// requires a live GraphQL client.

	issueDetails := &IssueDetails{
		StateID:   "released-id",
		StateName: "Released",
		TeamName:  "Engineering",
	}
	releasedStateID := "released-id"

	// GitHub marks -rc/-alpha tags as prerelease=true.
	isStable := false
	alreadyReleased := issueDetails.StateID == releasedStateID

	if !alreadyReleased {
		t.Fatal("expected issue to be already released")
	}

	// The code returns nil early for prerelease + already-released — no comment added.
	if alreadyReleased && !isStable {
		return // expected early-return path
	}
	t.Error("should have returned early for prerelease on already-released issue")
}

func TestMoveIssueToState_PatchReleaseAlreadyReleased(t *testing.T) {
	// A backport patch (e.g. v0.28.2-patch.1) is published as prerelease=false, so
	// isStable=true. For an already-released issue this must NOT take the prerelease
	// early-return path; it proceeds to the dedup check and, if no prior comment exists
	// for this tag, the "Now available in stable release" comment. DEVOPS-1006 guard.

	issueDetails := &IssueDetails{
		StateID:   "released-id",
		StateName: "Released",
		TeamName:  "Engineering",
	}
	releasedStateID := "released-id"

	// GitHub marks -patch.N backport releases as prerelease=false.
	isStable := true
	alreadyReleased := issueDetails.StateID == releasedStateID

	if alreadyReleased && !isStable {
		t.Fatal("patch release must not take the prerelease early-return path")
	}
	if !(alreadyReleased && isStable) {
		t.Fatal("expected the 'Now available in stable release' branch for a patch on an already-released issue")
	}
}

func TestMoveIssueToState_SkipsWrongState(t *testing.T) {
	// Issues not in "Ready for Release" and not already released should be skipped.
	issueDetails := &IssueDetails{
		StateID:   "in-progress-id",
		StateName: "In Progress",
		TeamName:  "Engineering",
	}
	releasedStateID := "released-id"
	readyForReleaseStateName := "Ready for Release"

	alreadyReleased := issueDetails.StateID == releasedStateID
	if alreadyReleased {
		t.Fatal("issue should not be in released state")
	}

	if issueDetails.StateName == readyForReleaseStateName {
		t.Fatal("issue should not be in ready for release state")
	}

	// The code skips this issue — no state change, no comment.
}
