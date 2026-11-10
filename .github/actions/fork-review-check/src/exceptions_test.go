package main

import (
	"context"
	"regexp"
	"strings"
	"testing"
	"time"
)

const testRecord = "https://github.com/loft-sh/architecture/blob/main/engineering-enablement/designs/fork-review-check.md#dated-exceptions"

// unlinkedAuthorFork is reviewedFork with c1 written under an email GitHub
// links to no account, so the compare returns no author login for it. alice
// still committed it.
func unlinkedAuthorFork() *fakeAPI {
	f := reviewedFork()
	f.compares[fork+"@"+baseSHA+"..."+merge].Commits[0].Author = ""
	return f
}

func c1Exception(number int) exceptionList {
	return exceptionList{exceptionKey(fork, c1): {Repo: fork, Commit: c1, Pull: number, Record: testRecord}}
}

func runWithExceptions(f *fakeAPI, l exceptionList, p pin) forkResult {
	c := newChecker(f, time.Time{}, nil)
	c.exceptions = l
	return c.checkFork(context.Background(), p)
}

func TestUnlinkedAuthorWithoutExceptionFails(t *testing.T) {
	r := runWithExceptions(unlinkedAuthorFork(), exceptionList{}, tagPin())
	c := r.Commits[0]
	if r.Pass || c.Pass {
		t.Fatal("want a commit whose author links to no account to fail without an exception")
	}
	if !strings.Contains(c.Failures[0], exceptionsFile) {
		t.Errorf("failure = %q, want it to name the exception list as the remedy", c.Failures[0])
	}
}

func TestExceptionLetsUnlinkedAuthorPass(t *testing.T) {
	r := runWithExceptions(unlinkedAuthorFork(), c1Exception(22), tagPin())
	if !r.Pass {
		t.Fatalf("want pass:\n%s", failuresOf(r))
	}
	c := r.Commits[0]
	if c.Approval == nil || c.Approval.Approver != "bob" || c.Approval.Exception != testRecord {
		t.Errorf("approval = %+v, want bob counted under %s", c.Approval, testRecord)
	}
	for _, other := range r.Commits[1:] {
		if other.Approval == nil || other.Approval.Exception != "" {
			t.Errorf("commit %s approval = %+v, want no exception on a linked author", short(other.SHA), other.Approval)
		}
	}
}

func TestExceptionAppliesOnlyToItsPull(t *testing.T) {
	r := runWithExceptions(unlinkedAuthorFork(), c1Exception(23), tagPin())
	if r.Commits[0].Pass {
		t.Fatal("an exception for another pull request must not count")
	}
}

func TestExceptionAppliesOnlyToItsRepo(t *testing.T) {
	other := exceptionList{exceptionKey("loft-sh/tailscale", c1): {Repo: "loft-sh/tailscale", Commit: c1, Pull: 22, Record: testRecord}}
	r := runWithExceptions(unlinkedAuthorFork(), other, tagPin())
	if r.Commits[0].Pass {
		t.Fatal("an exception for the same SHA in another fork must not count")
	}
}

func TestExceptionNeedsCommitterOtherThanApprover(t *testing.T) {
	for name, committer := range map[string]string{"approver": "bob", "unlinked": ""} {
		t.Run(name, func(t *testing.T) {
			f := unlinkedAuthorFork()
			f.compares[fork+"@"+baseSHA+"..."+merge].Commits[0].Committer = committer
			r := runWithExceptions(f, c1Exception(22), tagPin())
			c := r.Commits[0]
			if c.Pass {
				t.Fatalf("committer %q: want the exception to be refused", committer)
			}
			if !strings.Contains(c.Failures[0], "committer") {
				t.Errorf("failure = %q, want it to name the committer", c.Failures[0])
			}
		})
	}
}

func TestExceptionDoesNotCoverLinkedAuthor(t *testing.T) {
	// GitHub links c1 to bob, so bob's approval is a self-review whatever
	// the exception list says.
	f := reviewedFork()
	f.compares[fork+"@"+baseSHA+"..."+merge].Commits[0].Author = "bob"
	r := runWithExceptions(f, c1Exception(22), tagPin())
	if r.Commits[0].Pass {
		t.Fatal("an exception must not waive the check on a linked commit author")
	}
}

func TestExceptionKeepsOtherConditions(t *testing.T) {
	f := unlinkedAuthorFork()
	f.forcePush[fork+"#22"] = t0.Add(90 * time.Minute)
	r := runWithExceptions(f, c1Exception(22), tagPin())
	if r.Commits[0].Pass {
		t.Fatal("an approval before the last force push must still fail under an exception")
	}
	if !strings.Contains(r.Commits[0].Failures[0], "force push") {
		t.Errorf("failure = %q, want the force push named", r.Commits[0].Failures[0])
	}
}

func TestExceptionForReviewedTreeHead(t *testing.T) {
	// S is the PR's final head, written under an unlinked email.
	f := reviewedFork()
	f.tags[fork+"@"+tag] = head
	f.compares[fork+"@"+baseSHA+"..."+head] = comparison{Status: "ahead", Total: 1, Commits: []commitInfo{{SHA: head, Committer: "alice", Subject: "fix review"}}}
	p := pin{Repo: fork, Ref: tag, Tag: tag, Commit: head}
	if r := runWithExceptions(f, exceptionList{}, p); r.Pass || r.ReviewedTree.Pass {
		t.Fatalf("without an exception the reviewed tree must fail: %+v", r.ReviewedTree)
	}
	l := exceptionList{exceptionKey(fork, head): {Repo: fork, Commit: head, Pull: 22, Record: testRecord}}
	if r := runWithExceptions(f, l, p); !r.Pass || r.ReviewedTree.Via != "head" {
		t.Fatalf("want the excepted head to be a reviewed tree:\n%s", failuresOf(r))
	}
}

func TestEmbeddedExceptionsParseAndCarryNoPersonalData(t *testing.T) {
	l, err := parseExceptions(exceptionsJSON)
	if err != nil {
		t.Fatal(err)
	}
	if len(defaultExceptions) != len(l) {
		t.Errorf("defaultExceptions has %d entries, the file has %d", len(defaultExceptions), len(l))
	}
	// This repository is public: the justification, with any names, lives
	// in the private record, never here.
	if m := regexp.MustCompile(`[^\s"]+@[^\s"]+\.[a-z]+`).Find(exceptionsJSON); m != nil {
		t.Errorf("%s contains an email address %q; keep personal data in the private record", exceptionsFile, m)
	}
}

func TestParseExceptionsRejectsMalformedEntries(t *testing.T) {
	object := func(repo, commit, pull, record string) string {
		return `{"repo":"` + repo + `","commit":"` + commit + `","pull":` + pull + `,"record":"` + record + `"}`
	}
	entry := func(repo, commit, pull, record string) string {
		return `{"exceptions":[` + object(repo, commit, pull, record) + `]}`
	}
	cases := map[string]string{
		"not json":        `{`,
		"unknown field":   `{"exceptions":[{"repo":"` + fork + `","commit":"` + c1 + `","pull":22,"record":"` + testRecord + `","author":"x"}]}`,
		"bad repo":        entry("kine", c1, "22", testRecord),
		"short sha":       entry(fork, c1[:12], "22", testRecord),
		"uppercase sha":   entry(fork, strings.ToUpper("abcdef"+c1[6:]), "22", testRecord),
		"no pull":         entry(fork, c1, "0", testRecord),
		"public record":   entry(fork, c1, "22", "https://github.com/loft-sh/github-actions/issues/1"),
		"duplicate entry": `{"exceptions":[` + object(fork, c1, "22", testRecord) + `,` + object(fork, c1, "23", testRecord) + `]}`,
	}
	for name, doc := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := parseExceptions([]byte(doc)); err == nil {
				t.Errorf("want %s to be rejected", name)
			}
		})
	}
	if _, err := parseExceptions([]byte(entry(fork, c1, "22", testRecord))); err != nil {
		t.Errorf("want a valid entry to parse: %v", err)
	}
}

func TestReportsMarkExceptionApprovals(t *testing.T) {
	r := runWithExceptions(unlinkedAuthorFork(), c1Exception(22), tagPin())
	rc := receipt{Pass: r.Pass, Forks: []forkResult{r}}
	if out := renderText(rc); !strings.Contains(out, "dated exception "+testRecord) {
		t.Errorf("text report does not mark the exception:\n%s", out)
	}
	if out := renderMarkdown(rc); !strings.Contains(out, "bob ([dated exception]("+testRecord+"))") {
		t.Errorf("markdown report does not mark the exception:\n%s", out)
	}
}
