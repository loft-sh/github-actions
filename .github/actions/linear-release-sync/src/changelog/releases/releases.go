package releases

import (
	"context"
	"fmt"

	semver "github.com/Masterminds/semver/v3"
	"github.com/shurcooL/githubv4"
)

const PageSize = 100

// LastStableRelease returns the last stable release for the given repository.
// It returns the tag name, id and the creation time of the release.
func LastStableRelease(ctx context.Context, client *githubv4.Client, owner, repo string) (string, int, error) {
	var query struct {
		Repository struct {
			LatestRelease struct {
				CreatedAt  githubv4.DateTime
				TagName    string
				DatabaseId int
			}
		} `graphql:"repository(owner: $owner, name: $repo)"`
	}

	if err := client.Query(ctx, &query, map[string]interface{}{
		"owner": githubv4.String(owner),
		"repo":  githubv4.String(repo),
	}); err != nil {
		return "", 0, fmt.Errorf("query latest release: %w", err)
	}

	return query.Repository.LatestRelease.TagName, query.Repository.LatestRelease.DatabaseId, nil
}

func LastStableReleaseBeforeTag(ctx context.Context, client *githubv4.Client, owner, repo, tag string) (string, error) {
	tagSemver, err := semver.NewVersion(tag)
	if err != nil {
		return "", fmt.Errorf("failed to parse tag: %w", err)
	}

	return LatestStableSemverRange(ctx, client, owner, repo, "< "+tagSemver.String())
}

// LatestStableSemverRange returns the highest-semver stable release whose tag
// satisfies tagRangeExpr. Releases are paginated via the GitHub API ordered by
// CREATED_AT (the only meaningful ordering the API supports), but the winner
// is picked by semver comparison across all matches, not by creation date.
//
// Ordering by creation date is wrong for repositories that maintain multiple
// stable release lines in parallel: a patch on an older minor (e.g. v4.6.3)
// can be cut moments before a patch on a newer minor (e.g. v4.8.2), and a
// creation-date-first match would return v4.6.3 as the predecessor of v4.8.2
// rather than v4.8.1. See DEVOPS-874.
func LatestStableSemverRange(ctx context.Context, client *githubv4.Client, owner, repo, tagRangeExpr string) (string, error) {
	tagRange, err := semver.NewConstraint(tagRangeExpr)
	if err != nil {
		// Ignore bad ranges for now.
		return "", fmt.Errorf("failed to parse tag: %w", err)
	}

	var query struct {
		Repository struct {
			Releases struct {
				PageInfo struct {
					EndCursor   githubv4.String
					HasNextPage bool
				}
				Nodes []struct {
					TagName      string
					IsPrerelease bool
				}
			} `graphql:"releases(first: $pageSize, after: $cursor, orderBy: { direction: DESC, field: CREATED_AT})"`
		} `graphql:"repository(owner: $owner, name: $repo)"`
	}

	var (
		cursor  *githubv4.String
		best    *semver.Version
		bestTag string
	)

	for {
		if err := client.Query(ctx, &query, map[string]interface{}{
			"owner":    githubv4.String(owner),
			"repo":     githubv4.String(repo),
			"pageSize": githubv4.Int(PageSize),
			"cursor":   cursor,
		}); err != nil {
			return "", fmt.Errorf("query repository: %w", err)
		}

		cursor = &query.Repository.Releases.PageInfo.EndCursor

		for _, release := range query.Repository.Releases.Nodes {
			releaseSemver, err := semver.NewVersion(release.TagName)
			if err != nil {
				continue
			}

			if releaseSemver.Prerelease() != "" {
				continue
			}

			if release.IsPrerelease {
				continue
			}

			if !tagRange.Check(releaseSemver) {
				continue
			}

			if best == nil || releaseSemver.GreaterThan(best) {
				best = releaseSemver
				bestTag = release.TagName
			}
		}

		if !query.Repository.Releases.PageInfo.HasNextPage {
			break
		}
	}

	return bestTag, nil
}

type Release struct {
	PublishedAt  githubv4.DateTime
	Description  string
	Name         string
	TagName      string
	IsPrerelease bool
	DatabaseId   int64
}

// FetchReleaseByTag fetches a release by its tag name.
// It returns the release or an error if the release could not be found.
func FetchReleaseByTag(ctx context.Context, client *githubv4.Client, owner, repo, tag string) (Release, error) {
	var query struct {
		Repository struct {
			Release Release `graphql:"release(tagName: $tag)"`
		} `graphql:"repository(owner: $owner, name: $repo)"`
	}

	if err := client.Query(ctx, &query, map[string]interface{}{
		"owner": githubv4.String(owner),
		"repo":  githubv4.String(repo),
		"tag":   githubv4.String(tag),
	}); err != nil {
		return Release{}, fmt.Errorf("query release by tag: %w", err)
	}

	return query.Repository.Release, nil
}
