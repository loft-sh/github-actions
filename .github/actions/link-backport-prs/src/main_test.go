package main

import "testing"

func TestVersionFromBranch(t *testing.T) {
	cases := map[string]string{
		"v0.34":        "0.34",
		"v0.35":        "0.35",
		"0.34":         "0.34",
		"release-4.2":  "4.2",
		"release-v4.2": "4.2",
		"main":         "",
		"":             "",
		"v1":           "",
	}
	for in, want := range cases {
		if got := versionFromBranch(in); got != want {
			t.Errorf("versionFromBranch(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestBackportHeadBranch(t *testing.T) {
	if got := backportHeadBranch("v0.34", 3993); got != "backport/v0.34/pr-3993" {
		t.Errorf("got %q", got)
	}
	if got := backportHeadBranch("release-4.2", 12); got != "backport/release-4.2/pr-12" {
		t.Errorf("got %q", got)
	}
}

func TestTitleMatchesVersion(t *testing.T) {
	cases := []struct {
		title, version string
		want           bool
	}{
		{"[0.34] Copy of ENGCP-906", "0.34", true},  // real-world format, no v
		{"[v0.34] Copy of ENGCP-906", "0.34", true}, // spec format, with v
		{"  [0.34] padded", "0.34", true},
		{"[0.35] Copy of ENGCP-906", "0.34", false},
		{"[0.3] something", "0.34", false},          // prefix must not partial-match
		{"[0.34] x", "0.3", false},                  // 0.3 must not match [0.34]
		{"Copy of ENGCP-906 [0.34]", "0.34", false}, // prefix must be at start
		{"QA for ENGCP-906", "0.34", false},
		{"[0.34] x", "", false},
	}
	for _, c := range cases {
		if got := titleMatchesVersion(c.title, c.version); got != c.want {
			t.Errorf("titleMatchesVersion(%q, %q) = %v, want %v", c.title, c.version, got, c.want)
		}
	}
}

func TestMatchSubIssue(t *testing.T) {
	candidates := []issueRef{
		{Identifier: "ENGCP-906", Title: "[Bug] HA vCluster ExternalSecrets CRD sync race"},
		{Identifier: "ENGCP-913", Title: "[0.34] Copy of ENGCP-906"},
		{Identifier: "ENGCP-943", Title: "[0.35] Copy of ENGCP-906"},
		{Identifier: "ENGQA-1102", Title: "QA for ENGCP-906"},
	}
	got, ok := matchSubIssue(candidates, "0.34")
	if !ok || got.Identifier != "ENGCP-913" {
		t.Fatalf("0.34 -> %+v, ok=%v; want ENGCP-913", got, ok)
	}
	got, ok = matchSubIssue(candidates, "0.35")
	if !ok || got.Identifier != "ENGCP-943" {
		t.Fatalf("0.35 -> %+v, ok=%v; want ENGCP-943", got, ok)
	}
	if _, ok := matchSubIssue(candidates, "0.33"); ok {
		t.Errorf("0.33 should not match any candidate")
	}
}

func TestFamilyCandidates(t *testing.T) {
	// Attached issue is the parent: its own children are the [X.Y] copies.
	parentAttached := issueFamily{
		issueWithChildren: issueWithChildren{
			issueRef: issueRef{Identifier: "ENGCP-906", Title: "[Bug] ..."},
		},
	}
	parentAttached.Children.Nodes = []issueRef{
		{Identifier: "ENGCP-913", Title: "[0.34] Copy of ENGCP-906"},
	}
	cands := familyCandidates(parentAttached)
	if len(cands) != 2 || cands[0].Identifier != "ENGCP-906" || cands[1].Identifier != "ENGCP-913" {
		t.Fatalf("parent-attached candidates = %+v", cands)
	}

	// Attached issue is a sub-issue: the [X.Y] copies are siblings under parent.
	child := issueWithChildren{issueRef: issueRef{Identifier: "ENGCP-940", Title: "[main] Copy of ENGCP-906"}}
	parent := &issueWithChildren{issueRef: issueRef{Identifier: "ENGCP-906", Title: "[Bug] ..."}}
	parent.Children.Nodes = []issueRef{
		{Identifier: "ENGCP-913", Title: "[0.34] Copy of ENGCP-906"},
		{Identifier: "ENGCP-940", Title: "[main] Copy of ENGCP-906"},
	}
	subAttached := issueFamily{issueWithChildren: child, Parent: parent}
	cands = familyCandidates(subAttached)
	if got, ok := matchSubIssue(cands, "0.34"); !ok || got.Identifier != "ENGCP-913" {
		t.Fatalf("sibling match = %+v ok=%v; want ENGCP-913", got, ok)
	}
}

func TestBodyReferencesIssue(t *testing.T) {
	cases := []struct {
		body, id string
		want     bool
	}{
		{"Fixes ENGCP-913", "ENGCP-913", true},
		{"fixes ENGCP-913", "ENGCP-913", true},
		{"Closes ENGCP-913", "ENGCP-913", true},
		{"resolved ENGCP-913", "ENGCP-913", true},
		{"Fixes #ENGCP-913", "ENGCP-913", true},
		{"some text\nFixes ENGCP-913\nmore", "ENGCP-913", true},
		{"Fixes ENGCP-9131", "ENGCP-913", false}, // word boundary
		{"mentions ENGCP-913 without keyword", "ENGCP-913", false},
		{"", "ENGCP-913", false},
		{"Fixes ENGCP-913", "ENGCP-943", false},
	}
	for _, c := range cases {
		if got := bodyReferencesIssue(c.body, c.id); got != c.want {
			t.Errorf("bodyReferencesIssue(%q, %q) = %v, want %v", c.body, c.id, got, c.want)
		}
	}
}

func TestAppendFixes(t *testing.T) {
	if got := appendFixes("", "ENGCP-913"); got != "Fixes ENGCP-913" {
		t.Errorf("empty body -> %q", got)
	}
	if got := appendFixes("Backport of #3993", "ENGCP-913"); got != "Backport of #3993\n\nFixes ENGCP-913" {
		t.Errorf("got %q", got)
	}
	if got := appendFixes("Backport of #3993\n\n", "ENGCP-913"); got != "Backport of #3993\n\nFixes ENGCP-913" {
		t.Errorf("trailing newlines -> %q", got)
	}
}

func TestExtractIdentifier(t *testing.T) {
	if got := extractIdentifier("ENGCP-906"); got != "ENGCP-906" {
		t.Errorf("branch-as-id -> %q", got)
	}
	if got := extractIdentifier("eng-906/some-slug"); got != "ENG-906" {
		t.Errorf("lowercase branch -> %q", got)
	}
	if got := extractIdentifier("no ref here", "Closes DEVOPS-12 in body"); got != "DEVOPS-12" {
		t.Errorf("body fallback -> %q", got)
	}
	if got := extractIdentifier("gwapi-p0s-v2", ""); got != "" {
		t.Errorf("no identifier -> %q", got)
	}
}

func TestBackportTargetsFromNames(t *testing.T) {
	got := backportTargetsFromNames(
		[]string{"backport-to-v0.34", "area/ci", "backport-to-v0.35", "backport-to-main"},
		"backport-to-",
	)
	want := []string{"v0.34", "v0.35", "main"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}
