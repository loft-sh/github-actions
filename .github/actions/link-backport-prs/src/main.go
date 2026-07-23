// Command link-backport-prs links sorenlouv-created backport pull requests to
// the matching Linear sub-issue.
//
// On the shared backport workflow, after sorenlouv opens the backport PRs for a
// merged source PR, this tool resolves the source PR's Linear issue (the
// parent), finds the sub-issue for each backported release line by its title
// prefix (for example "[0.34] Copy of ENGCP-906"), and appends "Fixes <id>" to
// that backport PR's body so the sub-issue is closed when the backport merges.
//
// It is advisory: any failure is logged as a warning and the process still
// exits 0 so it never blocks the backport workflow.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strings"

	"github.com/google/go-github/v88/github"
)

const linearAPIURL = "https://api.linear.app/graphql"

// issueRef is a minimal Linear issue.
type issueRef struct {
	ID         string `json:"id"`
	Identifier string `json:"identifier"`
	Title      string `json:"title"`
}

// issueWithChildren is an issue plus its direct sub-issues.
type issueWithChildren struct {
	issueRef
	Children struct {
		Nodes []issueRef `json:"nodes"`
	} `json:"children"`
}

// issueFamily is the issue attached to a PR, its sub-issues, and its parent
// (with the parent's sub-issues, i.e. the attached issue's siblings).
type issueFamily struct {
	issueWithChildren
	Parent *issueWithChildren `json:"parent"`
}

func main() {
	// Workflow commands (::notice::, ::warning::) are only parsed when they
	// start the line, so drop log's default date/time prefix; otherwise the
	// annotations never surface in the run.
	log.SetFlags(0)
	if err := run(); err != nil {
		// Advisory tool: surface the problem but never fail the backport job.
		warnf("link-backport-prs: %v", err)
		writeLinkedCount(0)
	}
}

func run() error {
	sourcePR := flag.Int("source-pr", 0, "merged source pull request number")
	repoOwner := flag.String("repo-owner", "", "repository owner")
	repoName := flag.String("repo-name", "", "repository name")
	labelPrefix := flag.String("label-prefix", "backport-to-", "prefix of backport labels")
	dryRun := flag.Bool("dry-run", false, "log intended edits without applying them")
	flag.Parse()

	if *sourcePR == 0 || *repoOwner == "" || *repoName == "" {
		return fmt.Errorf("source-pr, repo-owner and repo-name are required")
	}

	githubToken := os.Getenv("GITHUB_TOKEN")
	if githubToken == "" {
		return fmt.Errorf("GITHUB_TOKEN is required")
	}

	ctx := context.Background()
	gh, err := github.NewClient(github.WithAuthToken(githubToken))
	if err != nil {
		return fmt.Errorf("create github client: %w", err)
	}

	src, _, err := gh.PullRequests.Get(ctx, *repoOwner, *repoName, *sourcePR)
	if err != nil {
		return fmt.Errorf("get source PR #%d: %w", *sourcePR, err)
	}

	// A source PR without backport labels has nothing to link and nothing to
	// fix, so it stays a plain notice.
	targets := backportTargets(src.Labels, *labelPrefix)
	if len(targets) == 0 {
		noticef("source PR #%d has no %s* labels, nothing to link", *sourcePR, *labelPrefix)
		writeLinkedCount(0)
		return nil
	}

	// Backport labels are present, so every skip from here on hides a link that
	// should have happened. The empty-token case is the silent no-op from the
	// production rollout (DEVOPS-1060): a missing or misnamed secret looked
	// identical to the feature being off. Make it loud, with the fix.
	linearToken := os.Getenv("LINEAR_TOKEN")
	if linearToken == "" {
		remedyWarning{
			problem: fmt.Sprintf("source PR #%d carries %d backport label(s) but linear-token is empty, so no backport PR was linked to its Linear sub-issue", *sourcePR, len(targets)),
			remedy:  "set the backport workflow's linear-token secret to a valid Linear API token (verify the caller's `secrets: linear-token:` maps to an existing repository secret)",
		}.emit()
		writeLinkedCount(0)
		return nil
	}

	family := resolveFamily(linearToken, src)
	if family == nil {
		remedyWarning{
			problem: fmt.Sprintf("could not resolve a Linear issue for source PR #%d (no attachment, and no TEAM-123 identifier in its branch or body), so its %d backport target(s) were not linked", *sourcePR, len(targets)),
			remedy:  "attach the source PR to its Linear issue, or include the issue identifier in the PR branch name or body",
		}.emit()
		writeLinkedCount(0)
		return nil
	}
	candidates := familyCandidates(*family)
	noticef("resolved Linear family from %s: %d candidate sub-issues", family.Identifier, len(candidates))

	linked := 0
	for _, target := range targets {
		version := versionFromBranch(target)
		if version == "" {
			noticef("label target %q has no X.Y version (e.g. main), skipping", target)
			continue
		}

		sub, ok := matchSubIssue(candidates, version)
		if !ok {
			remedyWarning{
				problem: fmt.Sprintf("no sub-issue with a [%s] title prefix found under %s for backport to %s", version, family.Identifier, target),
				remedy:  fmt.Sprintf("create or rename a sub-issue under %s so its title starts with [%s]", family.Identifier, version),
			}.emit()
			continue
		}

		headBranch := backportHeadBranch(target, *sourcePR)
		bp, err := findBackportPR(ctx, gh, *repoOwner, *repoName, headBranch, target)
		if err != nil {
			warnf("looking up backport PR %s: %v", headBranch, err)
			continue
		}
		if bp == nil {
			remedyWarning{
				problem: fmt.Sprintf("no backport PR found for %s (base %s); sorenlouv likely skipped it after a merge conflict or empty diff", headBranch, target),
				remedy:  fmt.Sprintf("backport to %s manually and add 'Fixes %s' to that PR's body", target, sub.Identifier),
			}.emit()
			continue
		}

		if bodyReferencesIssue(bp.GetBody(), sub.Identifier) {
			noticef("backport PR #%d already references %s, skipping", bp.GetNumber(), sub.Identifier)
			continue
		}

		newBody := appendFixes(bp.GetBody(), sub.Identifier)
		if *dryRun {
			noticef("[dry-run] would add 'Fixes %s' to backport PR #%d (%s)", sub.Identifier, bp.GetNumber(), target)
			linked++
			continue
		}

		if _, _, err := gh.PullRequests.Edit(ctx, *repoOwner, *repoName, bp.GetNumber(), &github.PullRequest{Body: &newBody}); err != nil {
			warnf("updating backport PR #%d body: %v", bp.GetNumber(), err)
			continue
		}
		noticef("linked backport PR #%d (%s) to %s via 'Fixes %s'", bp.GetNumber(), target, sub.Identifier, sub.Identifier)
		linked++
	}

	noticef("link-backport-prs: linked %d of %d backport target(s)", linked, len(targets))
	writeLinkedCount(linked)
	return nil
}

// backportTargets returns the target branch for each backport-to-* label,
// i.e. the label with the prefix stripped ("backport-to-v0.34" -> "v0.34").
func backportTargets(labels []*github.Label, prefix string) []string {
	names := make([]string, 0, len(labels))
	for _, l := range labels {
		names = append(names, l.GetName())
	}
	return backportTargetsFromNames(names, prefix)
}

// backportTargetsFromNames is the pure core of backportTargets.
func backportTargetsFromNames(names []string, prefix string) []string {
	var targets []string
	for _, name := range names {
		if strings.HasPrefix(name, prefix) {
			targets = append(targets, strings.TrimPrefix(name, prefix))
		}
	}
	return targets
}

var versionInBranchRe = regexp.MustCompile(`(\d+)\.(\d+)`)

// versionFromBranch extracts the X.Y release line from a target branch.
// "v0.34" -> "0.34", "release-4.2" -> "4.2", "main" -> "".
func versionFromBranch(branch string) string {
	m := versionInBranchRe.FindStringSubmatch(branch)
	if len(m) < 3 {
		return ""
	}
	return m[1] + "." + m[2]
}

// backportHeadBranch is the branch sorenlouv creates for a backport:
// backport/<targetBranch>/pr-<sourcePR>.
func backportHeadBranch(targetBranch string, sourcePR int) string {
	return fmt.Sprintf("backport/%s/pr-%d", targetBranch, sourcePR)
}

// titleMatchesVersion reports whether a sub-issue title carries the release-line
// prefix for version, e.g. "[0.34] Copy of ENGCP-906" or "[v0.34] ...".
func titleMatchesVersion(title, version string) bool {
	if version == "" {
		return false
	}
	re := regexp.MustCompile(`^\s*\[v?` + regexp.QuoteMeta(version) + `\]`)
	return re.MatchString(title)
}

// matchSubIssue returns the first candidate whose title matches the version.
func matchSubIssue(candidates []issueRef, version string) (issueRef, bool) {
	for _, c := range candidates {
		if titleMatchesVersion(c.Title, version) {
			return c, true
		}
	}
	return issueRef{}, false
}

// familyCandidates flattens an issue family into the set of issues that may
// carry a release-line prefix: the family root plus its direct children. When
// the attached issue has a parent, the root is that parent and the children are
// the attached issue's siblings (which is where the [X.Y] copies live).
func familyCandidates(f issueFamily) []issueRef {
	if f.Parent != nil {
		out := []issueRef{f.Parent.issueRef}
		return append(out, f.Parent.Children.Nodes...)
	}
	out := []issueRef{f.issueRef}
	return append(out, f.Children.Nodes...)
}

var fixesRe = regexp.MustCompile(`(?i)\b(fix(es|ed)?|close[sd]?|resolve[sd]?)\s+#?`)

// bodyReferencesIssue reports whether a PR body already closes/fixes/resolves
// the given Linear identifier, so the tool stays idempotent across re-runs.
func bodyReferencesIssue(body, identifier string) bool {
	re := regexp.MustCompile(fixesRe.String() + regexp.QuoteMeta(identifier) + `\b`)
	return re.MatchString(body)
}

// appendFixes adds a "Fixes <identifier>" line to a PR body.
func appendFixes(body, identifier string) string {
	trimmed := strings.TrimRight(body, "\n")
	if trimmed == "" {
		return "Fixes " + identifier
	}
	return trimmed + "\n\nFixes " + identifier
}

// findBackportPR returns the backport PR with the expected head branch, or nil
// if none exists yet.
func findBackportPR(ctx context.Context, gh *github.Client, owner, repo, headBranch, baseBranch string) (*github.PullRequest, error) {
	opts := &github.PullRequestListOptions{
		State:       "all",
		Head:        owner + ":" + headBranch,
		Base:        baseBranch,
		ListOptions: github.ListOptions{PerPage: 20},
	}
	prs, _, err := gh.PullRequests.List(ctx, owner, repo, opts)
	if err != nil {
		return nil, err
	}
	for _, pr := range prs {
		if pr.GetHead().GetRef() == headBranch {
			return pr, nil
		}
	}
	return nil, nil
}

var identifierRe = regexp.MustCompile(`(?i)\b([A-Z][A-Z0-9]+)-(\d+)\b`)

// extractIdentifier returns the first Linear-looking identifier (TEAM-123) found
// across the given strings, uppercased.
func extractIdentifier(strs ...string) string {
	for _, s := range strs {
		if m := identifierRe.FindStringSubmatch(s); len(m) == 3 {
			return strings.ToUpper(m[1]) + "-" + m[2]
		}
	}
	return ""
}

// resolveFamily finds the Linear issue family for a source PR: first via
// Linear's reverse attachment lookup on the PR URL, then by parsing an
// identifier from the branch name or body as a fallback.
func resolveFamily(token string, src *github.PullRequest) *issueFamily {
	if url := src.GetHTMLURL(); url != "" {
		if f, err := getFamilyByURL(token, url); err != nil {
			warnf("attachmentsForURL lookup failed: %v", err)
		} else if f != nil {
			return f
		}
	}
	id := extractIdentifier(src.GetHead().GetRef(), src.GetBody())
	if id == "" {
		return nil
	}
	noticef("falling back to identifier %s parsed from branch/body", id)
	f, err := getFamilyByID(token, id)
	if err != nil {
		warnf("issue lookup for %s failed: %v", id, err)
		return nil
	}
	return f
}

func getFamilyByURL(token, url string) (*issueFamily, error) {
	const q = `query($url: String!) {
  attachmentsForURL(url: $url) {
    nodes { issue {
      id identifier title
      children { nodes { id identifier title } }
      parent { id identifier title children { nodes { id identifier title } } }
    } }
  }
}`
	var resp struct {
		Data struct {
			AttachmentsForURL struct {
				Nodes []struct {
					Issue issueFamily `json:"issue"`
				} `json:"nodes"`
			} `json:"attachmentsForURL"`
		} `json:"data"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if err := linearGraphQL(token, q, map[string]any{"url": url}, &resp); err != nil {
		return nil, err
	}
	if len(resp.Errors) > 0 {
		return nil, fmt.Errorf("linear: %s", resp.Errors[0].Message)
	}
	for _, n := range resp.Data.AttachmentsForURL.Nodes {
		if n.Issue.Identifier != "" {
			f := n.Issue
			return &f, nil
		}
	}
	return nil, nil
}

func getFamilyByID(token, id string) (*issueFamily, error) {
	const q = `query($id: String!) {
  issue(id: $id) {
    id identifier title
    children { nodes { id identifier title } }
    parent { id identifier title children { nodes { id identifier title } } }
  }
}`
	var resp struct {
		Data struct {
			Issue issueFamily `json:"issue"`
		} `json:"data"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if err := linearGraphQL(token, q, map[string]any{"id": id}, &resp); err != nil {
		return nil, err
	}
	if len(resp.Errors) > 0 {
		return nil, fmt.Errorf("linear: %s", resp.Errors[0].Message)
	}
	if resp.Data.Issue.Identifier == "" {
		return nil, nil
	}
	f := resp.Data.Issue
	return &f, nil
}

func linearGraphQL(token, query string, variables map[string]any, out any) error {
	payload, err := json.Marshal(map[string]any{"query": query, "variables": variables})
	if err != nil {
		return err
	}
	req, err := http.NewRequest("POST", linearAPIURL, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", token)

	resp, err := (&http.Client{}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("linear status %d: %s", resp.StatusCode, string(body))
	}
	return json.Unmarshal(body, out)
}

// remedyWarning is a skip a human can fix. It renders to both a ::warning::
// annotation (surfaced in the run's annotations) and a job-summary bullet, so a
// skipped link is impossible to miss and always states how to fix it. Emitting
// one never fails the job: the step stays advisory.
type remedyWarning struct {
	problem string // what was skipped and why
	remedy  string // the concrete action that makes the link happen
}

func (w remedyWarning) annotation() string {
	return fmt.Sprintf("%s. Remedy: %s", w.problem, w.remedy)
}

func (w remedyWarning) summaryLine() string {
	return fmt.Sprintf("- ⚠️ %s\n  - **Remedy:** %s", w.problem, w.remedy)
}

func (w remedyWarning) emit() {
	warnf("%s", w.annotation())
	summaryf("%s", w.summaryLine())
}

func noticef(format string, args ...any) {
	log.Printf("::notice::"+format, args...)
}

func warnf(format string, args ...any) {
	log.Printf("::warning::"+format, args...)
}

// summaryf appends a markdown line to the GitHub job summary. Advisory: when
// $GITHUB_STEP_SUMMARY is unset (local runs) or unwritable, it is a no-op.
func summaryf(format string, args ...any) {
	appendToEnvFile("GITHUB_STEP_SUMMARY", fmt.Sprintf(format, args...))
}

// writeLinkedCount publishes the linked-count step output declared in
// action.yml. It is written on every exit path (0 when the step skips) so
// callers always read a number.
func writeLinkedCount(n int) {
	appendToEnvFile("GITHUB_OUTPUT", fmt.Sprintf("linked-count=%d", n))
}

// appendToEnvFile appends one line to the file named by envVar, if that
// variable is set. Backs both $GITHUB_OUTPUT and $GITHUB_STEP_SUMMARY; write
// failures are ignored so the advisory step never fails the backport job.
func appendToEnvFile(envVar, line string) {
	path := os.Getenv(envVar)
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintln(f, line)
}
