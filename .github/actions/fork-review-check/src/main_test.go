package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestRefModeResolvesTag(t *testing.T) {
	rc, err := check(context.Background(), reviewedFork(), nil, options{mode: "ref", repo: fork, ref: tag}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if !rc.Pass || len(rc.Forks) != 1 || rc.Forks[0].Commit != merge {
		t.Fatalf("want one passing fork at %s: %+v", merge, rc)
	}
	if rc.Inputs[0].Kind != "fork-ref" || rc.Inputs[0].Commit != merge {
		t.Errorf("input = %+v", rc.Inputs[0])
	}
}

func TestRefModeAcceptsFullSHA(t *testing.T) {
	f := reviewedFork()
	f.repos[upstream] = repoInfo{FullName: upstream, DefaultBranch: "master"}
	f.compares[fork+"@k3s-io:master..."+merge] = comparison{Status: "diverged", Total: 3, MergeBase: baseSHA, Commits: f.compares[fork+"@"+baseSHA+"..."+merge].Commits}
	sha := merge
	rc, err := check(context.Background(), f, nil, options{mode: "ref", repo: fork, ref: sha}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if !rc.Pass || rc.Forks[0].Base.Rule != "merge-base" {
		t.Fatalf("want a commit pin on the merge-base rule: %+v", rc.Forks)
	}
}

func TestRefModeUnknownRefFails(t *testing.T) {
	rc, err := check(context.Background(), reviewedFork(), nil, options{mode: "ref", repo: fork, ref: "v9.9.9"}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if rc.Pass || len(rc.Failures) != 1 {
		t.Fatalf("want an unresolvable ref to fail: %+v", rc)
	}
}

func TestAsOfFlagAppliesRule3(t *testing.T) {
	rc, err := check(context.Background(), reviewedFork(), nil, options{mode: "ref", repo: fork, ref: tag, asOf: t0.Add(30 * time.Minute).Format(time.RFC3339)}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if rc.Pass || rc.AsOf == nil {
		t.Fatalf("want rule 3 to fail and as_of recorded: %+v", rc)
	}
}

func TestParseArgs(t *testing.T) {
	if _, err := parseArgs([]string{"ref", "-repo", fork}); err == nil {
		t.Error("ref mode without -ref must fail")
	}
	if _, err := parseArgs([]string{"image"}); err == nil {
		t.Error("an unknown mode must fail")
	}
	o, err := parseArgs([]string{"go"})
	if err != nil || len(o.dirs) != 1 || o.dirs[0] != "." {
		t.Errorf("go mode defaults to the current directory: %+v %v", o, err)
	}
}

func TestParseUpstreams(t *testing.T) {
	got, err := parseUpstreams([]string{"k3s-io/kine", "loft-sh/fuse=nestybox/fuse@master"}, fork)
	if err != nil {
		t.Fatal(err)
	}
	if got[fork].Repo != upstream || got["loft-sh/fuse"].Ref != "master" {
		t.Errorf("overrides = %+v", got)
	}
	if _, err := parseUpstreams([]string{"kine"}, ""); err == nil {
		t.Error("a bare upstream outside ref mode must fail")
	}
}

func TestReportsNameFailures(t *testing.T) {
	f := reviewedFork()
	delete(f.pulls, fork+"@"+c1)
	rc, _ := check(context.Background(), f, nil, options{mode: "ref", repo: fork, ref: tag}, time.Now())
	text, md := renderText(rc), renderMarkdown(rc)
	for _, want := range []string{"FAIL", short(c1), "direct push"} {
		if !strings.Contains(text, want) || !strings.Contains(md, want) {
			t.Errorf("reports miss %q:\n%s\n%s", want, text, md)
		}
	}
}
