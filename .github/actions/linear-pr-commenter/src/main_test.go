package main

import (
	"reflect"
	"testing"

	"github.com/google/go-github/v53/github"
)

func TestExtractIssueIDs(t *testing.T) {
	// Mock Linear teams
	mockTeams := []linearTeam{
		{ID: "team1", Name: "Engineering", Key: "ENG"},
		{ID: "team2", Name: "Operations", Key: "OPS"},
		{ID: "team3", Name: "Documentation", Key: "DOC"},
		{ID: "team4", Name: "Quality Assurance", Key: "QA"},
	}

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
					Ref: github.String("feature/OPS-5678-new-feature"),
				},
			},
			expected: []string{"OPS-5678"},
		},
		{
			name: "Extract multiple issue IDs",
			pr: &github.PullRequest{
				Body: github.String("This PR fixes ENG-1234 and DOC-5678"),
				Head: &github.PullRequestBranch{
					Ref: github.String("feature/fix-multiple"),
				},
			},
			expected: []string{"ENG-1234", "DOC-5678"},
		},
		{
			name: "No issue IDs",
			pr: &github.PullRequest{
				Body: github.String("This PR adds new features"),
				Head: &github.PullRequestBranch{
					Ref: github.String("feature/new-feature"),
				},
			},
			expected: nil,
		},
		{
			name: "Exclude CVE IDs",
			pr: &github.PullRequest{
				Body: github.String("This PR fixes CVE-1234"),
				Head: &github.PullRequestBranch{
					Ref: github.String("feature/security-fix"),
				},
			},
			expected: nil,
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
		{
			name: "Case insensitive matching",
			pr: &github.PullRequest{
				Body: github.String("This PR fixes eng-1234"),
				Head: &github.PullRequestBranch{
					Ref: github.String("feature/new-feature"),
				},
			},
			expected: []string{"ENG-1234"},
		},
		{
			name: "Short team keys (2 letters)",
			pr: &github.PullRequest{
				Body: github.String("This PR fixes QA-42"),
				Head: &github.PullRequestBranch{
					Ref: github.String("feature/qa-fix"),
				},
			},
			expected: []string{"QA-42"},
		},
		{
			name: "References format",
			pr: &github.PullRequest{
				Body: github.String("References OPS-160"),
				Head: &github.PullRequestBranch{
					Ref: github.String("feature/some-fix"),
				},
			},
			expected: []string{"OPS-160"},
		},
		{
			name: "Ignore unknown team keys",
			pr: &github.PullRequest{
				Body: github.String("This PR fixes ABC-1234"),
				Head: &github.PullRequestBranch{
					Ref: github.String("feature/new-feature"),
				},
			},
			expected: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractIssueIDs(tt.pr, mockTeams)
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
			name: "Comment exists - new format",
			comments: []*github.IssueComment{
				{Body: github.String("[ENG-1234: Implement new feature](https://linear.app/team/issue/ENG-1234) (In Progress)")},
			},
			issueID:  "ENG-1234",
			expected: true,
		},
		{
			name: "Comment doesn't exist",
			comments: []*github.IssueComment{
				{Body: github.String("[DOC-5678: Document new API](https://linear.app/team/issue/DOC-5678) (In Progress)")},
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
		{
			name: "Old format comment - should still detect",
			comments: []*github.IssueComment{
				{Body: github.String("Linear issue: [ENG-1234](https://linear.app/team/issue/ENG-1234) - Implement new feature (In Progress)")},
			},
			issueID:  "ENG-1234",
			expected: true,
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