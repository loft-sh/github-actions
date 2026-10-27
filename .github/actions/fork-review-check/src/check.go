package main

import (
	"context"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"
)

// maxCompareCommits is the largest fork range the check accepts. A bigger
// compare is reported as truncated and fails, so no commit is skipped silently.
const maxCompareCommits = 250

// forkTagRe splits a fork release tag into the upstream release it names and
// the fork suffix: v0.16.5.vcluster.1 (kine) and v1.96.4-loft.3 (tailscale)
// both name an upstream tag (v0.16.5, v1.96.4).
var forkTagRe = regexp.MustCompile(`^(v\d+\.\d+\.\d+)(\.vcluster\.\d+|-loft\.\d+)$`)

// githubMergeCommitter is the committer GitHub records on commits it writes
// itself, such as the merge commit of a pull request merged in the UI or API.
const githubMergeCommitter = "web-flow"

// writePermissions are the collaborator permission values whose approvals
// count toward required reviews. The endpoint reports maintain as write.
var writePermissions = map[string]bool{"admin": true, "write": true}

// pin is one fork commit a build consumes.
type pin struct {
	Repo   string // fork repository, owner/name
	Ref    string // what the build pins: a tag, a Go version or a commit
	Tag    string // fork release tag; empty for commit and pseudo-version pins
	Commit string // S, the commit the build consumes
}

// upstreamOverride stands in for a missing fork-upstream property so a
// read-only run can still produce per-commit evidence. The missing property
// is reported as a failure either way.
type upstreamOverride struct {
	Repo string // upstream repository, owner/name
	Ref  string // upstream branch for commit pins; empty means its default branch
}

type baseRecord struct {
	Rule   string `json:"rule"` // upstream-tag or merge-base
	Ref    string `json:"ref"`
	Commit string `json:"commit"`
}

type pullRecord struct {
	Number      int       `json:"number"`
	URL         string    `json:"url"`
	Author      string    `json:"author"`
	Head        string    `json:"head"`
	MergeCommit string    `json:"merge_commit"`
	MergedAt    time.Time `json:"merged_at"`
}

type approvalRecord struct {
	Approver    string    `json:"approver"`
	SubmittedAt time.Time `json:"submitted_at"`
	Commit      string    `json:"commit"`
	Permission  string    `json:"permission"` // read at check time; the endpoint reports current access only
}

type commitResult struct {
	SHA      string          `json:"sha"`
	Author   string          `json:"author"`
	Subject  string          `json:"subject"`
	Merge    bool            `json:"merge"`
	Pull     *pullRecord     `json:"pull,omitempty"`
	Approval *approvalRecord `json:"approval,omitempty"`
	Pass     bool            `json:"pass"`
	Failures []string        `json:"failures,omitempty"`
}

type reviewedTree struct {
	Pull *pullRecord `json:"pull,omitempty"`
	Via  string      `json:"via,omitempty"` // head or merge
	Pass bool        `json:"pass"`
}

type forkResult struct {
	Repo               string         `json:"repo"`
	Ref                string         `json:"ref"`
	Commit             string         `json:"commit"`
	ForkUpstream       string         `json:"fork_upstream"`
	ForkUpstreamSource string         `json:"fork_upstream_source"` // property, override or missing
	Base               *baseRecord    `json:"base,omitempty"`
	ReviewedTree       *reviewedTree  `json:"reviewed_tree,omitempty"`
	Commits            []commitResult `json:"commits"`
	Failures           []string       `json:"failures,omitempty"`
	Pass               bool           `json:"pass"`
}

// pullData caches what the rules read per pull request.
type pullData struct {
	reviews       []reviewInfo
	lastForcePush time.Time
}

// checker evaluates the design's rules against live GitHub data.
type checker struct {
	api       forkAPI
	asOf      time.Time // rule 3 cutoff; zero skips the rule
	overrides map[string]upstreamOverride

	pulls map[string]*pullData
	perms map[string]string
}

func newChecker(api forkAPI, asOf time.Time, overrides map[string]upstreamOverride) *checker {
	return &checker{
		api:       api,
		asOf:      asOf,
		overrides: overrides,
		pulls:     map[string]*pullData{},
		perms:     map[string]string{},
	}
}

// checkFork applies the rules to every fork commit between the trusted
// upstream base and p.Commit.
func (c *checker) checkFork(ctx context.Context, p pin) forkResult {
	res := forkResult{Repo: p.Repo, Ref: p.Ref, Commit: p.Commit, Commits: []commitResult{}}

	upstream, err := c.api.ForkUpstream(ctx, p.Repo)
	if err != nil {
		res.Failures = append(res.Failures, fmt.Sprintf("read fork-upstream property: %v", err))
		return res
	}
	override, hasOverride := c.overrides[p.Repo]
	switch {
	case upstream != "":
		res.ForkUpstream, res.ForkUpstreamSource = upstream, "property"
	case hasOverride:
		res.ForkUpstream, res.ForkUpstreamSource = override.Repo, "override"
		res.Failures = append(res.Failures, "repo has no fork-upstream property; an org owner sets it, and the result below used the override "+override.Repo)
	default:
		res.ForkUpstreamSource = "missing"
		res.Failures = append(res.Failures, "repo has no fork-upstream property; an org owner sets it to the upstream repository, then the check re-runs")
		return res
	}

	base, cmp, failure := c.resolveBase(ctx, p, res.ForkUpstream, override.Ref)
	if failure != "" {
		res.Failures = append(res.Failures, failure)
		return res
	}
	res.Base = base

	for _, ci := range cmp.Commits {
		res.Commits = append(res.Commits, c.checkCommit(ctx, p.Repo, ci))
	}

	if len(cmp.Commits) > 0 {
		res.ReviewedTree = c.checkReviewedTree(ctx, p.Repo, commitOf(cmp.Commits, p.Commit))
		if !res.ReviewedTree.Pass {
			res.Failures = append(res.Failures, fmt.Sprintf("%s is not the approved final head or merge result of a merged fork pull request (rule 1)", short(p.Commit)))
		}
	}

	res.Pass = len(res.Failures) == 0
	for _, cr := range res.Commits {
		if !cr.Pass {
			res.Pass = false
		}
	}
	return res
}

// resolveBase finds the trusted upstream base and the fork range above it. A
// tag pin names its base (the tag before the fork suffix), which must be an
// ancestor of S. A commit pin has no tag, so its base is the merge base with
// the upstream branch.
func (c *checker) resolveBase(ctx context.Context, p pin, upstream, upstreamRef string) (*baseRecord, comparison, string) {
	var base *baseRecord
	var cmp comparison
	var err error

	if p.Tag != "" {
		m := forkTagRe.FindStringSubmatch(p.Tag)
		if m == nil {
			return nil, cmp, fmt.Sprintf("fork tag %s has no fork suffix (.vcluster.N or -loft.N), so it names no upstream base; pin a suffixed fork release tag", p.Tag)
		}
		baseSHA, err := c.api.ResolveTag(ctx, upstream, m[1])
		if err != nil {
			return nil, cmp, fmt.Sprintf("resolve upstream tag %s in %s: %v", m[1], upstream, err)
		}
		if baseSHA == "" {
			return nil, cmp, fmt.Sprintf("upstream %s has no tag %s, so the base is ambiguous", upstream, m[1])
		}
		base = &baseRecord{Rule: "upstream-tag", Ref: upstream + "@" + m[1], Commit: baseSHA}
		cmp, err = c.api.Compare(ctx, p.Repo, baseSHA, p.Commit)
		if err != nil {
			return nil, cmp, fmt.Sprintf("compare %s...%s: %v", short(baseSHA), short(p.Commit), err)
		}
		if cmp.Status != "ahead" && cmp.Status != "identical" {
			return nil, cmp, fmt.Sprintf("upstream base %s (%s) is not an ancestor of %s (compare status %s)", m[1], short(baseSHA), short(p.Commit), cmp.Status)
		}
	} else {
		ref := upstreamRef
		if ref == "" {
			info, err := c.api.Repo(ctx, upstream)
			if err != nil {
				return nil, cmp, fmt.Sprintf("read upstream %s: %v", upstream, err)
			}
			ref = info.DefaultBranch
		}
		owner := strings.SplitN(upstream, "/", 2)[0]
		cmp, err = c.api.Compare(ctx, p.Repo, owner+":"+ref, p.Commit)
		if err != nil {
			return nil, cmp, fmt.Sprintf("compare %s:%s...%s: %v", owner, ref, short(p.Commit), err)
		}
		if cmp.MergeBase == "" {
			return nil, cmp, fmt.Sprintf("%s shares no history with %s@%s", short(p.Commit), upstream, ref)
		}
		base = &baseRecord{Rule: "merge-base", Ref: upstream + "@" + ref, Commit: cmp.MergeBase}
	}

	if cmp.Total > maxCompareCommits {
		return nil, cmp, fmt.Sprintf("compare from base %s is truncated: %d commits, the limit is %d", short(base.Commit), cmp.Total, maxCompareCommits)
	}
	if len(cmp.Commits) != cmp.Total {
		return nil, cmp, fmt.Sprintf("compare from base %s returned %d of %d commits", short(base.Commit), len(cmp.Commits), cmp.Total)
	}
	return base, cmp, ""
}

// checkCommit applies rule 2 to one fork commit: it belongs to a merged fork
// pull request with a qualifying approval.
func (c *checker) checkCommit(ctx context.Context, repo string, ci commitInfo) commitResult {
	res := commitResult{SHA: ci.SHA, Author: ci.Author, Subject: ci.Subject, Merge: ci.Merge}

	pulls, err := c.mergedPulls(ctx, repo, ci.SHA)
	if err != nil {
		res.Failures = []string{fmt.Sprintf("list pull requests for the commit: %v", err)}
		return res
	}
	if len(pulls) == 0 {
		res.Failures = []string{"no merged pull request in " + repo + " contains this commit (direct push or bypass)"}
		return res
	}

	for _, pr := range pulls {
		approval, reasons := c.qualifyingApproval(ctx, repo, pr, effectiveAuthor(ci, pr))
		if approval == nil {
			res.Failures = append(res.Failures, reasons...)
			continue
		}
		res.Pull, res.Approval, res.Pass, res.Failures = pullRecordOf(pr), approval, true, nil
		return res
	}
	return res
}

// checkReviewedTree applies rule 1 to S: it is the final head or the merge
// result of a merged fork pull request that carries a qualifying approval.
func (c *checker) checkReviewedTree(ctx context.Context, repo string, ci commitInfo) *reviewedTree {
	sha := ci.SHA
	pulls, err := c.mergedPulls(ctx, repo, sha)
	if err != nil {
		return &reviewedTree{}
	}
	for _, pr := range pulls {
		via := ""
		switch sha {
		case pr.HeadSHA:
			via = "head"
		case pr.MergeCommit:
			via = "merge"
		default:
			continue
		}
		if approval, _ := c.qualifyingApproval(ctx, repo, pr, effectiveAuthor(ci, pr)); approval != nil {
			return &reviewedTree{Pull: pullRecordOf(pr), Via: via, Pass: true}
		}
	}
	return &reviewedTree{}
}

// qualifyingApproval returns the earliest approval on pr that meets every
// condition, or the reasons each approval fell short.
func (c *checker) qualifyingApproval(ctx context.Context, repo string, pr pullInfo, commitAuthor string) (*approvalRecord, []string) {
	data, err := c.pullData(ctx, repo, pr.Number)
	if err != nil {
		return nil, []string{fmt.Sprintf("#%d: read reviews: %v", pr.Number, err)}
	}

	var reasons []string
	var approvals []reviewInfo
	for _, r := range data.reviews {
		if r.State == "APPROVED" {
			approvals = append(approvals, r)
		}
	}
	if len(approvals) == 0 {
		return nil, []string{fmt.Sprintf("#%d: merged without an approval", pr.Number)}
	}
	sort.SliceStable(approvals, func(i, j int) bool { return approvals[i].SubmittedAt.Before(approvals[j].SubmittedAt) })

	for _, r := range approvals {
		reason := ""
		switch {
		case r.CommitID != pr.HeadSHA:
			reason = fmt.Sprintf("approval by %s is on %s, not the final head %s", r.User, short(r.CommitID), short(pr.HeadSHA))
		case strings.EqualFold(r.User, pr.Author):
			reason = fmt.Sprintf("approval by %s is by the pull request author", r.User)
		case commitAuthor == "":
			reason = fmt.Sprintf("approval by %s cannot be shown to be by a non-author: the commit author has no GitHub account", r.User)
		case strings.EqualFold(r.User, commitAuthor):
			reason = fmt.Sprintf("approval by %s is by the commit author", r.User)
		case !data.lastForcePush.IsZero() && !r.SubmittedAt.After(data.lastForcePush):
			reason = fmt.Sprintf("approval by %s predates the last force push (%s)", r.User, data.lastForcePush.Format(time.RFC3339))
		case !c.asOf.IsZero() && !r.SubmittedAt.Before(c.asOf):
			reason = fmt.Sprintf("approval by %s at %s is not before the release (%s) (rule 3)", r.User, r.SubmittedAt.Format(time.RFC3339), c.asOf.Format(time.RFC3339))
		}
		if reason != "" {
			reasons = append(reasons, fmt.Sprintf("#%d: %s", pr.Number, reason))
			continue
		}

		perm, err := c.permission(ctx, repo, r.User)
		if err != nil {
			reasons = append(reasons, fmt.Sprintf("#%d: read permission of %s: %v", pr.Number, r.User, err))
			continue
		}
		if !writePermissions[perm] {
			reasons = append(reasons, fmt.Sprintf("#%d: approval by %s does not count: %s permission, write or higher needed", pr.Number, r.User, perm))
			continue
		}
		return &approvalRecord{Approver: r.User, SubmittedAt: r.SubmittedAt, Commit: r.CommitID, Permission: perm}, nil
	}
	return nil, reasons
}

// mergedPulls lists the merged pull requests into repo that contain sha.
func (c *checker) mergedPulls(ctx context.Context, repo, sha string) ([]pullInfo, error) {
	all, err := c.api.PullsWithCommit(ctx, repo, sha)
	if err != nil {
		return nil, err
	}
	var merged []pullInfo
	for _, pr := range all {
		if !pr.MergedAt.IsZero() && strings.EqualFold(pr.BaseRepo, repo) {
			merged = append(merged, pr)
		}
	}
	sort.Slice(merged, func(i, j int) bool { return merged[i].Number < merged[j].Number })
	return merged, nil
}

func (c *checker) pullData(ctx context.Context, repo string, number int) (*pullData, error) {
	key := fmt.Sprintf("%s#%d", repo, number)
	if d, ok := c.pulls[key]; ok {
		return d, nil
	}
	reviews, err := c.api.Reviews(ctx, repo, number)
	if err != nil {
		return nil, err
	}
	forced, err := c.api.LastForcePush(ctx, repo, number)
	if err != nil {
		return nil, err
	}
	d := &pullData{reviews: reviews, lastForcePush: forced}
	c.pulls[key] = d
	return d, nil
}

func (c *checker) permission(ctx context.Context, repo, user string) (string, error) {
	key := repo + "/" + strings.ToLower(user)
	if p, ok := c.perms[key]; ok {
		return p, nil
	}
	p, err := c.api.Permission(ctx, repo, user)
	if err != nil {
		return "", err
	}
	c.perms[key] = p
	return p, nil
}

func pullRecordOf(pr pullInfo) *pullRecord {
	return &pullRecord{Number: pr.Number, URL: pr.URL, Author: pr.Author, Head: pr.HeadSHA, MergeCommit: pr.MergeCommit, MergedAt: pr.MergedAt}
}

func commitOf(commits []commitInfo, sha string) commitInfo {
	for _, ci := range commits {
		if ci.SHA == sha {
			return ci
		}
	}
	return commitInfo{SHA: sha}
}

// effectiveAuthor is the author the non-author rule compares approvers with.
// The merge commit GitHub writes when a pull request merges carries the
// merger as author but no code of its own, so for that commit the code author
// is the pull request author. Any other commit keeps its git author, merge
// commits pushed by hand included.
func effectiveAuthor(ci commitInfo, pr pullInfo) string {
	if ci.Merge && ci.Committer == githubMergeCommitter && ci.SHA == pr.MergeCommit {
		return pr.Author
	}
	return ci.Author
}

func short(sha string) string {
	if len(sha) > 12 {
		return sha[:12]
	}
	return sha
}
