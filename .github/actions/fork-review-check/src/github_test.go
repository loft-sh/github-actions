package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
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

func TestPermissionResponses(t *testing.T) {
	for _, status := range []int{http.StatusOK, http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet || r.URL.Path != "/api/v3/repos/owner/fork/collaborators/reviewer/permission" {
					t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
				}
				w.WriteHeader(status)
				if status == http.StatusOK {
					fmt.Fprint(w, `{"permission":"write"}`)
				} else {
					fmt.Fprint(w, `{"message":"request failed"}`)
				}
			}))
			defer server.Close()
			client, err := github.NewClient(github.WithEnterpriseURLs(server.URL, server.URL))
			if err != nil {
				t.Fatal(err)
			}
			permission, err := (githubAPI{gh: client}).Permission(context.Background(), "owner/fork", "reviewer")
			if status == http.StatusOK {
				if err != nil || permission != "write" {
					t.Fatalf("got permission %q, error %v", permission, err)
				}
				return
			}
			var ghErr *github.ErrorResponse
			if permission != "" || !errors.As(err, &ghErr) || ghErr.Response.StatusCode != status {
				t.Fatalf("got permission %q, error %v; want HTTP %d error", permission, err, status)
			}
			if status == http.StatusUnauthorized || status == http.StatusForbidden {
				for _, part := range []string{"github-token", "Metadata:read", "owner/fork"} {
					if !strings.Contains(err.Error(), part) {
						t.Errorf("error %q missing %q", err, part)
					}
				}
			}
		})
	}
}
