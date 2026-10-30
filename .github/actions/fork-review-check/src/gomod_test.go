package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func vendorFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	run("init", "-q")
	run("config", "user.name", "Test")
	run("config", "user.email", "test@example.com")
	if err := os.MkdirAll(filepath.Join(dir, "vendor"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "vendor", "source.go"), []byte("original"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("source.go", filepath.Join(dir, "vendor", "link")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".gitignore"), []byte("vendor/ignored\n"), 0644); err != nil {
		t.Fatal(err)
	}
	run("add", ".")
	run("commit", "-qm", "fixture")
	return dir
}

func TestVerifyVendorRequiresVerifier(t *testing.T) {
	dir := vendorFixture(t)
	if err := verifyVendor(dir, ""); err == nil || !strings.Contains(err.Error(), "verifier") {
		t.Fatalf("expected missing verifier error, got %v", err)
	}
	if err := verifyVendor(t.TempDir(), ""); err != nil {
		t.Fatal(err)
	}
}

func TestVerifyVendorRejectsBrokenVendorLink(t *testing.T) {
	dir := t.TempDir()
	if err := os.Symlink("missing", filepath.Join(dir, "vendor")); err != nil {
		t.Fatal(err)
	}
	if err := verifyVendor(dir, "true"); err == nil {
		t.Fatal("expected broken vendor link to fail")
	}
}

func TestVerifyVendorRunsInIsolatedCopy(t *testing.T) {
	dir := vendorFixture(t)
	command := "test -L vendor/link && test -d .git && test \"$(cat vendor/link)\" = original && printf changed > vendor/source.go"
	if err := verifyVendor(dir, command); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, "vendor", "source.go"))
	if err != nil || string(data) != "original" {
		t.Fatalf("original changed: %q, %v", data, err)
	}
	if err := verifyVendor(dir, "exit 7"); err == nil {
		t.Fatal("expected verifier failure")
	}
}

func TestVerifyVendorRejectsDirtyAndIgnoredVendor(t *testing.T) {
	for _, file := range []string{"source.go", "untracked", "ignored"} {
		t.Run(file, func(t *testing.T) {
			dir := vendorFixture(t)
			if err := os.WriteFile(filepath.Join(dir, "vendor", file), []byte("changed"), 0644); err != nil {
				t.Fatal(err)
			}
			if err := verifyVendor(dir, "true"); err == nil {
				t.Fatal("expected dirty vendor failure")
			}
		})
	}
}

func TestVerifyVendorRejectsSymlinkOutsideCheckout(t *testing.T) {
	dir := vendorFixture(t)
	if err := os.Symlink(t.TempDir(), filepath.Join(dir, "vendor", "outside")); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("git", "add", "vendor/outside")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git add: %v: %s", err, out)
	}
	cmd = exec.Command("git", "commit", "-qm", "outside link")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git commit: %v: %s", err, out)
	}
	if err := verifyVendor(dir, "true"); err == nil || !strings.Contains(err.Error(), "outside") {
		t.Fatalf("expected outside symlink error, got %v", err)
	}
}

func TestVerifyVendorRejectsIgnoredSymlinkTargetContent(t *testing.T) {
	dir := vendorFixture(t)
	if err := os.MkdirAll(filepath.Join(dir, "staging"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "staging", "tracked"), []byte("tracked"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../staging", filepath.Join(dir, "vendor", "staging")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".gitignore"), []byte("staging/ignored\n"), 0644); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("git", "add", "-A")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git add: %v: %s", err, out)
	}
	cmd = exec.Command("git", "commit", "-qm", "staging link")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git commit: %v: %s", err, out)
	}
	if err := os.WriteFile(filepath.Join(dir, "staging", "ignored"), []byte("uncommitted"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := verifyVendor(dir, "true"); err == nil {
		t.Fatal("expected ignored target content to fail")
	}
}

func TestVerifyVendorRunsInModuleDirectory(t *testing.T) {
	root := vendorFixture(t)
	module := filepath.Join(root, "sub")
	if err := os.MkdirAll(module, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(filepath.Join(root, "vendor"), filepath.Join(module, "vendor")); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("git", "add", "-A")
	cmd.Dir = root
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git add: %v: %s", err, out)
	}
	cmd = exec.Command("git", "commit", "-qm", "nested module")
	cmd.Dir = root
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git commit: %v: %s", err, out)
	}
	if err := verifyVendor(module, "test -L vendor/link && test ! -d .git"); err != nil {
		t.Fatal(err)
	}
}

func TestVerifyVendorRejectsWorkspaceVendor(t *testing.T) {
	root := t.TempDir()
	module := filepath.Join(root, "sub")
	if err := os.MkdirAll(module, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "vendor"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "go.work"), []byte("go 1.24\n\nuse ./sub\n"), 0644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOWORK", "auto")
	if err := verifyVendor(module, "true"); err == nil || !strings.Contains(err.Error(), "workspace") {
		t.Fatalf("expected workspace vendor error, got %v", err)
	}
}

func TestListModulesWithVendorAndWorkspaceDisabled(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "vendor"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module example.com/test\n\ngo 1.24\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "vendor", "modules.txt"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOWORK", "off")
	t.Setenv("GOFLAGS", "-mod=vendor")
	mods, err := (execGo{}).ListModules(dir)
	if err != nil || len(mods) != 1 || mods[0].Path != "example.com/test" {
		t.Fatalf("modules = %+v, err = %v", mods, err)
	}
}

type fakeGo struct {
	mods      []goModule
	downloads map[string]goDownload // path@version
}

func (f fakeGo) ListModules(string) ([]goModule, error) { return f.mods, nil }

func (f fakeGo) Download(_, path, version string) (goDownload, error) {
	dl, ok := f.downloads[path+"@"+version]
	if !ok {
		return dl, fmt.Errorf("no download %s@%s", path, version)
	}
	return dl, nil
}

const fuseRev = "0b597961e33d5a2b8e3c1f6d1e8e6c4e2c1a0b9f"

// vnodeGraph mirrors vnode-internal: bazil.org/fuse replaced by the loft-sh
// fork at a pseudo-version, a loft-sh product module, a directory replacement
// and an unrelated module.
func vnodeGraph() fakeGo {
	return fakeGo{
		mods: []goModule{
			{Path: "github.com/loft-sh/vnode", Main: true},
			{Path: "bazil.org/fuse", Version: "v0.0.0-20180421153158-65cc252bf669", Replace: &goModule{Path: "github.com/loft-sh/fuse", Version: "v0.0.0-20250416130952-0b597961e33d"}},
			{Path: "github.com/loft-sh/api/v4", Version: "v4.2.1"},
			{Path: "github.com/loft-sh/local", Version: "v0.0.0", Replace: &goModule{Path: "./local"}},
			{Path: "tailscale.com", Version: "v1.96.4", Replace: &goModule{Path: "github.com/loft-sh/tailscale", Version: "v1.96.4-loft.3"}},
			{Path: "github.com/sirupsen/logrus", Version: "v1.9.3"},
		},
		downloads: map[string]goDownload{
			"github.com/loft-sh/fuse@v0.0.0-20250416130952-0b597961e33d": {Sum: "h1:fuse", Origin: &goOrigin{VCS: "git", URL: "https://github.com/loft-sh/fuse", Hash: fuseRev}},
			"github.com/loft-sh/api/v4@v4.2.1":                           {Sum: "h1:api", Origin: &goOrigin{VCS: "git", URL: "https://github.com/loft-sh/api", Hash: strings.Repeat("a", 40)}},
			"github.com/loft-sh/tailscale@v1.96.4-loft.3":                {Sum: "h1:ts", Origin: &goOrigin{VCS: "git", URL: "https://github.com/loft-sh/tailscale", Hash: strings.Repeat("4", 40)}},
		},
	}
}

func TestGoForkInputsResolvesLoftModules(t *testing.T) {
	inputs, failures, err := goForkInputs(vnodeGraph(), "vnode")
	if err != nil || len(failures) != 0 {
		t.Fatalf("err %v, failures %v", err, failures)
	}
	got := map[string]inputRecord{}
	for _, in := range inputs {
		got[in.Path] = in
	}
	if len(got) != 3 {
		t.Fatalf("want fuse, api and tailscale, got %v", inputs)
	}
	fuse := got["github.com/loft-sh/fuse"]
	if fuse.Module != "bazil.org/fuse" || fuse.Repo != "loft-sh/fuse" || fuse.Commit != fuseRev || fuse.Sum != "h1:fuse" {
		t.Errorf("fuse input = %+v", fuse)
	}
	if _, ok := got["github.com/loft-sh/local"]; ok {
		t.Error("a directory replacement is product code, not a fork pin")
	}
}

func TestGoForkInputsNeedsOrigin(t *testing.T) {
	g := vnodeGraph()
	dl := g.downloads["github.com/loft-sh/fuse@v0.0.0-20250416130952-0b597961e33d"]
	dl.Origin = nil
	g.downloads["github.com/loft-sh/fuse@v0.0.0-20250416130952-0b597961e33d"] = dl
	_, failures, _ := goForkInputs(g, "vnode")
	if len(failures) != 1 || !strings.Contains(failures[0], "GOPRIVATE") {
		t.Fatalf("want one failure naming the GOPRIVATE remedy, got %v", failures)
	}
}

func TestPinFromGoInput(t *testing.T) {
	pseudo := pinFromGoInput(inputRecord{Repo: "loft-sh/fuse", Version: "v0.0.0-20250416130952-0b597961e33d", Commit: fuseRev})
	if pseudo.Tag != "" || pseudo.Commit != fuseRev {
		t.Errorf("pseudo-version pin = %+v, want a commit pin", pseudo)
	}
	tagged := pinFromGoInput(inputRecord{Repo: "loft-sh/tailscale", Version: "v1.96.4-loft.3", Commit: "x"})
	if tagged.Tag != "v1.96.4-loft.3" {
		t.Errorf("tag pin = %+v, want tag v1.96.4-loft.3", tagged)
	}
	for _, v := range []string{"v1.2.4-0.20191109021931-daa7c04131f5", "v1.2.3-pre.0.20191109021931-daa7c04131f5", "v2.0.0-20191109021931-daa7c04131f5+incompatible"} {
		if !pseudoVersionRe.MatchString(v) {
			t.Errorf("%s is a pseudo-version", v)
		}
	}
}

func TestRepoFromOrigin(t *testing.T) {
	cases := map[[2]string]string{
		{"https://github.com/loft-sh/sysbox-libs", "github.com/loft-sh/sysbox-libs/utils"}: "loft-sh/sysbox-libs",
		{"", "github.com/loft-sh/sysbox-libs/utils"}:                                       "loft-sh/sysbox-libs",
		{"https://github.com/loft-sh/fuse.git", "github.com/loft-sh/fuse"}:                 "loft-sh/fuse",
	}
	for in, want := range cases {
		if got := repoFromOrigin(in[0], in[1]); got != want {
			t.Errorf("repoFromOrigin(%q, %q) = %q, want %q", in[0], in[1], got, want)
		}
	}
}

func TestDecodeModulesStream(t *testing.T) {
	var out []byte
	for _, m := range vnodeGraph().mods {
		b, _ := json.MarshalIndent(m, "", "\t")
		out = append(out, b...)
		out = append(out, '\n')
	}
	mods, err := decodeModules(out)
	if err != nil || len(mods) != len(vnodeGraph().mods) || mods[1].Replace.Path != "github.com/loft-sh/fuse" {
		t.Fatalf("decode = %v, %v", mods, err)
	}
}

// TestGoModeChecksOnlyForks runs the whole go mode: api/v4 is a loft-sh
// product repo and is listed but not checked; fuse and tailscale are forks.
func TestGoModeChecksOnlyForks(t *testing.T) {
	f := newFake()
	f.repos["loft-sh/fuse"] = repoInfo{FullName: "loft-sh/fuse", Fork: true}
	f.repos["loft-sh/api"] = repoInfo{FullName: "loft-sh/api"}
	f.repos["loft-sh/tailscale"] = repoInfo{FullName: "loft-sh/tailscale", Fork: true}
	f.upstreams["loft-sh/tailscale"] = "tailscale/tailscale"

	rc, err := check(context.Background(), f, vnodeGraph(), options{mode: "go", dirs: multiFlag{"vnode"}}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if len(rc.Inputs) != 3 {
		t.Fatalf("want 3 inputs listed, got %+v", rc.Inputs)
	}
	var checked []string
	for _, fr := range rc.Forks {
		checked = append(checked, fr.Repo)
	}
	if strings.Join(checked, ",") != "loft-sh/fuse,loft-sh/tailscale" {
		t.Fatalf("checked %v, want fuse and tailscale", checked)
	}
	if rc.Pass {
		t.Fatal("fuse has no fork-upstream property, so the run must fail")
	}
}
