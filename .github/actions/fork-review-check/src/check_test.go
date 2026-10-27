package main

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

// fakeAPI serves canned GitHub data keyed the way forkAPI asks for it.
type fakeAPI struct {
	repos      map[string]repoInfo
	upstreams  map[string]string
	tags       map[string]string // repo@tag -> sha
	compares   map[string]comparison
	pulls      map[string][]pullInfo // repo@sha
	reviews    map[string][]reviewInfo
	forcePush  map[string]time.Time
	perms      map[string]string // repo/user
	permErr    error
	permCalled int
}

func newFake() *fakeAPI {
	return &fakeAPI{
		repos:     map[string]repoInfo{},
		upstreams: map[string]string{},
		tags:      map[string]string{},
		compares:  map[string]comparison{},
		pulls:     map[string][]pullInfo{},
		reviews:   map[string][]reviewInfo{},
		forcePush: map[string]time.Time{},
		perms:     map[string]string{},
	}
}

func (f *fakeAPI) Repo(_ context.Context, repo string) (repoInfo, error) {
	r, ok := f.repos[repo]
	if !ok {
		return repoInfo{}, fmt.Errorf("no repo %s", repo)
	}
	return r, nil
}

func (f *fakeAPI) ForkUpstream(_ context.Context, repo string) (string, error) {
	return f.upstreams[repo], nil
}

func (f *fakeAPI) ResolveTag(_ context.Context, repo, tag string) (string, error) {
	return f.tags[repo+"@"+tag], nil
}

func (f *fakeAPI) Compare(_ context.Context, repo, base, head string) (comparison, error) {
	c, ok := f.compares[repo+"@"+base+"..."+head]
	if !ok {
		return comparison{}, fmt.Errorf("no compare %s %s...%s", repo, base, head)
	}
	return c, nil
}

func (f *fakeAPI) PullsWithCommit(_ context.Context, repo, sha string) ([]pullInfo, error) {
	return f.pulls[repo+"@"+sha], nil
}

func (f *fakeAPI) Reviews(_ context.Context, repo string, number int) ([]reviewInfo, error) {
	return f.reviews[fmt.Sprintf("%s#%d", repo, number)], nil
}

func (f *fakeAPI) LastForcePush(_ context.Context, repo string, number int) (time.Time, error) {
	return f.forcePush[fmt.Sprintf("%s#%d", repo, number)], nil
}

func (f *fakeAPI) Permission(_ context.Context, repo, user string) (string, error) {
	f.permCalled++
	if f.permErr != nil {
		return "", f.permErr
	}
	if p, ok := f.perms[repo+"/"+user]; ok {
		return p, nil
	}
	return "none", nil
}

const (
	fork     = "loft-sh/kine"
	upstream = "k3s-io/kine"
	baseSHA  = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	c1       = "1111111111111111111111111111111111111111"
	c2       = "2222222222222222222222222222222222222222"
	head     = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	merge    = "dddddddddddddddddddddddddddddddddddddddd"
	tag      = "v0.16.5.vcluster.1"
)

var t0 = time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)

// reviewedFork is kine at a tag with two fork commits, both from PR #22,
// approved at its final head by bob (write) after alice opened it. The tag
// points at the PR's merge commit, written by GitHub.
func reviewedFork() *fakeAPI {
	f := newFake()
	f.upstreams[fork] = upstream
	f.tags[upstream+"@v0.16.5"] = baseSHA
	f.tags[fork+"@"+tag] = merge
	f.compares[fork+"@"+baseSHA+"..."+merge] = comparison{
		Status: "ahead", Total: 3,
		Commits: []commitInfo{
			{SHA: c1, Author: "alice", Committer: "alice", Subject: "add kerberos"},
			{SHA: head, Author: "alice", Committer: "alice", Subject: "fix review"},
			{SHA: merge, Author: "bob", Committer: githubMergeCommitter, Subject: "Merge pull request #22", Merge: true},
		},
	}
	pr22 := pullInfo{Number: 22, URL: "https://github.com/loft-sh/kine/pull/22", Author: "alice", BaseRepo: fork, HeadSHA: head, MergeCommit: merge, MergedAt: t0.Add(2 * time.Hour)}
	for _, sha := range []string{c1, head, merge} {
		f.pulls[fork+"@"+sha] = []pullInfo{pr22}
	}
	f.reviews[fork+"#22"] = []reviewInfo{{User: "bob", State: "APPROVED", CommitID: head, SubmittedAt: t0.Add(time.Hour)}}
	f.perms[fork+"/bob"] = "write"
	return f
}

func tagPin() pin { return pin{Repo: fork, Ref: tag, Tag: tag, Commit: merge} }

func runCheck(f *fakeAPI, p pin) forkResult {
	return newChecker(f, time.Time{}, nil).checkFork(context.Background(), p)
}

func failuresOf(r forkResult) string {
	var all []string
	all = append(all, r.Failures...)
	for _, c := range r.Commits {
		all = append(all, c.Failures...)
	}
	return strings.Join(all, "\n")
}

func TestReviewedForkPasses(t *testing.T) {
	r := runCheck(reviewedFork(), tagPin())
	if !r.Pass {
		t.Fatalf("want pass, got failures:\n%s", failuresOf(r))
	}
	if r.Base.Rule != "upstream-tag" || r.Base.Commit != baseSHA {
		t.Errorf("base = %+v, want upstream-tag %s", r.Base, baseSHA)
	}
	if r.ReviewedTree.Via != "merge" || r.ReviewedTree.Pull.Number != 22 {
		t.Errorf("reviewed tree = %+v, want merge result of #22", r.ReviewedTree)
	}
	for _, c := range r.Commits {
		if c.Approval == nil || c.Approval.Approver != "bob" || c.Approval.Permission != "write" {
			t.Errorf("commit %s approval = %+v, want bob with write", short(c.SHA), c.Approval)
		}
	}
}

func TestDirectPushFails(t *testing.T) {
	f := reviewedFork()
	delete(f.pulls, fork+"@"+c1)
	r := runCheck(f, tagPin())
	if r.Pass || r.Commits[0].Pass {
		t.Fatal("want the direct push to fail")
	}
	if !strings.Contains(r.Commits[0].Failures[0], "direct push") {
		t.Errorf("failure = %q, want it to name a direct push", r.Commits[0].Failures[0])
	}
	if !r.Commits[1].Pass {
		t.Error("the reviewed commits should still pass on their own")
	}
}

func TestUnmergedPullDoesNotCount(t *testing.T) {
	f := reviewedFork()
	open := pullInfo{Number: 30, Author: "alice", BaseRepo: fork, HeadSHA: c1}
	f.pulls[fork+"@"+c1] = []pullInfo{open}
	r := runCheck(f, tagPin())
	if r.Commits[0].Pass {
		t.Fatal("an open pull request must not satisfy rule 2")
	}
}

func TestPullIntoAnotherRepoDoesNotCount(t *testing.T) {
	f := reviewedFork()
	upstreamPR := pullInfo{Number: 22, Author: "alice", BaseRepo: upstream, HeadSHA: head, MergedAt: t0}
	f.pulls[fork+"@"+c1] = []pullInfo{upstreamPR}
	r := runCheck(f, tagPin())
	if r.Commits[0].Pass {
		t.Fatal("a pull request merged into another repository must not count")
	}
}

func TestSelfApprovalFails(t *testing.T) {
	f := reviewedFork()
	f.reviews[fork+"#22"] = []reviewInfo{{User: "alice", State: "APPROVED", CommitID: head, SubmittedAt: t0.Add(time.Hour)}}
	f.perms[fork+"/alice"] = "admin"
	r := runCheck(f, tagPin())
	if r.Pass {
		t.Fatal("want the PR author's own approval to fail")
	}
	if !strings.Contains(failuresOf(r), "pull request author") {
		t.Errorf("failures do not name the PR author:\n%s", failuresOf(r))
	}
}

func TestCommitAuthorApprovalFails(t *testing.T) {
	// carol opens a PR carrying a commit dave wrote; dave approves it.
	f := reviewedFork()
	f.compares[fork+"@"+baseSHA+"..."+merge].Commits[0].Author = "dave"
	f.reviews[fork+"#22"] = []reviewInfo{{User: "dave", State: "APPROVED", CommitID: head, SubmittedAt: t0.Add(time.Hour)}}
	f.perms[fork+"/dave"] = "write"
	r := runCheck(f, tagPin())
	if r.Commits[0].Pass {
		t.Fatal("want an approval by the commit author to fail")
	}
	if !strings.Contains(r.Commits[0].Failures[0], "commit author") {
		t.Errorf("failure = %q, want it to name the commit author", r.Commits[0].Failures[0])
	}
}

func TestApproverMayMergeTheirReview(t *testing.T) {
	// bob approved and merged; GitHub's merge commit names bob as author but
	// carries no code, so bob's approval still counts for it.
	r := runCheck(reviewedFork(), tagPin())
	merged := r.Commits[2]
	if !merged.Merge || !merged.Pass {
		t.Fatalf("GitHub merge commit by the approver should pass: %+v", merged)
	}
}

func TestHandMadeMergeByApproverFails(t *testing.T) {
	f := reviewedFork()
	f.compares[fork+"@"+baseSHA+"..."+merge].Commits[2].Committer = "bob"
	r := runCheck(f, tagPin())
	if r.Commits[2].Pass {
		t.Fatal("a merge commit bob pushed himself is his code; his approval cannot cover it")
	}
}

func TestStaleHeadApprovalFails(t *testing.T) {
	f := reviewedFork()
	f.reviews[fork+"#22"] = []reviewInfo{{User: "bob", State: "APPROVED", CommitID: c1, SubmittedAt: t0.Add(time.Hour)}}
	r := runCheck(f, tagPin())
	if r.Pass {
		t.Fatal("want an approval on an earlier head to fail")
	}
	if !strings.Contains(failuresOf(r), "not the final head") {
		t.Errorf("failures do not name the stale head:\n%s", failuresOf(r))
	}
}

func TestApprovalBeforeForcePushFails(t *testing.T) {
	f := reviewedFork()
	f.forcePush[fork+"#22"] = t0.Add(90 * time.Minute)
	r := runCheck(f, tagPin())
	if r.Pass {
		t.Fatal("want an approval older than the last force push to fail")
	}
	if !strings.Contains(failuresOf(r), "force push") {
		t.Errorf("failures do not name the force push:\n%s", failuresOf(r))
	}
}

func TestReadOnlyApproverFails(t *testing.T) {
	f := reviewedFork()
	f.perms[fork+"/bob"] = "read"
	r := runCheck(f, tagPin())
	if r.Pass {
		t.Fatal("want an approver with read permission to fail")
	}
	if !strings.Contains(failuresOf(r), "read permission") {
		t.Errorf("failures do not name the permission:\n%s", failuresOf(r))
	}
}

func TestPermissionLookupErrorFailsClosed(t *testing.T) {
	f := reviewedFork()
	f.permErr = fmt.Errorf("403 Resource not accessible by integration")
	r := runCheck(f, tagPin())
	if r.Pass {
		t.Fatal("a permission lookup error must fail the check")
	}
	if !strings.Contains(failuresOf(r), "403") {
		t.Errorf("failures hide the lookup error:\n%s", failuresOf(r))
	}
}

func TestPermissionIsReadOncePerApprover(t *testing.T) {
	f := reviewedFork()
	runCheck(f, tagPin())
	if f.permCalled != 1 {
		t.Errorf("permission read %d times, want 1 (cached)", f.permCalled)
	}
}

func TestLaterQualifyingApprovalCounts(t *testing.T) {
	f := reviewedFork()
	f.reviews[fork+"#22"] = []reviewInfo{
		{User: "alice", State: "APPROVED", CommitID: head, SubmittedAt: t0.Add(30 * time.Minute)},
		{User: "carol", State: "CHANGES_REQUESTED", CommitID: head, SubmittedAt: t0.Add(40 * time.Minute)},
		{User: "bob", State: "APPROVED", CommitID: head, SubmittedAt: t0.Add(time.Hour)},
	}
	r := runCheck(f, tagPin())
	if !r.Pass {
		t.Fatalf("bob's approval qualifies, want pass:\n%s", failuresOf(r))
	}
}

func TestNoApprovalFails(t *testing.T) {
	f := reviewedFork()
	f.reviews[fork+"#22"] = nil
	r := runCheck(f, tagPin())
	if !strings.Contains(failuresOf(r), "merged without an approval") {
		t.Errorf("failures do not say the PR had no approval:\n%s", failuresOf(r))
	}
}

func TestApprovalAfterReleaseFails(t *testing.T) {
	f := reviewedFork()
	r := newChecker(f, t0.Add(30*time.Minute), nil).checkFork(context.Background(), tagPin())
	if r.Pass {
		t.Fatal("want an approval after the release to fail (rule 3)")
	}
	if !strings.Contains(failuresOf(r), "rule 3") {
		t.Errorf("failures do not cite rule 3:\n%s", failuresOf(r))
	}
}

func TestIntermediateCommitIsNotAReviewedTree(t *testing.T) {
	// Pinning c1, a commit inside PR #22, fails rule 1 even though #22 is approved.
	f := reviewedFork()
	f.tags[fork+"@v0.16.5.vcluster.0"] = c1
	f.compares[fork+"@"+baseSHA+"..."+c1] = comparison{Status: "ahead", Total: 1, Commits: []commitInfo{{SHA: c1, Author: "alice", Subject: "add kerberos"}}}
	r := runCheck(f, pin{Repo: fork, Ref: "v0.16.5.vcluster.0", Tag: "v0.16.5.vcluster.0", Commit: c1})
	if r.Pass {
		t.Fatal("want rule 1 to fail on an intermediate PR commit")
	}
	if r.ReviewedTree.Pass || !strings.Contains(failuresOf(r), "rule 1") {
		t.Errorf("rule 1 not reported:\n%s", failuresOf(r))
	}
	if !r.Commits[0].Pass {
		t.Error("the commit itself is covered by #22; only rule 1 should fail")
	}
}

func TestFinalHeadIsAReviewedTree(t *testing.T) {
	f := reviewedFork()
	f.tags[fork+"@v0.16.5.vcluster.0"] = head
	f.compares[fork+"@"+baseSHA+"..."+head] = comparison{Status: "ahead", Total: 2, Commits: f.compares[fork+"@"+baseSHA+"..."+merge].Commits[:2]}
	r := runCheck(f, pin{Repo: fork, Ref: "v0.16.5.vcluster.0", Tag: "v0.16.5.vcluster.0", Commit: head})
	if !r.Pass || r.ReviewedTree.Via != "head" {
		t.Fatalf("want the approved final head to pass via head: %+v\n%s", r.ReviewedTree, failuresOf(r))
	}
}

func TestUnsuffixedTagFails(t *testing.T) {
	r := runCheck(reviewedFork(), pin{Repo: fork, Ref: "v0.14.5", Tag: "v0.14.5", Commit: merge})
	if r.Pass || !strings.Contains(failuresOf(r), "no fork suffix") {
		t.Fatalf("want an unsuffixed fork tag to fail:\n%s", failuresOf(r))
	}
}

func TestLoftSuffixNamesUpstreamTag(t *testing.T) {
	m := forkTagRe.FindStringSubmatch("v1.96.4-loft.3")
	if m == nil || m[1] != "v1.96.4" {
		t.Fatalf("v1.96.4-loft.3 split = %v, want base v1.96.4", m)
	}
	for _, bad := range []string{"v0.14.15-rc.2", "v1.96.4-loft", "v0.16.5.vcluster", "cmd/cigocacher/abc"} {
		if forkTagRe.MatchString(bad) {
			t.Errorf("%s should not parse as a fork release tag", bad)
		}
	}
}

func TestMissingUpstreamTagFails(t *testing.T) {
	f := reviewedFork()
	delete(f.tags, upstream+"@v0.16.5")
	r := runCheck(f, tagPin())
	if r.Pass || !strings.Contains(failuresOf(r), "has no tag v0.16.5") {
		t.Fatalf("want a missing upstream tag to fail:\n%s", failuresOf(r))
	}
}

func TestBaseNotAncestorFails(t *testing.T) {
	f := reviewedFork()
	cmp := f.compares[fork+"@"+baseSHA+"..."+merge]
	cmp.Status = "diverged"
	f.compares[fork+"@"+baseSHA+"..."+merge] = cmp
	r := runCheck(f, tagPin())
	if r.Pass || !strings.Contains(failuresOf(r), "not an ancestor") {
		t.Fatalf("want a diverged base to fail:\n%s", failuresOf(r))
	}
}

func TestTruncatedCompareFails(t *testing.T) {
	f := reviewedFork()
	cmp := f.compares[fork+"@"+baseSHA+"..."+merge]
	cmp.Total = maxCompareCommits + 1
	f.compares[fork+"@"+baseSHA+"..."+merge] = cmp
	r := runCheck(f, tagPin())
	if r.Pass || !strings.Contains(failuresOf(r), "truncated") {
		t.Fatalf("want a compare over the limit to fail:\n%s", failuresOf(r))
	}
}

func TestIdenticalToUpstreamPasses(t *testing.T) {
	f := reviewedFork()
	f.compares[fork+"@"+baseSHA+"..."+baseSHA] = comparison{Status: "identical"}
	r := runCheck(f, pin{Repo: fork, Ref: "v0.16.5.vcluster.0", Tag: "v0.16.5.vcluster.0", Commit: baseSHA})
	if !r.Pass || len(r.Commits) != 0 {
		t.Fatalf("no fork commits means nothing to review: %+v\n%s", r, failuresOf(r))
	}
}

func TestMissingForkUpstreamFails(t *testing.T) {
	f := reviewedFork()
	delete(f.upstreams, fork)
	r := runCheck(f, tagPin())
	if r.Pass || r.ForkUpstreamSource != "missing" || len(r.Commits) != 0 {
		t.Fatalf("want a fork without fork-upstream to fail before any lookup: %+v", r)
	}
}

func TestOverrideKeepsEvidenceButStillFails(t *testing.T) {
	f := reviewedFork()
	delete(f.upstreams, fork)
	r := newChecker(f, time.Time{}, map[string]upstreamOverride{fork: {Repo: upstream}}).checkFork(context.Background(), tagPin())
	if r.Pass {
		t.Fatal("the missing property must fail even with an override")
	}
	if r.ForkUpstreamSource != "override" || len(r.Commits) != 3 {
		t.Fatalf("want per-commit evidence from the override: %+v", r)
	}
	for _, c := range r.Commits {
		if !c.Pass {
			t.Errorf("commit %s should pass on its own: %v", short(c.SHA), c.Failures)
		}
	}
}

func TestPropertyWinsOverOverride(t *testing.T) {
	f := reviewedFork()
	r := newChecker(f, time.Time{}, map[string]upstreamOverride{fork: {Repo: "evil/kine"}}).checkFork(context.Background(), tagPin())
	if r.ForkUpstream != upstream || r.ForkUpstreamSource != "property" || !r.Pass {
		t.Fatalf("the property must win: %+v", r)
	}
}

func TestCommitPinUsesMergeBase(t *testing.T) {
	// A pseudo-version pin: no tag, so the base is the merge base with the
	// upstream default branch.
	f := reviewedFork()
	f.repos[upstream] = repoInfo{FullName: upstream, DefaultBranch: "master"}
	f.compares[fork+"@k3s-io:master..."+merge] = comparison{Status: "diverged", Total: 3, MergeBase: baseSHA, Commits: f.compares[fork+"@"+baseSHA+"..."+merge].Commits}
	r := runCheck(f, pin{Repo: fork, Ref: "v0.0.0-20261001120000-dddddddddddd", Commit: merge})
	if !r.Pass {
		t.Fatalf("want pass:\n%s", failuresOf(r))
	}
	if r.Base.Rule != "merge-base" || r.Base.Commit != baseSHA || r.Base.Ref != upstream+"@master" {
		t.Errorf("base = %+v, want merge-base %s on %s@master", r.Base, baseSHA, upstream)
	}
}

func TestCommitPinHonoursUpstreamBranchOverride(t *testing.T) {
	f := reviewedFork()
	delete(f.upstreams, fork)
	f.compares[fork+"@k3s-io:release-1.0..."+merge] = comparison{Status: "diverged", Total: 0, MergeBase: merge}
	r := newChecker(f, time.Time{}, map[string]upstreamOverride{fork: {Repo: upstream, Ref: "release-1.0"}}).checkFork(context.Background(), pin{Repo: fork, Ref: merge, Commit: merge})
	if r.Base == nil || r.Base.Ref != upstream+"@release-1.0" {
		t.Fatalf("want the override branch as base ref: %+v", r)
	}
}
