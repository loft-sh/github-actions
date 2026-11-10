package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

const (
	unlinkedEmail = "carol@loft.sh"
	carolLogin    = "carol-gh"
)

// unlinkedAuthorFork is reviewedFork with c1 written under an email GitHub
// links to no account, so the compare returns no author login for it.
func unlinkedAuthorFork() *fakeAPI {
	f := reviewedFork()
	cmp := f.compares[fork+"@"+baseSHA+"..."+merge]
	cmp.Commits[0].Author = ""
	cmp.Commits[0].AuthorEmail = unlinkedEmail
	return f
}

func carolMap() identityMap {
	return identityMap{unlinkedEmail: {Email: unlinkedEmail, Login: carolLogin, Name: "Carol", Evidence: "https://github.com/loft-sh/kine/pull/1"}}
}

func runWithIdentities(f *fakeAPI, ids identityMap) forkResult {
	c := newChecker(f, time.Time{}, nil)
	c.identities = ids
	return c.checkFork(context.Background(), tagPin())
}

func TestUnlinkedAuthorWithoutMapEntryFails(t *testing.T) {
	r := runWithIdentities(unlinkedAuthorFork(), identityMap{})
	c := r.Commits[0]
	if r.Pass || c.Pass {
		t.Fatal("want a commit whose author links to no account and has no map entry to fail")
	}
	if !strings.Contains(c.Failures[0], identityMapFile) {
		t.Errorf("failure = %q, want it to name the identity map as the remedy", c.Failures[0])
	}
	if c.Author != "" || c.AuthorSource != "" || c.AuthorEmail != unlinkedEmail {
		t.Errorf("commit = %+v, want no author, no source and the email for the remedy", c)
	}
}

func TestMappedAuthorPasses(t *testing.T) {
	r := runWithIdentities(unlinkedAuthorFork(), carolMap())
	if !r.Pass {
		t.Fatalf("want pass:\n%s", failuresOf(r))
	}
	c := r.Commits[0]
	if c.Author != carolLogin || c.AuthorSource != identityMapSource || c.AuthorEmail != unlinkedEmail {
		t.Errorf("commit = %+v, want author %s from the identity map with its email", c, carolLogin)
	}
	if c.Approval == nil || c.Approval.Approver != "bob" {
		t.Errorf("approval = %+v, want bob", c.Approval)
	}
}

func TestMappedAuthorStillCannotApprove(t *testing.T) {
	// The map names bob as the author, so bob's approval is a self-review.
	f := unlinkedAuthorFork()
	ids := identityMap{unlinkedEmail: {Email: unlinkedEmail, Login: "bob", Name: "Bob", Evidence: "https://github.com/loft-sh/kine/pull/1"}}
	r := runWithIdentities(f, ids)
	c := r.Commits[0]
	if c.Pass {
		t.Fatal("want an approval by the mapped commit author to fail")
	}
	if !strings.Contains(c.Failures[0], "is by the commit author") {
		t.Errorf("failure = %q, want it to name the commit author", c.Failures[0])
	}
}

func TestMapLookupIgnoresEmailCase(t *testing.T) {
	f := unlinkedAuthorFork()
	f.compares[fork+"@"+baseSHA+"..."+merge].Commits[0].AuthorEmail = "Carol@Loft.SH"
	r := runWithIdentities(f, carolMap())
	if !r.Commits[0].Pass || r.Commits[0].Author != carolLogin {
		t.Fatalf("want the map to match regardless of email case: %+v", r.Commits[0])
	}
}

func TestLinkedLoginWinsOverMap(t *testing.T) {
	// GitHub links c1's email to alice; a map entry for the same email must
	// not rename her, or a map entry could hide a self-review.
	f := reviewedFork()
	f.compares[fork+"@"+baseSHA+"..."+merge].Commits[0].AuthorEmail = unlinkedEmail
	r := runWithIdentities(f, carolMap())
	c := r.Commits[0]
	if c.Author != "alice" || c.AuthorSource != "" || c.AuthorEmail != "" {
		t.Errorf("commit = %+v, want GitHub's login alice and no map source or email", c)
	}
}

func TestMappedAuthorOfReviewedTreeHead(t *testing.T) {
	// S is the PR's final head, written under an unlinked email.
	f := reviewedFork()
	f.tags[fork+"@"+tag] = head
	f.compares[fork+"@"+baseSHA+"..."+head] = comparison{Status: "ahead", Total: 1, Commits: []commitInfo{{SHA: head, AuthorEmail: unlinkedEmail, Subject: "fix review"}}}
	p := pin{Repo: fork, Ref: tag, Tag: tag, Commit: head}

	c := newChecker(f, time.Time{}, nil)
	c.identities = identityMap{}
	if r := c.checkFork(context.Background(), p); r.Pass || r.ReviewedTree.Pass {
		t.Fatalf("without a map entry the reviewed tree must fail: %+v", r.ReviewedTree)
	}

	c = newChecker(f, time.Time{}, nil)
	c.identities = carolMap()
	if r := c.checkFork(context.Background(), p); !r.Pass || r.ReviewedTree.Via != "head" {
		t.Fatalf("want the mapped head to be a reviewed tree:\n%s", failuresOf(r))
	}
}

func TestEmbeddedIdentityMapParses(t *testing.T) {
	m, err := parseIdentities(identitiesJSON)
	if err != nil {
		t.Fatal(err)
	}
	for email, id := range m {
		if email != strings.ToLower(id.Email) {
			t.Errorf("key %q does not match its lowercased email %q", email, id.Email)
		}
	}
	if len(defaultIdentities) != len(m) {
		t.Errorf("defaultIdentities has %d entries, the file has %d", len(defaultIdentities), len(m))
	}
}

func TestParseIdentitiesRejectsUnverifiableEntries(t *testing.T) {
	entry := func(email, login, name, evidence string) string {
		return `{"identities":[{"email":"` + email + `","login":"` + login + `","name":"` + name + `","evidence":"` + evidence + `"}]}`
	}
	ok := "https://github.com/loft-sh/kine/pull/1"
	cases := map[string]string{
		"not json":           `{`,
		"unknown field":      `{"identities":[{"email":"a@loft.sh","login":"a","name":"A","evidence":"` + ok + `","note":"x"}]}`,
		"bad email":          entry("not-an-email", "a", "A", ok),
		"display name":       entry("A <a@loft.sh>", "a", "A", ok),
		"empty login":        entry("a@loft.sh", "", "A", ok),
		"bad login":          entry("a@loft.sh", "-a", "A", ok),
		"long login":         entry("a@loft.sh", strings.Repeat("a", 40), "A", ok),
		"empty name":         entry("a@loft.sh", "a", " ", ok),
		"evidence elsewhere": entry("a@loft.sh", "a", "A", "https://example.com/a"),
		"duplicate email": `{"identities":[` +
			`{"email":"a@loft.sh","login":"a","name":"A","evidence":"` + ok + `"},` +
			`{"email":"A@loft.sh","login":"b","name":"B","evidence":"` + ok + `"}]}`,
	}
	for name, doc := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := parseIdentities([]byte(doc)); err == nil {
				t.Errorf("want %s to be rejected", name)
			}
		})
	}
	if _, err := parseIdentities([]byte(entry("a@loft.sh", "a-b", "A", ok))); err != nil {
		t.Errorf("want a valid entry to parse: %v", err)
	}
}

func TestReportsLabelMappedAndUnlinkedAuthors(t *testing.T) {
	mapped := commitResult{SHA: c1, Author: carolLogin, AuthorEmail: unlinkedEmail, AuthorSource: identityMapSource, Subject: "add kerberos"}
	unlinked := commitResult{SHA: c2, AuthorEmail: unlinkedEmail, Subject: "fix"}
	linked := commitResult{SHA: head, Author: "alice", Subject: "fix review"}
	rc := receipt{Forks: []forkResult{{Repo: fork, Ref: tag, Commit: merge, Commits: []commitResult{mapped, unlinked, linked}}}}
	for name, out := range map[string]string{"text": renderText(rc), "markdown": renderMarkdown(rc)} {
		for _, want := range []string{carolLogin + " (identity map: " + unlinkedEmail + ")", "none (" + unlinkedEmail + ")", "alice"} {
			if !strings.Contains(out, want) {
				t.Errorf("%s report lacks %q:\n%s", name, want, out)
			}
		}
	}
}
