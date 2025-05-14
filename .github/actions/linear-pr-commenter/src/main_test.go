package main

import (
	"reflect"
	"testing"

	"github.com/google/go-github/v53/github"
)

func TestExtractIssueIDs(t *testing.T) {
	tests := []struct {
		name     string
		pr       *github.PullRequest
		expected []string
	}{
		{
			name: "Extract issue ID from PR body",
			pr: &github.PullRequest{
				Body: github.String("This PR fixes ENG-1234"),
				Head: &github.PullRequestBranch{
					Ref: github.String("feature/new-feature"),
				},
			},
			expected: []string{"ENG-1234"},
		},
		{
			name: "Extract issue ID from branch name",
			pr: &github.PullRequest{
				Body: github.String("This PR adds new features"),
				Head: &github.PullRequestBranch{
					Ref: github.String("feature/ABC-5678-new-feature"),
				},
			},
			expected: []string{"ABC-5678"},
		},
		{
			name: "Extract multiple issue IDs",
			pr: &github.PullRequest{
				Body: github.String("This PR fixes ENG-1234 and DEV-5678"),
				Head: &github.PullRequestBranch{
					Ref: github.String("feature/fix-multiple"),
				},
			},
			expected: []string{"ENG-1234", "DEV-5678"},
		},
		{
			name: "No issue IDs",
			pr: &github.PullRequest{
				Body: github.String("This PR adds new features"),
				Head: &github.PullRequestBranch{
					Ref: github.String("feature/new-feature"),
				},
			},
			expected: nil, // Changed from [] to nil
		},
		{
			name: "Exclude CVE IDs",
			pr: &github.PullRequest{
				Body: github.String("This PR fixes CVE-1234"),
				Head: &github.PullRequestBranch{
					Ref: github.String("feature/security-fix"),
				},
			},
			expected: nil, // Changed from [] to nil
		},
		{
			name: "Deduplicate issue IDs",
			pr: &github.PullRequest{
				Body: github.String("This PR fixes ENG-1234 and ENG-1234"),
				Head: &github.PullRequestBranch{
					Ref: github.String("feature/ENG-1234-fix"),
				},
			},
			expected: []string{"ENG-1234"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractIssueIDs(tt.pr)
			if (tt.expected == nil && len(result) != 0) || 
			   (tt.expected != nil && !reflect.DeepEqual(result, tt.expected)) {
				t.Errorf("extractIssueIDs() = %v, want %v", result, tt.expected)
			}
		})
	}
}

func TestHasLinearComment(t *testing.T) {
	tests := []struct {
		name     string
		comments []*github.IssueComment
		issueID  string
		expected bool
	}{
		{
			name: "Comment exists",
			comments: []*github.IssueComment{
				{Body: github.String("Linear issue: [ENG-1234](https://linear.app/team/issue/ENG-1234)")},
			},
			issueID:  "ENG-1234",
			expected: true,
		},
		{
			name: "Comment doesn't exist",
			comments: []*github.IssueComment{
				{Body: github.String("Linear issue: [DEV-5678](https://linear.app/team/issue/DEV-5678)")},
			},
			issueID:  "ENG-1234",
			expected: false,
		},
		{
			name:     "No comments",
			comments: []*github.IssueComment{},
			issueID:  "ENG-1234",
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := hasLinearComment(tt.comments, tt.issueID)
			if result != tt.expected {
				t.Errorf("hasLinearComment() = %v, want %v", result, tt.expected)
			}
		})
	}
}