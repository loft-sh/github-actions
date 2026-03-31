package releases

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

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

func TestLastStableReleaseBeforeTag(t *testing.T) {
	testCases := []struct {
		name        string
		tag         string
		releases    []map[string]any
		expected    string
		expectError bool
	}{
		{
			name: "finds previous stable release",
			tag:  "v1.2.0",
			releases: []map[string]any{
				{"tagName": "v1.2.0", "isPrerelease": false},
				{"tagName": "v1.1.0", "isPrerelease": false},
				{"tagName": "v1.0.0", "isPrerelease": false},
			},
			expected: "v1.1.0",
		},
		{
			name: "skips pre-releases",
			tag:  "v1.2.0",
			releases: []map[string]any{
				{"tagName": "v1.2.0", "isPrerelease": false},
				{"tagName": "v1.2.0-rc.1", "isPrerelease": true},
				{"tagName": "v1.1.0", "isPrerelease": false},
			},
			expected: "v1.1.0",
		},
		{
			name: "skips semver pre-releases even if isPrerelease is false",
			tag:  "v1.2.0",
			releases: []map[string]any{
				{"tagName": "v1.2.0", "isPrerelease": false},
				{"tagName": "v1.2.0-alpha.1", "isPrerelease": false},
				{"tagName": "v1.1.0", "isPrerelease": false},
			},
			expected: "v1.1.0",
		},
		{
			name:        "invalid tag returns error",
			tag:         "not-semver",
			releases:    []map[string]any{},
			expectError: true,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				resp := map[string]any{
					"data": map[string]any{
						"repository": map[string]any{
							"releases": map[string]any{
								"pageInfo": map[string]any{
									"endCursor":   "",
									"hasNextPage": false,
								},
								"nodes": tc.releases,
							},
						},
					},
				}
				json.NewEncoder(w).Encode(resp)
			})

			client := newTestClient(handler)
			result, err := LastStableReleaseBeforeTag(context.Background(), client, "owner", "repo", tc.tag)

			if tc.expectError {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				return
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if result != tc.expected {
				t.Errorf("expected %q, got %q", tc.expected, result)
			}
		})
	}
}

func TestLatestStableSemverRange_Pagination(t *testing.T) {
	callCount := 0
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		var resp map[string]any
		if callCount == 1 {
			resp = map[string]any{
				"data": map[string]any{
					"repository": map[string]any{
						"releases": map[string]any{
							"pageInfo": map[string]any{
								"endCursor":   "cursor1",
								"hasNextPage": true,
							},
							"nodes": []any{
								map[string]any{"tagName": "v2.0.0", "isPrerelease": false},
								map[string]any{"tagName": "v1.5.0-rc.1", "isPrerelease": true},
							},
						},
					},
				},
			}
		} else {
			resp = map[string]any{
				"data": map[string]any{
					"repository": map[string]any{
						"releases": map[string]any{
							"pageInfo": map[string]any{
								"endCursor":   "",
								"hasNextPage": false,
							},
							"nodes": []any{
								map[string]any{"tagName": "v1.4.0", "isPrerelease": false},
								map[string]any{"tagName": "v1.3.0", "isPrerelease": false},
							},
						},
					},
				},
			}
		}
		json.NewEncoder(w).Encode(resp)
	})

	client := newTestClient(handler)
	result, err := LatestStableSemverRange(context.Background(), client, "owner", "repo", "< 1.5.0")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if callCount != 2 {
		t.Errorf("expected 2 API calls for pagination, got %d", callCount)
	}
	if result != "v1.4.0" {
		t.Errorf("expected v1.4.0, got %q", result)
	}
}

func TestLatestStableSemverRange_NoMatch(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := map[string]any{
			"data": map[string]any{
				"repository": map[string]any{
					"releases": map[string]any{
						"pageInfo": map[string]any{
							"endCursor":   "",
							"hasNextPage": false,
						},
						"nodes": []any{
							map[string]any{"tagName": "v2.0.0", "isPrerelease": false},
							map[string]any{"tagName": "v1.5.0", "isPrerelease": false},
						},
					},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	})

	client := newTestClient(handler)
	result, err := LatestStableSemverRange(context.Background(), client, "owner", "repo", "< 1.0.0")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result != "" {
		t.Errorf("expected empty string for no match, got %q", result)
	}
}

func TestFetchReleaseByTag(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := map[string]any{
			"data": map[string]any{
				"repository": map[string]any{
					"release": map[string]any{
						"publishedAt": "2024-01-15T12:00:00Z",
						"description": "Release notes",
						"name":        "v1.2.0",
						"tagName":     "v1.2.0",
						"databaseId":  42,
					},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	})

	client := newTestClient(handler)
	release, err := FetchReleaseByTag(context.Background(), client, "owner", "repo", "v1.2.0")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if release.TagName != "v1.2.0" {
		t.Errorf("expected tag v1.2.0, got %q", release.TagName)
	}
	if release.Name != "v1.2.0" {
		t.Errorf("expected name v1.2.0, got %q", release.Name)
	}
	if release.DatabaseId != 42 {
		t.Errorf("expected databaseId 42, got %d", release.DatabaseId)
	}
}

func TestLatestStableSemverRange_InvalidConstraint(t *testing.T) {
	client := newTestClient(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))

	_, err := LatestStableSemverRange(context.Background(), client, "owner", "repo", "not a valid constraint !!!")
	if err == nil {
		t.Fatal("expected error for invalid constraint, got nil")
	}
}

func TestLastStableRelease(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := map[string]any{
			"data": map[string]any{
				"repository": map[string]any{
					"latestRelease": map[string]any{
						"createdAt":  "2024-01-15T12:00:00Z",
						"tagName":    "v1.5.0",
						"databaseId": 99,
					},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	})

	client := newTestClient(handler)
	tagName, dbID, err := LastStableRelease(context.Background(), client, "owner", "repo")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if tagName != "v1.5.0" {
		t.Errorf("expected tag v1.5.0, got %q", tagName)
	}
	if dbID != 99 {
		t.Errorf("expected databaseId 99, got %d", dbID)
	}
}

func TestLatestStableSemverRange_SkipsInvalidTagNames(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := map[string]any{
			"data": map[string]any{
				"repository": map[string]any{
					"releases": map[string]any{
						"pageInfo": map[string]any{
							"endCursor":   "",
							"hasNextPage": false,
						},
						"nodes": []any{
							map[string]any{"tagName": "not-semver", "isPrerelease": false},
							map[string]any{"tagName": "v1.0.0", "isPrerelease": false},
						},
					},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	})

	client := newTestClient(handler)
	result, err := LatestStableSemverRange(context.Background(), client, "owner", "repo", "< 2.0.0")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result != "v1.0.0" {
		t.Errorf("expected v1.0.0, got %q", result)
	}
}
