package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/google/go-github/v88/github"
)

// forkUpstreamProperty is the org custom property that names a fork's
// upstream repository. Only org actors can set it, so a repo admin cannot
// point the check at a different upstream.
const forkUpstreamProperty = "fork-upstream"

type repoInfo struct {
	FullName      string
	DefaultBranch string
	Fork          bool
}

type commitInfo struct {
	SHA       string
	Author    string // GitHub login of the git author; empty when the email maps to no account
	Committer string // GitHub login of the committer
	Verified  bool   // GitHub's verification result for the commit signature
	Subject   string
	Merge     bool
}

type comparison struct {
	Status    string
	Total     int
	MergeBase string
	Commits   []commitInfo
}

type pullInfo struct {
	Number      int
	URL         string
	Author      string
	BaseRepo    string
	HeadSHA     string
	MergeCommit string
	MergedAt    time.Time // zero when the pull request is not merged
}

type reviewInfo struct {
	User        string
	State       string
	CommitID    string
	SubmittedAt time.Time
}

// forkAPI is the read-only GitHub surface the rules need.
type forkAPI interface {
	Repo(ctx context.Context, repo string) (repoInfo, error)
	// ForkUpstream returns the fork-upstream property, or "" when it is unset.
	ForkUpstream(ctx context.Context, repo string) (string, error)
	// ResolveTag returns the commit a tag points to, or "" when the tag does not exist.
	ResolveTag(ctx context.Context, repo, tag string) (string, error)
	Compare(ctx context.Context, repo, base, head string) (comparison, error)
	PullsWithCommit(ctx context.Context, repo, sha string) ([]pullInfo, error)
	Reviews(ctx context.Context, repo string, number int) ([]reviewInfo, error)
	// LastForcePush returns when the pull request head was last force-pushed, or zero.
	LastForcePush(ctx context.Context, repo string, number int) (time.Time, error)
	// Permission returns the collaborator permission: admin, write, read or none.
	Permission(ctx context.Context, repo, user string) (string, error)
}

type githubAPI struct {
	gh *github.Client
}

func splitRepo(repo string) (string, string) {
	owner, name, _ := strings.Cut(repo, "/")
	return owner, name
}

func (a githubAPI) Repo(ctx context.Context, repo string) (repoInfo, error) {
	owner, name := splitRepo(repo)
	r, _, err := a.gh.Repositories.Get(ctx, owner, name)
	if err != nil {
		return repoInfo{}, err
	}
	return repoInfo{FullName: r.GetFullName(), DefaultBranch: r.GetDefaultBranch(), Fork: r.GetFork()}, nil
}

func (a githubAPI) ForkUpstream(ctx context.Context, repo string) (string, error) {
	owner, name := splitRepo(repo)
	values, _, err := a.gh.Repositories.GetAllCustomPropertyValues(ctx, owner, name)
	if err != nil {
		return "", err
	}
	for _, v := range values {
		if v.PropertyName != forkUpstreamProperty {
			continue
		}
		if s, ok := v.Value.(string); ok {
			return strings.TrimSpace(s), nil
		}
	}
	return "", nil
}

func (a githubAPI) ResolveTag(ctx context.Context, repo, tag string) (string, error) {
	owner, name := splitRepo(repo)
	ref, _, err := a.gh.Git.GetRef(ctx, owner, name, "tags/"+tag)
	if isNotFound(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	obj := ref.GetObject()
	// Annotated tags point at a tag object; peel until a commit.
	for obj.GetType() == "tag" {
		t, _, err := a.gh.Git.GetTag(ctx, owner, name, obj.GetSHA())
		if err != nil {
			return "", err
		}
		obj = t.GetObject()
	}
	if obj.GetType() != "commit" {
		return "", fmt.Errorf("tag %s points to a %s, not a commit", tag, obj.GetType())
	}
	return obj.GetSHA(), nil
}

func (a githubAPI) Compare(ctx context.Context, repo, base, head string) (comparison, error) {
	owner, name := splitRepo(repo)
	var out comparison
	opts := &github.ListOptions{PerPage: 100}
	for {
		cmp, resp, err := a.gh.Repositories.CompareCommits(ctx, owner, name, base, head, opts)
		if err != nil {
			return comparison{}, err
		}
		if opts.Page == 0 {
			out.Status = cmp.GetStatus()
			out.Total = cmp.GetTotalCommits()
			out.MergeBase = cmp.GetMergeBaseCommit().GetSHA()
			if out.Total > maxCompareCommits {
				return out, nil
			}
		}
		for _, rc := range cmp.Commits {
			out.Commits = append(out.Commits, commitInfo{
				SHA:       rc.GetSHA(),
				Author:    rc.GetAuthor().GetLogin(),
				Committer: rc.GetCommitter().GetLogin(),
				Verified:  rc.GetCommit().GetVerification().GetVerified(),
				Subject:   firstLine(rc.GetCommit().GetMessage()),
				Merge:     len(rc.Parents) > 1,
			})
		}
		if resp.NextPage == 0 {
			return out, nil
		}
		opts.Page = resp.NextPage
	}
}

func (a githubAPI) PullsWithCommit(ctx context.Context, repo, sha string) ([]pullInfo, error) {
	owner, name := splitRepo(repo)
	var out []pullInfo
	opts := &github.ListOptions{PerPage: 100}
	for {
		prs, resp, err := a.gh.PullRequests.ListPullRequestsWithCommit(ctx, owner, name, sha, opts)
		if err != nil {
			return nil, err
		}
		for _, pr := range prs {
			out = append(out, pullInfo{
				Number:      pr.GetNumber(),
				URL:         pr.GetHTMLURL(),
				Author:      pr.GetUser().GetLogin(),
				BaseRepo:    pr.GetBase().GetRepo().GetFullName(),
				HeadSHA:     pr.GetHead().GetSHA(),
				MergeCommit: pr.GetMergeCommitSHA(),
				MergedAt:    pr.GetMergedAt().Time,
			})
		}
		if resp.NextPage == 0 {
			return out, nil
		}
		opts.Page = resp.NextPage
	}
}

func (a githubAPI) Reviews(ctx context.Context, repo string, number int) ([]reviewInfo, error) {
	owner, name := splitRepo(repo)
	var out []reviewInfo
	opts := &github.ListOptions{PerPage: 100}
	for {
		reviews, resp, err := a.gh.PullRequests.ListReviews(ctx, owner, name, number, opts)
		if err != nil {
			return nil, err
		}
		for _, r := range reviews {
			out = append(out, reviewInfo{
				User:        r.GetUser().GetLogin(),
				State:       r.GetState(),
				CommitID:    r.GetCommitID(),
				SubmittedAt: r.GetSubmittedAt().Time,
			})
		}
		if resp.NextPage == 0 {
			return out, nil
		}
		opts.Page = resp.NextPage
	}
}

func (a githubAPI) LastForcePush(ctx context.Context, repo string, number int) (time.Time, error) {
	owner, name := splitRepo(repo)
	var last time.Time
	opts := &github.ListOptions{PerPage: 100}
	for {
		events, resp, err := a.gh.Issues.ListIssueTimeline(ctx, owner, name, number, opts)
		if err != nil {
			return time.Time{}, err
		}
		for _, e := range events {
			if e.GetEvent() == "head_ref_force_pushed" && e.GetCreatedAt().After(last) {
				last = e.GetCreatedAt().Time
			}
		}
		if resp.NextPage == 0 {
			return last, nil
		}
		opts.Page = resp.NextPage
	}
}

func (a githubAPI) Permission(ctx context.Context, repo, user string) (string, error) {
	owner, name := splitRepo(repo)
	p, _, err := a.gh.Repositories.GetPermissionLevel(ctx, owner, name, user)
	if err != nil {
		return "", err
	}
	return p.GetPermission(), nil
}

func isNotFound(err error) bool {
	var ghErr *github.ErrorResponse
	return errors.As(err, &ghErr) && ghErr.Response != nil && ghErr.Response.StatusCode == http.StatusNotFound
}

func firstLine(s string) string {
	line, _, _ := strings.Cut(s, "\n")
	return strings.TrimSpace(line)
}
