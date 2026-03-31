package main

import (
	"bytes"
	"context"
	"flag"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	pullrequests "github.com/loft-sh/github-actions/linear-release-sync/changelog/pull-requests"
	"github.com/loft-sh/github-actions/linear-release-sync/changelog/releases"
	"github.com/shurcooL/githubv4"
)

func TestStrictFilteringFlag(t *testing.T) {
	testCases := []struct {
		name          string
		args          []string
		expectedValue bool
		description   string
	}{
		{
			name:          "Default strict filtering (true)",
			args:          []string{"linear-sync", "--release-tag", "v1.0.0"},
			expectedValue: true,
			description:   "Default should be strict filtering enabled",
		},
		{
			name:          "Explicit strict filtering true",
			args:          []string{"linear-sync", "--release-tag", "v1.0.0", "--strict-filtering=true"},
			expectedValue: true,
			description:   "Explicitly setting strict filtering to true",
		},
		{
			name:          "Explicit strict filtering false",
			args:          []string{"linear-sync", "--release-tag", "v1.0.0", "--strict-filtering=false"},
			expectedValue: false,
			description:   "Explicitly setting strict filtering to false",
		},
		{
			name:          "Explicit strict filtering false with equals",
			args:          []string{"linear-sync", "--release-tag", "v1.0.0", "--strict-filtering=false"},
			expectedValue: false,
			description:   "Using equals form for boolean flag",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			// Parse flags to test the strict-filtering flag
			flagset := flag.NewFlagSet("test", flag.ContinueOnError)
			flagset.SetOutput(io.Discard) // Suppress flag parsing output

			var (
				releaseTag      = flagset.String("release-tag", "", "The tag of the new release")
				strictFiltering = flagset.Bool("strict-filtering", true, "Only include PRs that were actually merged before the release was published")
			)

			err := flagset.Parse(tc.args[1:])
			if err != nil {
				t.Fatalf("Failed to parse flags: %v", err)
			}

			if *strictFiltering != tc.expectedValue {
				t.Errorf("%s: expected strict-filtering=%v, got=%v", tc.description, tc.expectedValue, *strictFiltering)
			}

			// Verify release-tag is parsed correctly
			if *releaseTag != "v1.0.0" {
				t.Errorf("Expected release-tag to be v1.0.0, got %s", *releaseTag)
			}
		})
	}
}

func TestLinearSyncLogic_StrictFiltering(t *testing.T) {
	// This test simulates the core logic flow with strict filtering
	releaseTime := time.Date(2024, 1, 15, 12, 0, 0, 0, time.UTC)

	// Mock data
	allPRs := []pullrequests.PullRequest{
		{
			Number:   1,
			Body:     "Fix bug ENG-1234",
			Merged:   true,
			MergedAt: &githubv4.DateTime{Time: releaseTime.Add(-2 * time.Hour)}, // Before release
		},
		{
			Number:   2,
			Body:     "Add feature ENG-5678",
			Merged:   true,
			MergedAt: &githubv4.DateTime{Time: releaseTime.Add(1 * time.Hour)}, // After release
		},
		{
			Number:   3,
			Body:     "Update docs ENG-9012",
			Merged:   true,
			MergedAt: &githubv4.DateTime{Time: releaseTime.Add(-30 * time.Minute)}, // Before release
		},
	}

	currentRelease := releases.Release{
		PublishedAt: githubv4.DateTime{Time: releaseTime},
		TagName:     "v1.2.0",
	}

	testCases := []struct {
		name               string
		strictFiltering    bool
		expectedPRCount    int
		expectedIssueCount int
		description        string
	}{
		{
			name:               "With strict filtering",
			strictFiltering:    true,
			expectedPRCount:    2, // Only PRs 1 and 3 (merged before release)
			expectedIssueCount: 2, // ENG-1234 and ENG-9012
			description:        "Should filter out PRs merged after release",
		},
		{
			name:               "Without strict filtering",
			strictFiltering:    false,
			expectedPRCount:    3, // All PRs
			expectedIssueCount: 3, // All issues
			description:        "Should include all PRs between tags",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			var pullRequests []LinearPullRequest

			if tc.strictFiltering {
				// Simulate filtered PRs (would come from FetchPRsForRelease)
				filteredPRs := filterPRsByTime(allPRs, currentRelease.PublishedAt.Time)
				pullRequests = NewLinearPullRequests(filteredPRs, nil)
			} else {
				// Use all PRs (original behavior)
				pullRequests = NewLinearPullRequests(allPRs, nil)
			}

			if len(pullRequests) != tc.expectedPRCount {
				t.Errorf("%s: expected %d PRs, got %d PRs", tc.description, tc.expectedPRCount, len(pullRequests))
			}

			// Extract issue IDs
			var releasedIssues []string
			for _, pr := range pullRequests {
				if issueIDs := pr.IssueIDs(); len(issueIDs) > 0 {
					releasedIssues = append(releasedIssues, issueIDs...)
				}
			}

			if len(releasedIssues) != tc.expectedIssueCount {
				t.Errorf("%s: expected %d issues, got %d issues", tc.description, tc.expectedIssueCount, len(releasedIssues))
			}
		})
	}
}

// Helper function to simulate the filtering logic
func filterPRsByTime(prs []pullrequests.PullRequest, releaseTime time.Time) []pullrequests.PullRequest {
	var filtered []pullrequests.PullRequest
	for _, pr := range prs {
		if pr.MergedAt != nil && pr.MergedAt.After(releaseTime) {
			continue
		}
		if pr.MergedAt != nil {
			filtered = append(filtered, pr)
		}
	}
	return filtered
}

func TestRunFunction_FlagValidation(t *testing.T) {
	testCases := []struct {
		name          string
		envVars       map[string]string
		args          []string
		expectError   bool
		expectedError string
		description   string
	}{
		{
			name: "Missing GitHub token",
			envVars: map[string]string{
				"LINEAR_TOKEN": "test-linear-token",
			},
			args:          []string{"linear-sync", "--release-tag", "v1.0.0", "--repo", "vcluster"},
			expectError:   true,
			expectedError: "github token must be set",
			description:   "Should fail when GitHub token is missing",
		},
		{
			name: "Missing Linear token",
			envVars: map[string]string{
				"GITHUB_TOKEN": "test-github-token",
			},
			args:          []string{"linear-sync", "--release-tag", "v1.0.0", "--repo", "vcluster"},
			expectError:   true,
			expectedError: "linear token must be set",
			description:   "Should fail when Linear token is missing",
		},
		{
			name: "Missing release tag",
			envVars: map[string]string{
				"GITHUB_TOKEN": "test-github-token",
				"LINEAR_TOKEN": "test-linear-token",
			},
			args:          []string{"linear-sync", "--repo", "vcluster"},
			expectError:   true,
			expectedError: "release tag must be set",
			description:   "Should fail when release tag is missing",
		},
		{
			name: "Missing repo",
			envVars: map[string]string{
				"GITHUB_TOKEN": "test-github-token",
				"LINEAR_TOKEN": "test-linear-token",
			},
			args:          []string{"linear-sync", "--release-tag", "v1.0.0"},
			expectError:   true,
			expectedError: "repo must be set",
			description:   "Should fail when repo is missing",
		},
		{
			name: "All required parameters provided",
			envVars: map[string]string{
				"GITHUB_TOKEN": "test-github-token",
				"LINEAR_TOKEN": "test-linear-token",
			},
			args:        []string{"linear-sync", "--release-tag", "v1.0.0", "--repo", "vcluster"},
			expectError: false,
			description: "Should succeed when all required parameters are provided",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			// Set environment variables
			for key, value := range tc.envVars {
				os.Setenv(key, value)
				defer os.Unsetenv(key)
			}

			// Clear any existing env vars not in test case
			if _, exists := tc.envVars["GITHUB_TOKEN"]; !exists {
				os.Unsetenv("GITHUB_TOKEN")
			}
			if _, exists := tc.envVars["LINEAR_TOKEN"]; !exists {
				os.Unsetenv("LINEAR_TOKEN")
			}

			var stderr bytes.Buffer
			err := run(context.Background(), &stderr, tc.args)

			if tc.expectError {
				if err == nil {
					t.Errorf("%s: expected error but got none", tc.description)
				} else if !strings.Contains(err.Error(), tc.expectedError) {
					t.Errorf("%s: expected error containing '%s', got '%s'", tc.description, tc.expectedError, err.Error())
				}
			} else {
				if err != nil {
					// For successful cases, we expect to fail later in the process (API calls)
					// but not during initial validation
					if strings.Contains(err.Error(), "github token must be set") ||
						strings.Contains(err.Error(), "linear token must be set") ||
						strings.Contains(err.Error(), "release tag must be set") ||
						strings.Contains(err.Error(), "repo must be set") {
						t.Errorf("%s: unexpected validation error: %s", tc.description, err.Error())
					}
					// Other errors (like API failures) are expected in this test environment
				}
			}
		})
	}
}

func TestDeduplicateIssueIDs(t *testing.T) {
	testCases := []struct {
		name     string
		input    []string
		expected []string
	}{
		{
			name:     "no duplicates",
			input:    []string{"eng-1234", "eng-5678", "eng-9012"},
			expected: []string{"eng-1234", "eng-5678", "eng-9012"},
		},
		{
			name:     "with duplicates within single PR (body + branch)",
			input:    []string{"eng-8061", "eng-8061"},
			expected: []string{"eng-8061"},
		},
		{
			name:     "with duplicates across multiple PRs",
			input:    []string{"eng-1234", "eng-5678", "eng-1234", "eng-9012", "eng-5678"},
			expected: []string{"eng-1234", "eng-5678", "eng-9012"},
		},
		{
			name:     "empty list",
			input:    []string{},
			expected: []string{},
		},
		{
			name:     "all duplicates",
			input:    []string{"eng-1234", "eng-1234", "eng-1234"},
			expected: []string{"eng-1234"},
		},
		{
			name:     "preserves order",
			input:    []string{"eng-3333", "eng-1111", "eng-2222", "eng-1111"},
			expected: []string{"eng-3333", "eng-1111", "eng-2222"},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			result := deduplicateIssueIDs(tc.input)

			if len(result) != len(tc.expected) {
				t.Errorf("expected %d items, got %d", len(tc.expected), len(result))
				return
			}

			for i, v := range result {
				if v != tc.expected[i] {
					t.Errorf("at index %d: expected %q, got %q", i, tc.expected[i], v)
				}
			}
		})
	}
}

func TestIssueIDs_DuplicateAcrossBodyAndBranch(t *testing.T) {
	pr := LinearPullRequest{
		PullRequest: pullrequests.PullRequest{
			Number:      1,
			Body:        "Fixes ENG-1234",
			HeadRefName: "eng-1234/fix-bug",
		},
		validTeamKeys: nil,
	}

	ids := pr.IssueIDs()
	// Same issue appears in both body and branch — IssueIDs returns both,
	// deduplication happens later in deduplicateIssueIDs
	if len(ids) != 2 {
		t.Errorf("expected 2 raw matches (dedup happens upstream), got %d: %v", len(ids), ids)
	}

	deduped := deduplicateIssueIDs(ids)
	if len(deduped) != 1 {
		t.Errorf("expected 1 after dedup, got %d: %v", len(deduped), deduped)
	}
	if deduped[0] != "eng-1234" {
		t.Errorf("expected eng-1234, got %s", deduped[0])
	}
}

func TestParseCSV(t *testing.T) {
	testCases := []struct {
		input    string
		expected int
		contains []string
	}{
		{"", 0, nil},
		{"Engineering", 1, []string{"Engineering"}},
		{"Engineering,DevOps", 2, []string{"Engineering", "DevOps"}},
		{"Engineering, DevOps, Docs", 3, []string{"Engineering", "DevOps", "Docs"}},
		{" Engineering , ", 1, []string{"Engineering"}},
		{",,", 0, nil},
	}

	for _, tc := range testCases {
		t.Run(tc.input, func(t *testing.T) {
			result := parseCSV(tc.input)
			if len(result) != tc.expected {
				t.Errorf("parseCSV(%q): expected %d items, got %d", tc.input, tc.expected, len(result))
			}
			for _, v := range tc.contains {
				if !result.Contains(v) {
					t.Errorf("parseCSV(%q): expected to contain %q", tc.input, v)
				}
			}
		})
	}
}

func TestCaseInsensitiveSet_Contains(t *testing.T) {
	s := parseCSV("Engineering,DevOps")

	if !s.Contains("engineering") {
		t.Error("should match lowercase")
	}
	if !s.Contains("ENGINEERING") {
		t.Error("should match uppercase")
	}
	if !s.Contains("Engineering") {
		t.Error("should match mixed case")
	}
	if s.Contains("Docs") {
		t.Error("should not match absent value")
	}
}

func TestTeamAndProjectFiltering(t *testing.T) {
	issues := []struct {
		ID          string
		TeamName    string
		ProjectName string
	}{
		{"ENG-1", "Engineering", "vCluster"},
		{"ENG-2", "Engineering", "Platform"},
		{"DOC-1", "Docs", "vCluster"},
		{"DEVOPS-1", "DevOps", ""},
	}

	testCases := []struct {
		name            string
		teamFilter      string
		projectFilter   string
		expectedIssueIDs []string
	}{
		{
			name:            "no filters passes everything",
			teamFilter:      "",
			projectFilter:   "",
			expectedIssueIDs: []string{"ENG-1", "ENG-2", "DOC-1", "DEVOPS-1"},
		},
		{
			name:            "filter by single team",
			teamFilter:      "Engineering",
			projectFilter:   "",
			expectedIssueIDs: []string{"ENG-1", "ENG-2"},
		},
		{
			name:            "filter by multiple teams",
			teamFilter:      "Engineering,Docs",
			projectFilter:   "",
			expectedIssueIDs: []string{"ENG-1", "ENG-2", "DOC-1"},
		},
		{
			name:            "filter by project",
			teamFilter:      "",
			projectFilter:   "vCluster",
			expectedIssueIDs: []string{"ENG-1", "DOC-1"},
		},
		{
			name:            "filter by team and project",
			teamFilter:      "Engineering",
			projectFilter:   "Platform",
			expectedIssueIDs: []string{"ENG-2"},
		},
		{
			name:            "filter excludes all",
			teamFilter:      "NonExistentTeam",
			projectFilter:   "",
			expectedIssueIDs: []string{},
		},
		{
			name:            "empty project does not match project filter",
			teamFilter:      "",
			projectFilter:   "vCluster",
			expectedIssueIDs: []string{"ENG-1", "DOC-1"},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			teamFilter := parseCSV(tc.teamFilter)
			projectFilter := parseCSV(tc.projectFilter)

			var result []string
			for _, issue := range issues {
				if len(teamFilter) > 0 && !teamFilter.Contains(issue.TeamName) {
					continue
				}
				if len(projectFilter) > 0 && !projectFilter.Contains(issue.ProjectName) {
					continue
				}
				result = append(result, issue.ID)
			}

			if len(result) != len(tc.expectedIssueIDs) {
				t.Errorf("expected %d issues, got %d: %v", len(tc.expectedIssueIDs), len(result), result)
				return
			}

			for i, id := range result {
				if id != tc.expectedIssueIDs[i] {
					t.Errorf("at index %d: expected %q, got %q", i, tc.expectedIssueIDs[i], id)
				}
			}
		})
	}
}

func TestIssueIDs_InvalidPatterns(t *testing.T) {
	testCases := []struct {
		name        string
		body        string
		branch      string
		teamKeys    ValidTeamKeys
		expectedLen int
	}{
		{
			name:        "single char prefix rejected by regex",
			body:        "Fixes A-1",
			branch:      "main",
			teamKeys:    nil,
			expectedLen: 0, // regex requires 2+ char prefix
		},
		{
			name:        "too-long prefix matches substring",
			body:        "Fixes VERYLONGTEAMK-1",
			branch:      "main",
			teamKeys:    nil,
			expectedLen: 1, // regex matches substring YLONGTEAMK-1
		},
		{
			name:        "number too long matches substring",
			body:        "Fixes ENG-123456",
			branch:      "main",
			teamKeys:    nil,
			expectedLen: 1, // regex matches ENG-12345 (first 5 digits)
		},
		{
			name:        "valid pattern but unknown team filtered out",
			body:        "Fixes FAKE-1234",
			branch:      "main",
			teamKeys:    ValidTeamKeys{"eng": {}},
			expectedLen: 0,
		},
		{
			name:        "numeric-only prefix rejected by regex",
			body:        "Fixes 123-456",
			branch:      "main",
			teamKeys:    nil,
			expectedLen: 0, // regex requires [A-Z] prefix
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			pr := LinearPullRequest{
				PullRequest: pullrequests.PullRequest{
					Number:      1,
					Body:        tc.body,
					HeadRefName: tc.branch,
				},
				validTeamKeys: tc.teamKeys,
			}

			ids := pr.IssueIDs()
			if len(ids) != tc.expectedLen {
				t.Errorf("expected %d issue IDs, got %d: %v", tc.expectedLen, len(ids), ids)
			}
		})
	}
}

func TestExtractTeamKey_NoHyphen(t *testing.T) {
	result := extractTeamKey("nodash")
	if result != "nodash" {
		t.Errorf("expected %q, got %q", "nodash", result)
	}
}

func TestTeamKeyFiltering(t *testing.T) {
	// Test that issue IDs are filtered by valid team keys
	validKeys := ValidTeamKeys{
		"eng":    {},
		"doc":    {},
		"devops": {},
	}

	testCases := []struct {
		name           string
		prBody         string
		prBranch       string
		validTeamKeys  ValidTeamKeys
		expectedIssues []string
		description    string
	}{
		{
			name:           "Filter out invalid team keys",
			prBody:         "Fixes ENG-1234 and pr-3354",
			prBranch:       "feature/update",
			validTeamKeys:  validKeys,
			expectedIssues: []string{"eng-1234"},
			description:    "Should filter out pr-3354 as 'pr' is not a valid team key",
		},
		{
			name:           "Filter out multiple invalid patterns",
			prBody:         "Fixes snap-1, ENG-5678, and build-123",
			prBranch:       "feature/update",
			validTeamKeys:  validKeys,
			expectedIssues: []string{"eng-5678"},
			description:    "Should filter out snap-1 and build-123",
		},
		{
			name:           "Allow all valid team keys",
			prBody:         "Fixes ENG-1234, DOC-567, and DEVOPS-890",
			prBranch:       "feature/update",
			validTeamKeys:  validKeys,
			expectedIssues: []string{"eng-1234", "doc-567", "devops-890"},
			description:    "Should allow all issues with valid team keys",
		},
		{
			name:           "Case insensitive team keys",
			prBody:         "Fixes eng-1234 and ENG-5678",
			prBranch:       "DOC-999/update",
			validTeamKeys:  validKeys,
			expectedIssues: []string{"eng-1234", "eng-5678", "doc-999"},
			description:    "Should match team keys case-insensitively",
		},
		{
			name:           "No filtering when validTeamKeys is nil",
			prBody:         "Fixes pr-3354 and snap-1",
			prBranch:       "feature/update",
			validTeamKeys:  nil,
			expectedIssues: []string{"pr-3354", "snap-1"},
			description:    "Should not filter when validTeamKeys is nil",
		},
		{
			name:           "Empty validTeamKeys filters everything",
			prBody:         "Fixes ENG-1234",
			prBranch:       "feature/update",
			validTeamKeys:  ValidTeamKeys{},
			expectedIssues: []string{},
			description:    "Should filter all issues when validTeamKeys is empty",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			pr := LinearPullRequest{
				PullRequest: pullrequests.PullRequest{
					Number:      1,
					Body:        tc.prBody,
					HeadRefName: tc.prBranch,
					Merged:      true,
				},
				validTeamKeys: tc.validTeamKeys,
			}

			extractedIssues := pr.IssueIDs()

			if len(extractedIssues) != len(tc.expectedIssues) {
				t.Errorf("%s: expected %d issues, got %d issues", tc.description, len(tc.expectedIssues), len(extractedIssues))
				t.Errorf("Expected: %v, Got: %v", tc.expectedIssues, extractedIssues)
				return
			}

			// Check that all expected issues are present
			expectedMap := make(map[string]bool)
			for _, issue := range tc.expectedIssues {
				expectedMap[issue] = true
			}

			for _, issue := range extractedIssues {
				if !expectedMap[issue] {
					t.Errorf("%s: unexpected issue ID found: %s", tc.description, issue)
				}
				delete(expectedMap, issue)
			}

			for issue := range expectedMap {
				t.Errorf("%s: expected issue ID not found: %s", tc.description, issue)
			}
		})
	}
}

func TestExtractTeamKey(t *testing.T) {
	testCases := []struct {
		issueID     string
		expectedKey string
	}{
		{"eng-1234", "eng"},
		{"DOC-567", "doc"},
		{"DEVOPS-890", "devops"},
		{"pr-3354", "pr"},
		{"a-1", "a"},
		{"", ""},
	}

	for _, tc := range testCases {
		t.Run(tc.issueID, func(t *testing.T) {
			result := extractTeamKey(tc.issueID)
			if result != tc.expectedKey {
				t.Errorf("extractTeamKey(%q) = %q, want %q", tc.issueID, result, tc.expectedKey)
			}
		})
	}
}
