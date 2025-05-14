package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"regexp"
	"strings"

	"github.com/google/go-github/v53/github"
	"golang.org/x/oauth2"
)

type linearIssue struct {
	ID    string
	Title string
	URL   string
	State struct {
		Name string
	}
}

type linearTeam struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Key  string `json:"key"`
}

type linearTeamsResponse struct {
	Data struct {
		Teams struct {
			Nodes []linearTeam `json:"nodes"`
		} `json:"teams"`
	} `json:"data"`
	Errors []struct {
		Message string `json:"message"`
	} `json:"errors"`
}

type linearGraphQLResponse struct {
	Data struct {
		Issue linearIssue `json:"issue"`
	} `json:"data"`
	Errors []struct {
		Message string `json:"message"`
	} `json:"errors"`
}

func main() {
	prNumber := flag.Int("pr-number", 0, "GitHub pull request number")
	repoOwner := flag.String("repo-owner", "", "GitHub repository owner")
	repoName := flag.String("repo-name", "", "GitHub repository name")
	flag.Parse()

	if *prNumber == 0 || *repoOwner == "" || *repoName == "" {
		log.Fatal("PR number, repository owner, and repository name are required")
	}

	// Get GitHub token from environment
	githubToken := os.Getenv("GITHUB_TOKEN")
	if githubToken == "" {
		log.Fatal("GITHUB_TOKEN environment variable is required")
	}

	// Get Linear token from environment
	linearToken := os.Getenv("LINEAR_TOKEN")
	if linearToken == "" {
		log.Fatal("LINEAR_TOKEN environment variable is required")
	}

	// Create GitHub client
	ctx := context.Background()
	ts := oauth2.StaticTokenSource(&oauth2.Token{AccessToken: githubToken})
	tc := oauth2.NewClient(ctx, ts)
	client := github.NewClient(tc)

	// Get PR details
	pr, _, err := client.PullRequests.Get(ctx, *repoOwner, *repoName, *prNumber)
	if err != nil {
		log.Fatalf("Failed to get PR: %v", err)
	}

	// Debug outputs to help diagnose issues
	if pr.Body != nil {
		log.Printf("PR Body: %s", *pr.Body)
	} else {
		log.Printf("PR Body is nil")
	}
	
	if pr.Head != nil && pr.Head.Ref != nil {
		log.Printf("Branch name: %s", *pr.Head.Ref)
	} else {
		log.Printf("Branch name is nil")
	}

	// Get all Linear teams
	teams, err := getLinearTeams(linearToken)
	if err != nil {
		log.Fatalf("Failed to get Linear teams: %v", err)
	}
	log.Printf("Found %d Linear teams", len(teams))
	for _, team := range teams {
		log.Printf("Team: %s (Key: %s)", team.Name, team.Key)
	}

	// Extract Linear issue IDs from PR description and branch name
	issueIDs := extractIssueIDs(pr, teams)
	if len(issueIDs) == 0 {
		log.Println("No Linear issue IDs found in PR")
		return
	}

	log.Printf("Found %d Linear issue IDs: %v", len(issueIDs), issueIDs)

	// Check if we've already commented about these issues
	comments, _, err := client.Issues.ListComments(ctx, *repoOwner, *repoName, *prNumber, nil)
	if err != nil {
		log.Fatalf("Failed to list comments: %v", err)
	}

	for _, issueID := range issueIDs {
		// Skip if we already commented about this issue
		if hasLinearComment(comments, issueID) {
			log.Printf("Already commented about issue %s", issueID)
			continue
		}

		// Get Linear issue details
		issue, err := getLinearIssue(linearToken, issueID)
		if err != nil {
			log.Printf("Failed to get Linear issue %s: %v", issueID, err)
			continue
		}

		// Create comment with issue details - entire title and ID as one link, without the status
		comment := fmt.Sprintf("[%s: %s](%s)", 
			issueID, issue.Title, issue.URL)
		_, _, err = client.Issues.CreateComment(ctx, *repoOwner, *repoName, *prNumber, &github.IssueComment{
			Body: &comment,
		})
		if err != nil {
			log.Printf("Failed to create comment for issue %s: %v", issueID, err)
			continue
		}

		log.Printf("Added comment for Linear issue %s", issueID)
	}
}

// getLinearTeams fetches all teams from Linear API
func getLinearTeams(token string) ([]linearTeam, error) {
	query := `{
		"query": "query Teams { teams { nodes { id name key } } }"
	}`

	// Create request
	req, err := http.NewRequest("POST", "https://api.linear.app/graphql", strings.NewReader(query))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", token)

	// Send request
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	// Read response
	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	// Parse response
	var response linearTeamsResponse
	err = json.Unmarshal(body, &response)
	if err != nil {
		return nil, err
	}

	// Check for errors
	if len(response.Errors) > 0 {
		return nil, fmt.Errorf("Linear API error: %s", response.Errors[0].Message)
	}

	return response.Data.Teams.Nodes, nil
}

// extractIssueIDs extracts Linear issue IDs from PR description and branch name
func extractIssueIDs(pr *github.PullRequest, teams []linearTeam) []string {
	issueIDs := []string{}

	// Build a regex pattern for each team key
	teamPatterns := make([]string, 0, len(teams))
	teamKeysMap := make(map[string]bool)
	
	for _, team := range teams {
		if team.Key != "" {
			teamPatterns = append(teamPatterns, regexp.QuoteMeta(team.Key))
			teamKeysMap[strings.ToUpper(team.Key)] = true
		}
	}
	
	if len(teamPatterns) == 0 {
		log.Println("No valid team keys found to build regex patterns")
		return issueIDs
	}
	
	// Create a regex that matches any team key followed by a dash and digits
	teamKeysPattern := strings.Join(teamPatterns, "|")
	issueRegex := regexp.MustCompile(fmt.Sprintf(`(?i)(%s)-(\d+)`, teamKeysPattern))
	
	bodies := []string{}
	if pr.Body != nil && *pr.Body != "" {
		bodies = append(bodies, *pr.Body)
	}
	
	if pr.Head != nil && pr.Head.Ref != nil && *pr.Head.Ref != "" {
		bodies = append(bodies, *pr.Head.Ref)
	}

	for _, body := range bodies {
		matches := issueRegex.FindAllStringSubmatch(body, -1)
		for _, match := range matches {
			if len(match) >= 3 {
				teamKey := strings.ToUpper(match[1])
				issueNumber := match[2]
				issueID := fmt.Sprintf("%s-%s", teamKey, issueNumber)
				
				// Skip CVE IDs
				if strings.HasPrefix(teamKey, "CVE") {
					continue
				}
				
				// Validate that this is an actual team key
				if teamKeysMap[teamKey] {
					issueIDs = append(issueIDs, issueID)
				}
			}
		}
	}

	// Remove duplicates
	uniqueIDs := make(map[string]bool)
	var result []string
	for _, id := range issueIDs {
		if !uniqueIDs[id] {
			uniqueIDs[id] = true
			result = append(result, id)
		}
	}

	return result
}

// hasLinearComment checks if a comment about an issue already exists
func hasLinearComment(comments []*github.IssueComment, issueID string) bool {
	for _, comment := range comments {
		if comment.Body != nil {
			commentBody := *comment.Body
			
			// Check for new format: [ENG-1234: Title](URL)
			if strings.Contains(commentBody, fmt.Sprintf("[%s:", issueID)) {
				return true
			}
			
			// Check for old format: Linear issue: [ENG-1234](URL)
			if strings.Contains(commentBody, fmt.Sprintf("Linear issue: [%s]", issueID)) {
				return true
			}
		}
	}
	return false
}

// getLinearIssue fetches issue details from Linear API
func getLinearIssue(token, issueID string) (*linearIssue, error) {
	// GraphQL query for Linear issue details
	query := fmt.Sprintf(`{
		"query": "query IssueDetails($id: String!) { issue(id: $id) { id title url state { name } } }",
		"variables": { "id": "%s" }
	}`, issueID)

	// Create request
	req, err := http.NewRequest("POST", "https://api.linear.app/graphql", strings.NewReader(query))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", token)

	// Send request
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	// Read response
	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	// Parse response
	var response linearGraphQLResponse
	err = json.Unmarshal(body, &response)
	if err != nil {
		return nil, err
	}

	// Check for errors
	if len(response.Errors) > 0 {
		return nil, fmt.Errorf("Linear API error: %s", response.Errors[0].Message)
	}

	return &response.Data.Issue, nil
}