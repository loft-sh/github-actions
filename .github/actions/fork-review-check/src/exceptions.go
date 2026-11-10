package main

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// exceptionsFile is the reviewed exception list, named in failures as the remedy.
const exceptionsFile = ".github/actions/fork-review-check/src/exceptions.json"

// exceptionRecordPrefix is where the justification for every exception lives:
// the design's dated exceptions, in a private repository, so this public list
// carries no personal data.
const exceptionRecordPrefix = "https://github.com/loft-sh/architecture/"

//go:embed exceptions.json
var exceptionsJSON []byte

var repoNameRe = regexp.MustCompile(`^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$`)

// authorException is a dated exception for one shipped fork commit whose
// author email links to no GitHub account, so the check cannot show that an
// approver is not its author. It applies only to an approval on Pull, and it
// waives only that one condition: every other part of rule 2 still holds.
type authorException struct {
	Repo   string `json:"repo"`
	Commit string `json:"commit"`
	Pull   int    `json:"pull"`
	Record string `json:"record"`
}

// exceptionList is keyed by lowercased repo and commit SHA.
type exceptionList map[string]authorException

func exceptionKey(repo, sha string) string {
	return strings.ToLower(repo) + "@" + strings.ToLower(sha)
}

// defaultExceptions is the list compiled into the binary. It ships with the
// action at the caller's pinned ref, so a caller cannot add or change one.
var defaultExceptions = mustParseExceptions(exceptionsJSON)

func mustParseExceptions(data []byte) exceptionList {
	l, err := parseExceptions(data)
	if err != nil {
		panic(fmt.Sprintf("%s: %v", exceptionsFile, err))
	}
	return l
}

// parseExceptions reads the exception list and rejects any entry that does
// not name one fork commit, the pull request whose approval it applies to,
// and the record that justifies it.
func parseExceptions(data []byte) (exceptionList, error) {
	var doc struct {
		Exceptions []authorException `json:"exceptions"`
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&doc); err != nil {
		return nil, fmt.Errorf("parse exceptions: %w", err)
	}
	l := exceptionList{}
	for i, e := range doc.Exceptions {
		switch {
		case !repoNameRe.MatchString(e.Repo):
			return nil, fmt.Errorf("entry %d: repo %q is not owner/name", i, e.Repo)
		case !fullSHARe.MatchString(e.Commit):
			return nil, fmt.Errorf("entry %d (%s): commit %q is not a full lowercase SHA", i, e.Repo, e.Commit)
		case e.Pull <= 0:
			return nil, fmt.Errorf("entry %d (%s@%s): pull must name the approving pull request", i, e.Repo, short(e.Commit))
		case !strings.HasPrefix(e.Record, exceptionRecordPrefix):
			return nil, fmt.Errorf("entry %d (%s@%s): record %q is not under %s", i, e.Repo, short(e.Commit), e.Record, exceptionRecordPrefix)
		}
		key := exceptionKey(e.Repo, e.Commit)
		if _, dup := l[key]; dup {
			return nil, fmt.Errorf("entry %d: %s@%s appears twice", i, e.Repo, short(e.Commit))
		}
		l[key] = e
	}
	return l, nil
}

// forApproval returns the exception that covers commit sha in repo when it
// is approved on pull request number, or nil.
func (l exceptionList) forApproval(repo, sha string, number int) *authorException {
	e, ok := l[exceptionKey(repo, sha)]
	if !ok || e.Pull != number {
		return nil
	}
	return &e
}
