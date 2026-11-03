package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/go-github/v88/github"
)

func scanFixture(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, body := range files {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func scanFork() *fakeAPI {
	f := reviewedFork()
	f.repos[fork] = repoInfo{FullName: fork, Fork: true}
	return f
}

func scanOptions(root string) options {
	return options{
		mode:            "scan",
		root:            root,
		signerWorkflows: multiFlag{fork + "=.github/workflows/release.yml"},
	}
}

func scanCheck(t *testing.T, root string, f forkAPI, tool goTool, attest attestTool, download downloadTool, opts options) receipt {
	t.Helper()
	rc, err := check(context.Background(), f, tool, attest, download, opts, t0)
	if err != nil {
		t.Fatal(err)
	}
	if rc.Mode != "scan" {
		t.Fatalf("receipt mode = %q, want scan", rc.Mode)
	}
	return rc
}

func TestScanResolvesImageAndSourceARGDefaults(t *testing.T) {
	digest := "sha256:" + strings.Repeat("a", 64)
	root := scanFixture(t, map[string]string{
		"Dockerfile": "ARG TAG=\"v0.16.5.vcluster.1\"\n" +
			"ARG DIGEST=" + digest + "\n" +
			"FROM ghcr.io/loft-sh/kine:${TAG}@${DIGEST}\n" +
			"RUN git clone -b \"$TAG\" https://github.com/loft-sh/kine.git\n",
	})
	attest := &fakeAttest{}
	rc := scanCheck(t, root, scanFork(), nil, attest, nil, scanOptions(root))
	if !rc.Pass || len(rc.Inputs) != 2 || len(rc.Forks) != 1 {
		t.Fatalf("scan result = %+v", rc)
	}
	if rc.Inputs[0].Kind != "image" || rc.Inputs[1].Kind != "fork-source" || rc.Inputs[1].Source != "Dockerfile:4" {
		t.Fatalf("inputs = %+v", rc.Inputs)
	}
	if got := attest.subjects; len(got) != 1 || got[0] != "oci://"+imageSource(digest) {
		t.Fatalf("attestation subjects = %v", got)
	}
}

func TestScanTemplatedInputsNeedExplicitCoverage(t *testing.T) {
	image := "ghcr.io/loft-sh/kine:" + tag + "@sha256:" + strings.Repeat("a", 64)
	cases := []struct {
		name     string
		file     string
		opts     func(options) options
		download downloadTool
		want     string
		wantPass bool
	}{
		{
			name: "image",
			file: "FROM ghcr.io/loft-sh/kine:" + tag + "\n",
			want: "Dockerfile:1: image reference to loft-sh/kine is not pinned in the file; pass it with -image",
		},
		{
			name: "covered image",
			file: "FROM ghcr.io/loft-sh/kine:" + tag + "\n",
			opts: func(o options) options {
				o.images = multiFlag{image}
				return o
			},
			wantPass: true,
		},
		{
			name: "source",
			file: "ARG TAG\nRUN git clone --branch ${TAG} https://github.com/loft-sh/kine.git\n",
			want: "Dockerfile:2: source reference to loft-sh/kine is not pinned in the file; pass it with -source",
		},
		{
			name: "covered source",
			file: "ARG TAG\nRUN git clone --branch ${TAG} https://github.com/loft-sh/kine.git\n",
			opts: func(o options) options {
				o.sources = multiFlag{fork + "=" + tag}
				return o
			},
			wantPass: true,
		},
		{
			name: "binary",
			file: "curl -LO https://github.com/loft-sh/kine/releases/download/" + tag + "/kine\n",
			want: "build.sh:1: binary reference to loft-sh/kine is not pinned in the file; pass it with -url",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			name := "Dockerfile"
			if strings.Contains(tc.file, "curl") {
				name = "build.sh"
			}
			root := scanFixture(t, map[string]string{name: tc.file})
			opts := scanOptions(root)
			if tc.opts != nil {
				opts = tc.opts(opts)
			}
			rc := scanCheck(t, root, scanFork(), nil, &fakeAttest{}, tc.download, opts)
			if rc.Pass != tc.wantPass {
				t.Fatalf("pass = %t, want %t: %+v", rc.Pass, tc.wantPass, rc)
			}
			if tc.want != "" && !strings.Contains(strings.Join(rc.Failures, "\n"), tc.want) {
				t.Fatalf("failures = %v, want %q", rc.Failures, tc.want)
			}
		})
	}
}

func TestScanCoveredBinaryUsesNormalResolver(t *testing.T) {
	root := t.TempDir()
	asset := filepath.Join(root, "asset")
	if err := os.WriteFile(asset, []byte("kine"), 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("kine"))
	want := hex.EncodeToString(sum[:])
	url := "https://github.com/loft-sh/kine/releases/download/" + tag + "/kine"
	if err := os.WriteFile(filepath.Join(root, "build.sh"), []byte("curl -LO "+url+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	opts := scanOptions(root)
	opts.urls = multiFlag{url}
	opts.sha256 = multiFlag{want}
	rc := scanCheck(t, root, scanFork(), nil, &fakeAttest{}, fakeDownload{path: asset, url: url}, opts)
	if !rc.Pass || len(rc.Inputs) != 1 || rc.Inputs[0].Kind != "binary" {
		t.Fatalf("scan result = %+v", rc)
	}
}

func TestScanIgnoresLinksCommentsAndNonForks(t *testing.T) {
	root := scanFixture(t, map[string]string{
		"build.sh": "# https://github.com/loft-sh/kine\n" +
			"curl https://github.com/loft-sh/kine/releases/tag/" + tag + "\n" +
			"echo https://github.com/loft-sh/product\n",
		"go.mod": "// require github.com/loft-sh/kine v" + tag + "\n",
	})
	f := scanFork()
	f.repos["loft-sh/product"] = repoInfo{FullName: "loft-sh/product"}
	rc := scanCheck(t, root, f, nil, nil, nil, scanOptions(root))
	if !rc.Pass || len(rc.Inputs) != 0 || len(rc.Failures) != 0 {
		t.Fatalf("scan result = %+v", rc)
	}
}

type missingRepoAPI struct{ *fakeAPI }

func (f missingRepoAPI) Repo(ctx context.Context, repo string) (repoInfo, error) {
	if repo == "loft-sh/kine-fips" {
		return repoInfo{}, &github.ErrorResponse{Response: &http.Response{StatusCode: http.StatusNotFound}}
	}
	return f.fakeAPI.Repo(ctx, repo)
}

type packageErrAPI struct{ missingRepoAPI }

func (f packageErrAPI) PackageRepo(context.Context, string, string) (string, error) {
	return "", errors.New("403 Resource not accessible by integration")
}

// kine-fips has no repository of its own. Which repository publishes the
// package decides whether it can carry fork code.
func TestScanResolvesImageWithoutRepositoryThroughItsPackage(t *testing.T) {
	root := scanFixture(t, map[string]string{
		"Dockerfile": "FROM ghcr.io/loft-sh/kine-fips:latest\n",
	})
	cases := []struct {
		name    string
		publish string
		api     func(*fakeAPI) forkAPI
		want    string
	}{
		{name: "no package", api: func(f *fakeAPI) forkAPI { return missingRepoAPI{f} }},
		{name: "published by a non-fork build repo", publish: "loft-sh/fips-builds", api: func(f *fakeAPI) forkAPI { return missingRepoAPI{f} }},
		{
			name: "published by a fork under another name", publish: fork,
			api:  func(f *fakeAPI) forkAPI { return missingRepoAPI{f} },
			want: "Dockerfile:1: image ghcr.io/loft-sh/kine-fips is published by fork loft-sh/kine under another name, which no resolver understands",
		},
		{
			name: "package lookup fails", api: func(f *fakeAPI) forkAPI { return packageErrAPI{missingRepoAPI{f}} },
			want: "Dockerfile:1: cannot tell which repository publishes ghcr.io/loft-sh/kine-fips: 403 Resource not accessible by integration",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := scanFork()
			f.repos["loft-sh/fips-builds"] = repoInfo{FullName: "loft-sh/fips-builds"}
			f.packages = map[string]string{"loft-sh/kine-fips": tc.publish}
			rc := scanCheck(t, root, tc.api(f), nil, nil, nil, scanOptions(root))
			if tc.want == "" {
				if !rc.Pass || len(rc.Failures) != 0 {
					t.Fatalf("scan result = %+v", rc)
				}
				return
			}
			if rc.Pass || len(rc.Failures) != 1 || rc.Failures[0] != tc.want {
				t.Fatalf("failures = %q, want only %q", rc.Failures, tc.want)
			}
		})
	}
}

func TestScanUnknownReferenceNamesFileAndLine(t *testing.T) {
	root := scanFixture(t, map[string]string{
		"build.sh": "echo https://github.com/loft-sh/kine\n",
	})
	rc := scanCheck(t, root, scanFork(), nil, nil, nil, scanOptions(root))
	want := "build.sh:1: reference to fork loft-sh/kine that no resolver understands"
	if rc.Pass || len(rc.Failures) != 1 || rc.Failures[0] != want {
		t.Fatalf("failures = %v, want %q", rc.Failures, want)
	}
}

type scanGo struct {
	fakeGo
	dirs []string
}

func (g *scanGo) ListModules(dir string) ([]goModule, error) {
	g.dirs = append(g.dirs, dir)
	return g.fakeGo.ListModules(dir)
}

func TestScanRunsGoResolverOncePerDirectory(t *testing.T) {
	root := scanFixture(t, map[string]string{
		"go.mod":  "module example.test/product\n\nrequire github.com/loft-sh/kine " + tag + "\n",
		"go.work": "go 1.25\n\nuse .\n\nreplace github.com/loft-sh/kine => github.com/loft-sh/kine " + tag + "\n",
	})
	g := &scanGo{fakeGo: fakeGo{
		mods: []goModule{{Path: "github.com/" + fork, Version: tag}},
		downloads: map[string]goDownload{
			"github.com/" + fork + "@" + tag: {
				Origin: &goOrigin{URL: "https://github.com/" + fork, Hash: merge},
			},
		},
	}}
	rc := scanCheck(t, root, scanFork(), g, nil, nil, scanOptions(root))
	if !rc.Pass || len(rc.Inputs) != 1 || len(g.dirs) != 1 || rc.Inputs[0].Kind != "go-module" {
		t.Fatalf("scan result = %+v, calls = %v", rc, g.dirs)
	}
}

func TestScanSkipsExcludedAndNonInputFiles(t *testing.T) {
	root := scanFixture(t, map[string]string{
		"README.md":         "https://github.com/loft-sh/kine\n",
		"go.sum":            "https://github.com/loft-sh/kine\n",
		"main.go":           "https://github.com/loft-sh/kine\n",
		"vendor/x.sh":       "https://github.com/loft-sh/kine\n",
		"testdata/x.sh":     "https://github.com/loft-sh/kine\n",
		"node_modules/x.sh": "https://github.com/loft-sh/kine\n",
		".git/x.sh":         "https://github.com/loft-sh/kine\n",
	})
	rc := scanCheck(t, root, scanFork(), nil, nil, nil, scanOptions(root))
	if !rc.Pass || len(rc.Failures) != 0 {
		t.Fatalf("scan result = %+v", rc)
	}
}

func TestScanFailuresAreSortedAndArgsNeedPairs(t *testing.T) {
	root := scanFixture(t, map[string]string{
		"z.sh": "echo https://github.com/loft-sh/kine\n",
		"a.sh": "echo https://github.com/loft-sh/kine\n",
	})
	rc := scanCheck(t, root, scanFork(), nil, nil, nil, scanOptions(root))
	if got := strings.Join(rc.Failures, "\n"); !strings.HasPrefix(got, "a.sh:1\n") && !strings.HasPrefix(got, "a.sh:1:") {
		t.Fatalf("failures are not sorted: %v", rc.Failures)
	}
	opts, err := parseArgs([]string{"scan"})
	if err != nil || opts.root != "." {
		t.Fatalf("scan args = %+v, %v", opts, err)
	}
	if _, err := parseArgs([]string{"scan", "-url", "https://example.test/file"}); err == nil {
		t.Fatal("scan URL without SHA-256 must fail")
	}
}

func TestScanSourceFullCommit(t *testing.T) {
	root := scanFixture(t, map[string]string{
		"build.sh": "git clone -b " + merge + " https://github.com/loft-sh/kine.git\n",
	})
	f := scanFork()
	f.repos[upstream] = repoInfo{FullName: upstream, DefaultBranch: "master"}
	f.compares[fork+"@k3s-io:master..."+merge] = comparison{
		Status: "diverged", Total: 3, MergeBase: baseSHA,
		Commits: f.compares[fork+"@"+baseSHA+"..."+merge].Commits,
	}
	rc := scanCheck(t, root, f, nil, nil, nil, scanOptions(root))
	if !rc.Pass || rc.Inputs[0].Commit != merge {
		t.Fatalf("scan result = %+v", rc)
	}
}

func TestSourceParts(t *testing.T) {
	if _, _, err := sourceParts("loft-sh/kine"); err == nil {
		t.Fatal("source without a ref must fail")
	}
	repo, ref, err := sourceParts(fork + "=" + tag)
	if err != nil || repo != fork || ref != tag {
		t.Fatalf("source = %q, %q, %v", repo, ref, err)
	}
}

func TestScanUsesClockForReceipt(t *testing.T) {
	root := scanFixture(t, map[string]string{})
	now := time.Date(2026, 10, 27, 9, 0, 0, 0, time.UTC)
	rc, err := check(context.Background(), scanFork(), nil, nil, nil, scanOptions(root), now)
	if err != nil || !rc.CheckedAt.Equal(now) {
		t.Fatalf("receipt = %+v, err = %v", rc, err)
	}
}

func TestScanOperationalRepoErrorStopsCheck(t *testing.T) {
	root := scanFixture(t, map[string]string{
		"build.sh": "echo https://github.com/loft-sh/kine\n",
	})
	f := scanFork()
	f.repos = nil
	_, err := check(context.Background(), f, nil, nil, nil, scanOptions(root), t0)
	if err == nil || !strings.Contains(fmt.Sprint(err), "read loft-sh/kine") {
		t.Fatalf("error = %v", err)
	}
}

func TestScanCheckoutOfForkNeedsSource(t *testing.T) {
	root := scanFixture(t, map[string]string{
		".github/workflows/release.yaml": "steps:\n" +
			"  - uses: actions/checkout@v7\n" +
			"    with:\n" +
			"      repository: loft-sh/kine\n" +
			"      ref: ${{ env.KINE_VERSION }}\n",
		"hack/build.yaml": "repository: loft-sh/kine\n",
	})
	rc := scanCheck(t, root, scanFork(), nil, nil, nil, scanOptions(root))
	want := ".github/workflows/release.yaml:4: source reference to loft-sh/kine is not pinned in the file; pass it with -source"
	if rc.Pass || len(rc.Failures) != 1 || rc.Failures[0] != want {
		t.Fatalf("failures = %q, want only %q", rc.Failures, want)
	}

	opts := scanOptions(root)
	opts.sources = multiFlag{fork + "=" + tag}
	rc = scanCheck(t, root, scanFork(), nil, nil, nil, opts)
	if !rc.Pass || len(rc.Inputs) != 1 || rc.Inputs[0].Kind != "fork-source" {
		t.Fatalf("scan result = %+v", rc)
	}
}
