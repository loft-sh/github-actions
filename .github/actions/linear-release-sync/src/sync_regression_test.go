package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/shurcooL/graphql"
)

func TestResolvedUUIDUsedForMutations(t *testing.T) {
	for _, failure := range []string{"", "issueUpdate", "commentCreate"} {
		t.Run(failure, func(t *testing.T) {
			var mutations []string
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var req struct {
					Query     string         `json:"query"`
					Variables map[string]any `json:"variables"`
				}
				if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
					t.Fatal(err)
				}
				w.Header().Set("Content-Type", "application/json")
				if strings.Contains(req.Query, "issueUpdate") || strings.Contains(req.Query, "commentCreate") {
					if req.Variables["issueID"] != "resolved-uuid" {
						t.Errorf("mutation issueID = %v", req.Variables["issueID"])
					}
					name := "issueUpdate"
					if strings.Contains(req.Query, "commentCreate") {
						name = "commentCreate"
					}
					mutations = append(mutations, name)
					fmt.Fprintf(w, `{"data":{"%s":{"success":%t}}}`, name, name != failure)
					return
				}
				if req.Variables["id"] != "engplat-1329" {
					t.Errorf("lookup id = %v", req.Variables["id"])
				}
				fmt.Fprint(w, `{"data":{"issue":{"id":"resolved-uuid","state":{"id":"ready","name":"Ready for Release"},"team":{"name":"Platform"},"project":null}}}`)
			}))
			defer server.Close()
			client := LinearClient{client: graphql.NewClient(server.URL, server.Client()), logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
			details, err := client.GetIssueDetails(context.Background(), "engplat-1329")
			if err != nil {
				t.Fatal(err)
			}
			err = client.MoveIssueToState(context.Background(), false, "engplat-1329", details, "released", "Ready for Release", "v4.9.7", "2026-11-04", true)
			if (err != nil) != (failure != "") {
				t.Fatalf("error = %v, failure = %q", err, failure)
			}
			if len(mutations) == 0 || mutations[0] != "issueUpdate" {
				t.Fatalf("mutations = %v", mutations)
			}
			if failure != "issueUpdate" && len(mutations) != 2 {
				t.Fatalf("mutations = %v", mutations)
			}
		})
	}
}

func TestProcessIssuesContinuesAfterFailure(t *testing.T) {
	var visited []string
	failed, err := processIssues([]string{"one", "two", "three"}, func(id string) error {
		visited = append(visited, id)
		if id == "two" {
			return fmt.Errorf("comment failed")
		}
		return nil
	})
	if err == nil || failed != 1 || strings.Join(visited, ",") != "one,two,three" {
		t.Fatalf("error = %v, failed = %d, visited = %v", err, failed, visited)
	}
	if _, err := processIssues([]string{"skip", "success"}, func(string) error { return nil }); err != nil {
		t.Fatalf("successful batch: %v", err)
	}
}
