package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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

func TestLineFromVersionString(t *testing.T) {
	cases := map[string]string{
		"0.33.5":                 "0.33",
		"v0.33.5":                "0.33",
		"0.33.5 - Security Only": "0.33", // release name with a suffix
		"v1.2.3":                 "1.2",
		"4.2":                    "4.2",
		"  0.34.1":               "0.34", // leading whitespace
		"abc123":                 "",     // short commit hash
		"Security Only 0.33.5":   "",     // version must lead the string
		"":                       "",
		"v1":                     "",
	}
	for in, want := range cases {
		if got := lineFromVersionString(in); got != want {
			t.Errorf("lineFromVersionString(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestReleaseLine(t *testing.T) {
	cases := []struct {
		name    string
		release releaseRef
		want    string
	}{
		{"version field wins", releaseRef{Name: "0.35.0 - wrong", Version: "0.33.5"}, "0.33"},
		{"version field with v prefix", releaseRef{Name: "", Version: "v1.2.3"}, "1.2"},
		{"name fallback when version unset", releaseRef{Name: "0.33.5", Version: ""}, "0.33"},
		{"security-only suffix in name", releaseRef{Name: "0.33.5 - Security Only", Version: ""}, "0.33"},
		{"name fallback when version unparseable", releaseRef{Name: "0.34.2", Version: "abc123"}, "0.34"},
		{"neither parseable", releaseRef{Name: "Q3 hardening", Version: "abc123"}, ""},
		{"both empty", releaseRef{}, ""},
	}
	for _, c := range cases {
		if got := releaseLine(c.release); got != c.want {
			t.Errorf("%s: releaseLine(%+v) = %q, want %q", c.name, c.release, got, c.want)
		}
	}
}

func TestVerifyReleaseAttachment(t *testing.T) {
	sub := issueRef{ID: "uuid-913", Identifier: "ENGCP-913", Title: "[0.33] Copy of ENGCP-906"}

	cases := []struct {
		name       string
		releases   []releaseRef
		line       string
		wantWarn   bool
		wantRemedy string // substring the remedy must contain, when warning
	}{
		{
			name:       "no release attached warns with attach remedy",
			releases:   nil,
			line:       "0.33",
			wantWarn:   true,
			wantRemedy: "attach the 0.33 line's In Progress release to ENGCP-913",
		},
		{
			name:       "mismatched release line warns",
			releases:   []releaseRef{{Name: "0.34.2", Version: "0.34.2"}},
			line:       "0.33",
			wantWarn:   true,
			wantRemedy: "attach the 0.33 release to ENGCP-913",
		},
		{
			name:     "matching release via version field is silent",
			releases: []releaseRef{{Name: "0.33.5 - Security Only", Version: "0.33.5"}},
			line:     "0.33",
			wantWarn: false,
		},
		{
			name:     "matching release via name fallback is silent",
			releases: []releaseRef{{Name: "0.33.5 - Security Only", Version: ""}},
			line:     "0.33",
			wantWarn: false,
		},
		{
			name:     "any matching release among several is silent",
			releases: []releaseRef{{Name: "0.34.0"}, {Name: "0.33.5"}},
			line:     "0.33",
			wantWarn: false,
		},
		{
			name:       "unparseable release still warns on mismatch",
			releases:   []releaseRef{{Name: "Q3 hardening", Version: "abc123"}},
			line:       "0.33",
			wantWarn:   true,
			wantRemedy: "fix the sub-issue title",
		},
	}
	for _, c := range cases {
		w := verifyReleaseAttachment(sub, c.releases, c.line, "v"+c.line)
		if got := w != nil; got != c.wantWarn {
			t.Errorf("%s: warning = %v, want %v (warning: %+v)", c.name, got, c.wantWarn, w)
			continue
		}
		if w == nil {
			continue
		}
		if !strings.Contains(w.remedy, c.wantRemedy) {
			t.Errorf("%s: remedy %q does not contain %q", c.name, w.remedy, c.wantRemedy)
		}
		if !strings.Contains(w.problem, "ENGCP-913") {
			t.Errorf("%s: problem %q should name the sub-issue", c.name, w.problem)
		}
		if strings.Contains(w.annotation(), "\n") {
			t.Errorf("%s: annotation must be single-line, got %q", c.name, w.annotation())
		}
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

func TestRemedyWarningRendering(t *testing.T) {
	w := remedyWarning{problem: "no backport PR found for X", remedy: "backport X manually"}

	// The annotation is a single line so GitHub renders it as one ::warning::.
	got := w.annotation()
	want := "no backport PR found for X. Remedy: backport X manually"
	if got != want {
		t.Errorf("annotation() = %q, want %q", got, want)
	}
	if strings.Contains(got, "\n") {
		t.Errorf("annotation() must be single-line, got %q", got)
	}

	// The summary line is a markdown bullet naming the remedy.
	line := w.summaryLine()
	if !strings.HasPrefix(line, "- ") {
		t.Errorf("summaryLine() should be a markdown bullet, got %q", line)
	}
	if !strings.Contains(line, w.problem) || !strings.Contains(line, w.remedy) {
		t.Errorf("summaryLine() should name both problem and remedy, got %q", line)
	}
	if !strings.Contains(line, "Remedy:") {
		t.Errorf("summaryLine() should label the remedy, got %q", line)
	}
}

func TestWriteLinkedCount(t *testing.T) {
	path := filepath.Join(t.TempDir(), "output")
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GITHUB_OUTPUT", path)

	writeLinkedCount(3)

	got := readFile(t, path)
	if got != "linked-count=3\n" {
		t.Errorf("GITHUB_OUTPUT = %q, want %q", got, "linked-count=3\n")
	}
}

func TestWriteLinkedCountZeroOnSkip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "output")
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GITHUB_OUTPUT", path)

	// A skip path publishes 0 so callers always read a number.
	writeLinkedCount(0)

	if got := readFile(t, path); got != "linked-count=0\n" {
		t.Errorf("GITHUB_OUTPUT = %q, want %q", got, "linked-count=0\n")
	}
}

func TestSummaryfAppends(t *testing.T) {
	path := filepath.Join(t.TempDir(), "summary")
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GITHUB_STEP_SUMMARY", path)

	summaryf("- first")
	summaryf("- second")

	if got := readFile(t, path); got != "- first\n- second\n" {
		t.Errorf("GITHUB_STEP_SUMMARY = %q, want %q", got, "- first\n- second\n")
	}
}

func TestAppendToEnvFileUnsetIsNoop(t *testing.T) {
	// When the variable is unset (a local run, no Actions environment), writing
	// must be a harmless no-op, never a panic or error.
	t.Setenv("GITHUB_OUTPUT", "")
	if err := os.Unsetenv("GITHUB_OUTPUT"); err != nil {
		t.Fatal(err)
	}
	writeLinkedCount(1) // must not panic
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}
