package main

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"net/mail"
	"regexp"
	"strings"
)

// identityMapFile is the reviewed identity map, named in failures as the remedy.
const identityMapFile = ".github/actions/fork-review-check/src/identities.json"

// identityMapSource marks a commit author resolved through the identity map.
const identityMapSource = "identity-map"

//go:embed identities.json
var identitiesJSON []byte

// githubLoginRe is GitHub's username format: alphanumerics and single inner
// hyphens, at most 39 characters.
var githubLoginRe = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9]|-[A-Za-z0-9]){0,38}$`)

// identity ties a commit author email that GitHub links to no account to the
// GitHub account of the person who wrote the commit. Evidence is a GitHub
// URL a reviewer can open to confirm the tie, such as a pull request that
// account authored with commits from that email.
type identity struct {
	Email    string `json:"email"`
	Login    string `json:"login"`
	Name     string `json:"name"`
	Evidence string `json:"evidence"`
}

// identityMap is keyed by the lowercased commit author email.
type identityMap map[string]identity

// defaultIdentities is the map compiled into the binary. It ships with the
// action at the caller's pinned ref, so a caller cannot add or change an entry.
var defaultIdentities = mustParseIdentities(identitiesJSON)

func mustParseIdentities(data []byte) identityMap {
	m, err := parseIdentities(data)
	if err != nil {
		panic(fmt.Sprintf("%s: %v", identityMapFile, err))
	}
	return m
}

// parseIdentities reads the identity map and rejects any entry a reviewer
// could not verify: a malformed email or login, a missing name, evidence
// outside GitHub, or a second entry for the same email.
func parseIdentities(data []byte) (identityMap, error) {
	var doc struct {
		Identities []identity `json:"identities"`
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&doc); err != nil {
		return nil, fmt.Errorf("parse identity map: %w", err)
	}
	m := identityMap{}
	for i, id := range doc.Identities {
		email := strings.ToLower(id.Email)
		addr, err := mail.ParseAddress(id.Email)
		switch {
		case err != nil || addr.Address != id.Email || addr.Name != "":
			return nil, fmt.Errorf("entry %d: email %q is not a bare address", i, id.Email)
		case len(id.Login) > 39 || !githubLoginRe.MatchString(id.Login):
			return nil, fmt.Errorf("entry %d (%s): login %q is not a GitHub username", i, id.Email, id.Login)
		case strings.TrimSpace(id.Name) == "":
			return nil, fmt.Errorf("entry %d (%s): name is empty", i, id.Email)
		case !strings.HasPrefix(id.Evidence, "https://github.com/"):
			return nil, fmt.Errorf("entry %d (%s): evidence %q is not a https://github.com/ URL", i, id.Email, id.Evidence)
		}
		if _, dup := m[email]; dup {
			return nil, fmt.Errorf("entry %d: email %s appears twice", i, id.Email)
		}
		m[email] = id
	}
	return m, nil
}

// resolveAuthor fills in the GitHub login of a commit whose author email
// GitHub links to no account, from the reviewed identity map. A linked login
// always wins, so the map cannot rename an author GitHub already knows.
func (m identityMap) resolveAuthor(ci commitInfo) commitInfo {
	if ci.Author != "" || ci.AuthorEmail == "" {
		return ci
	}
	if id, ok := m[strings.ToLower(ci.AuthorEmail)]; ok {
		ci.Author, ci.AuthorSource = id.Login, identityMapSource
	}
	return ci
}
