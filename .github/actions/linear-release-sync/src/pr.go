package main

import (
	"regexp"
	"strings"

	pullrequests "github.com/loft-sh/github-actions/linear-release-sync/changelog/pull-requests"
)

var issuesInBodyREs = []*regexp.Regexp{
	regexp.MustCompile(`(?i)(?P<issue>[a-zA-Z]{2,10}-\d{1,5})`),
}

// ValidTeamKeys holds a set of known Linear team keys (lowercase) for filtering
type ValidTeamKeys map[string]struct{}

type LinearPullRequest struct {
	pullrequests.PullRequest
	validTeamKeys ValidTeamKeys
}

func NewLinearPullRequests(prs []pullrequests.PullRequest, validTeamKeys ValidTeamKeys) []LinearPullRequest {
	linearPRs := make([]LinearPullRequest, 0, len(prs))

	for _, pr := range prs {
		linearPRs = append(linearPRs, LinearPullRequest{
			PullRequest:   pr,
			validTeamKeys: validTeamKeys,
		})
	}

	return linearPRs
}

// IssueIDs extracts Linear issue IDs from the pull request body.
//
// Returns only issue IDs that match known Linear team keys (e.g., ENG-1234, DOC-567).
// Filters out false positives like pr-3354, snap-1 that match the regex pattern
// but aren't actual Linear issues, and ids whose number is 0 or has a leading
// zero, such as the StatefulSet ordinal pod-0 (POD is a real team key).
//
// Will return an empty slice if no valid issues are found.
func (p LinearPullRequest) IssueIDs() []string {
	issueIDs := []string{}

	for _, re := range issuesInBodyREs {
		matches := re.FindAllStringSubmatch(p.Body, -1)
		if len(matches) == 0 {
			continue
		}

		for _, match := range matches {
			for i, name := range re.SubexpNames() {
				if name != "issue" {
					continue
				}

				issueID := strings.ToLower(strings.TrimSpace(match[i]))

				if strings.HasPrefix(issueID, "cve") {
					issueID = ""
				}

				if issueID != "" && !hasValidIssueNumber(issueID) {
					issueID = ""
				}

				// Filter by valid team keys if provided
				if issueID != "" && p.validTeamKeys != nil {
					teamKey := extractTeamKey(issueID)
					if _, valid := p.validTeamKeys[teamKey]; !valid {
						issueID = ""
					}
				}

				if issueID != "" {
					issueIDs = append(issueIDs, issueID)
				}
			}
		}
	}

	return issueIDs
}

// hasValidIssueNumber reports whether the number after the last hyphen could be
// a Linear issue number. Linear numbers start at 1 and never carry a leading
// zero, so pod-0 and pod-01 are rejected while pod-1 and devops-123 are kept.
func hasValidIssueNumber(issueID string) bool {
	number := issueID[strings.LastIndex(issueID, "-")+1:]
	return number != "" && !strings.HasPrefix(number, "0")
}

// extractTeamKey extracts the team key from an issue ID (e.g., "eng" from "eng-1234")
func extractTeamKey(issueID string) string {
	parts := strings.SplitN(issueID, "-", 2)
	if len(parts) < 1 {
		return ""
	}
	return strings.ToLower(parts[0])
}
