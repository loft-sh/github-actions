package pullrequests

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/shurcooL/githubv4"
	"golang.org/x/oauth2"
)

func newTestClient(handler http.Handler) *githubv4.Client {
	srv := httptest.NewServer(handler)
	httpClient := oauth2.NewClient(context.Background(), oauth2.StaticTokenSource(
		&oauth2.Token{AccessToken: "test"},
	))
	return githubv4.NewEnterpriseClient(srv.URL, httpClient)
}

func TestFetchAllPRsBetween_DeduplicatesByPRNumber(t *testing.T) {
	callCount := 0
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		// Return the same PR number from two different commits to test deduplication
		resp := map[string]any{
			"data": map[string]any{
				"repository": map[string]any{
					"ref": map[string]any{
						"compare": map[string]any{
							"commits": map[string]any{
								"pageInfo": map[string]any{
									"endCursor":   "",
									"hasNextPage": false,
								},
								"nodes": []any{
									map[string]any{
										"associatedPullRequests": map[string]any{
											"pageInfo": map[string]any{
												"endCursor":   "",
												"hasNextPage": false,
											},
											"nodes": []any{
												map[string]any{
													"merged":      true,
													"body":        "Fix ENG-1234",
													"headRefName": "fix/bug",
													"author":      map[string]any{"login": "dev1"},
													"number":      1,
													"mergedAt":    "2024-01-15T10:00:00Z",
												},
											},
										},
									},
									map[string]any{
										"associatedPullRequests": map[string]any{
											"pageInfo": map[string]any{
												"endCursor":   "",
												"hasNextPage": false,
											},
											"nodes": []any{
												// Same PR #1 from a different commit
												map[string]any{
													"merged":      true,
													"body":        "Fix ENG-1234",
													"headRefName": "fix/bug",
													"author":      map[string]any{"login": "dev1"},
													"number":      1,
													"mergedAt":    "2024-01-15T10:00:00Z",
												},
												// Different PR #2
												map[string]any{
													"merged":      true,
													"body":        "Add feature ENG-5678",
													"headRefName": "feat/new",
													"author":      map[string]any{"login": "dev2"},
													"number":      2,
													"mergedAt":    "2024-01-15T11:00:00Z",
												},
											},
										},
									},
								},
							},
						},
					},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	})

	client := newTestClient(handler)
	prs, err := FetchAllPRsBetween(context.Background(), client, "owner", "repo", "v1.0.0", "v1.1.0")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(prs) != 2 {
		t.Errorf("expected 2 deduplicated PRs, got %d", len(prs))
	}
}

func TestFetchAllPRsBetween_SkipsUnmergedPRs(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := map[string]any{
			"data": map[string]any{
				"repository": map[string]any{
					"ref": map[string]any{
						"compare": map[string]any{
							"commits": map[string]any{
								"pageInfo": map[string]any{
									"endCursor":   "",
									"hasNextPage": false,
								},
								"nodes": []any{
									map[string]any{
										"associatedPullRequests": map[string]any{
											"pageInfo": map[string]any{
												"endCursor":   "",
												"hasNextPage": false,
											},
											"nodes": []any{
												map[string]any{
													"merged":      true,
													"body":        "Merged PR",
													"headRefName": "fix/merged",
													"author":      map[string]any{"login": "dev1"},
													"number":      1,
													"mergedAt":    "2024-01-15T10:00:00Z",
												},
												map[string]any{
													"merged":      false,
													"body":        "Open PR",
													"headRefName": "fix/open",
													"author":      map[string]any{"login": "dev2"},
													"number":      2,
												},
											},
										},
									},
								},
							},
						},
					},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	})

	client := newTestClient(handler)
	prs, err := FetchAllPRsBetween(context.Background(), client, "owner", "repo", "v1.0.0", "v1.1.0")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(prs) != 1 {
		t.Errorf("expected 1 merged PR, got %d", len(prs))
	}
	if len(prs) > 0 && prs[0].Number != 1 {
		t.Errorf("expected PR #1, got #%d", prs[0].Number)
	}
}

func TestFetchAllPRsBetween_Pagination(t *testing.T) {
	callCount := 0
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		var resp map[string]any
		if callCount == 1 {
			resp = map[string]any{
				"data": map[string]any{
					"repository": map[string]any{
						"ref": map[string]any{
							"compare": map[string]any{
								"commits": map[string]any{
									"pageInfo": map[string]any{
										"endCursor":   "cursor1",
										"hasNextPage": true,
									},
									"nodes": []any{
										map[string]any{
											"associatedPullRequests": map[string]any{
												"pageInfo": map[string]any{
													"endCursor":   "",
													"hasNextPage": false,
												},
												"nodes": []any{
													map[string]any{
														"merged":      true,
														"body":        "Page 1 PR",
														"headRefName": "fix/page1",
														"author":      map[string]any{"login": "dev1"},
														"number":      1,
														"mergedAt":    "2024-01-15T10:00:00Z",
													},
												},
											},
										},
									},
								},
							},
						},
					},
				},
			}
		} else {
			resp = map[string]any{
				"data": map[string]any{
					"repository": map[string]any{
						"ref": map[string]any{
							"compare": map[string]any{
								"commits": map[string]any{
									"pageInfo": map[string]any{
										"endCursor":   "cursor2",
										"hasNextPage": false,
									},
									"nodes": []any{
										map[string]any{
											"associatedPullRequests": map[string]any{
												"pageInfo": map[string]any{
													"endCursor":   "",
													"hasNextPage": false,
												},
												"nodes": []any{
													map[string]any{
														"merged":      true,
														"body":        "Page 2 PR",
														"headRefName": "fix/page2",
														"author":      map[string]any{"login": "dev2"},
														"number":      2,
														"mergedAt":    "2024-01-15T11:00:00Z",
													},
												},
											},
										},
									},
								},
							},
						},
					},
				},
			}
		}
		json.NewEncoder(w).Encode(resp)
	})

	client := newTestClient(handler)
	prs, err := FetchAllPRsBetween(context.Background(), client, "owner", "repo", "v1.0.0", "v1.1.0")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if callCount != 2 {
		t.Errorf("expected 2 API calls for pagination, got %d", callCount)
	}
	if len(prs) != 2 {
		t.Errorf("expected 2 PRs across pages, got %d", len(prs))
	}
}

func TestFetchPRsForRelease_FiltersAfterReleaseTime(t *testing.T) {
	releaseTime := time.Date(2024, 1, 15, 12, 0, 0, 0, time.UTC)

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := map[string]any{
			"data": map[string]any{
				"repository": map[string]any{
					"ref": map[string]any{
						"compare": map[string]any{
							"commits": map[string]any{
								"pageInfo": map[string]any{
									"endCursor":   "",
									"hasNextPage": false,
								},
								"nodes": []any{
									map[string]any{
										"associatedPullRequests": map[string]any{
											"pageInfo": map[string]any{
												"endCursor":   "",
												"hasNextPage": false,
											},
											"nodes": []any{
												map[string]any{
													"merged":      true,
													"body":        "Before release",
													"headRefName": "fix/before",
													"author":      map[string]any{"login": "dev1"},
													"number":      1,
													"mergedAt":    "2024-01-15T10:00:00Z", // 2h before
												},
												map[string]any{
													"merged":      true,
													"body":        "After release",
													"headRefName": "fix/after",
													"author":      map[string]any{"login": "dev2"},
													"number":      2,
													"mergedAt":    "2024-01-15T13:00:00Z", // 1h after
												},
												map[string]any{
													"merged":      true,
													"body":        "Also before release",
													"headRefName": "fix/also-before",
													"author":      map[string]any{"login": "dev3"},
													"number":      3,
													"mergedAt":    "2024-01-15T11:30:00Z", // 30m before
												},
											},
										},
									},
								},
							},
						},
					},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	})

	client := newTestClient(handler)
	prs, err := FetchPRsForRelease(context.Background(), client, "owner", "repo", "v1.0.0", "v1.1.0", releaseTime)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(prs) != 2 {
		t.Errorf("expected 2 PRs merged before release, got %d", len(prs))
	}

	for _, pr := range prs {
		if pr.Number == 2 {
			t.Errorf("PR #2 (merged after release) should have been filtered out")
		}
	}
}

func TestFetchAllPRsBetween_EmptyResult(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := map[string]any{
			"data": map[string]any{
				"repository": map[string]any{
					"ref": map[string]any{
						"compare": map[string]any{
							"commits": map[string]any{
								"pageInfo": map[string]any{
									"endCursor":   "",
									"hasNextPage": false,
								},
								"nodes": []any{},
							},
						},
					},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	})

	client := newTestClient(handler)
	prs, err := FetchAllPRsBetween(context.Background(), client, "owner", "repo", "v1.0.0", "v1.1.0")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(prs) != 0 {
		t.Errorf("expected 0 PRs, got %d", len(prs))
	}
}
