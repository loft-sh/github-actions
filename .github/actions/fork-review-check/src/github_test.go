package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/go-github/v88/github"
)

func TestCompareReadsCommitSignatureVerification(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"status":"ahead","total_commits":3,"commits":[
			{"sha":"signed","commit":{"verification":{"verified":true}}},
			{"sha":"unsigned","commit":{"verification":{"verified":false}}},
			{"sha":"missing","commit":{}}
		]}`)
	}))
	defer server.Close()
	client, err := github.NewClient(github.WithEnterpriseURLs(server.URL, server.URL))
	if err != nil {
		t.Fatal(err)
	}
	cmp, err := (githubAPI{gh: client}).Compare(context.Background(), "owner/repo", "base", "head")
	if err != nil {
		t.Fatal(err)
	}
	if len(cmp.Commits) != 3 || !cmp.Commits[0].Verified || cmp.Commits[1].Verified || cmp.Commits[2].Verified {
		t.Fatalf("unexpected verification states: %+v", cmp.Commits)
	}
}
