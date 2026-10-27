package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// forkModulePrefix selects the modules that can carry fork code: after
// replacements, their source lives in a loft-sh repository.
const forkModulePrefix = "github.com/loft-sh/"

// pseudoVersionRe matches Go pseudo-versions (golang.org/x/mod/module), which
// pin a commit rather than a tag.
var pseudoVersionRe = regexp.MustCompile(`^v[0-9]+\.(0\.0-|\d+\.\d+-([^+]*\.)?0\.)\d{14}-[A-Za-z0-9]+(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$`)

type goModule struct {
	Path    string
	Version string
	Main    bool
	Replace *goModule
}

type goOrigin struct {
	VCS  string
	URL  string
	Hash string
}

type goDownload struct {
	Path    string
	Version string
	Sum     string
	Origin  *goOrigin
	Error   string
}

// goTool runs the go command; tests replace it.
type goTool interface {
	ListModules(dir string) ([]goModule, error)
	Download(dir, path, version string) (goDownload, error)
}

// inputRecord is one build input the receipt lists, with its hash.
type inputRecord struct {
	Kind    string `json:"kind"`
	Source  string `json:"source"`
	Module  string `json:"module,omitempty"`
	Path    string `json:"path"`
	Version string `json:"version"`
	Repo    string `json:"repo"`
	Commit  string `json:"commit"`
	Sum     string `json:"sum,omitempty"`
	Fork    bool   `json:"fork"`
}

// goForkInputs resolves the loft-sh modules in the effective module graph of
// dir to the commits Go downloaded. It reports every loft-sh module; deciding
// which of them are forks needs the GitHub API and happens in the caller.
func goForkInputs(tool goTool, dir string) ([]inputRecord, []string, error) {
	mods, err := tool.ListModules(dir)
	if err != nil {
		return nil, nil, err
	}

	var inputs []inputRecord
	var failures []string
	seen := map[string]bool{}
	for _, m := range mods {
		if m.Main {
			continue
		}
		eff := m
		if m.Replace != nil {
			if m.Replace.Version == "" {
				// A directory replacement is code in the product repository itself.
				continue
			}
			eff = *m.Replace
		}
		if !strings.HasPrefix(eff.Path, forkModulePrefix) {
			continue
		}
		key := eff.Path + "@" + eff.Version
		if seen[key] {
			continue
		}
		seen[key] = true

		rec := inputRecord{Kind: "go-module", Source: filepath.Join(dir, "go.mod"), Path: eff.Path, Version: eff.Version}
		if m.Replace != nil {
			rec.Module = m.Path
		}
		dl, err := tool.Download(dir, eff.Path, eff.Version)
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s@%s: go mod download: %v", eff.Path, eff.Version, err))
			continue
		}
		if dl.Origin == nil || dl.Origin.Hash == "" {
			failures = append(failures, fmt.Sprintf("%s@%s: Go reported no origin commit; set GOPRIVATE=github.com/loft-sh/* so it fetches from git and records the commit", eff.Path, eff.Version))
			continue
		}
		rec.Commit = dl.Origin.Hash
		rec.Sum = dl.Sum
		rec.Repo = repoFromOrigin(dl.Origin.URL, eff.Path)
		inputs = append(inputs, rec)
	}
	return inputs, failures, nil
}

// pinFromGoInput turns a resolved module into the fork pin the rules check.
// A pseudo-version pins a commit; any other version names a fork tag.
func pinFromGoInput(in inputRecord) pin {
	version := strings.TrimSuffix(in.Version, "+incompatible")
	p := pin{Repo: in.Repo, Ref: in.Version, Commit: in.Commit}
	if !pseudoVersionRe.MatchString(in.Version) {
		p.Tag = version
	}
	return p
}

// repoFromOrigin names the repository Go fetched from, falling back to the
// first two path elements after github.com.
func repoFromOrigin(url, path string) string {
	u := strings.TrimSuffix(strings.TrimPrefix(strings.TrimPrefix(url, "https://"), "http://"), ".git")
	if strings.HasPrefix(u, "github.com/") {
		path = u
	}
	parts := strings.Split(strings.TrimPrefix(path, "github.com/"), "/")
	if len(parts) < 2 {
		return ""
	}
	return parts[0] + "/" + parts[1]
}

// verifyVendor checks the committed vendor tree using a caller-provided
// verifier in a temporary clone. The verifier is trusted code, not sandboxed.
func verifyVendor(dir, verifier string) error {
	// Workspace vendoring belongs to the workspace root, not an individual
	// module. Do not certify it with a module-scoped verifier.
	if st, err := os.Stat(dir); err == nil && st.IsDir() {
		out, err := runGo(dir, "env", "GOWORK")
		if err != nil {
			return fmt.Errorf("detect Go workspace: %w", err)
		}
		workspace := strings.TrimSpace(string(out))
		if workspace != "" && workspace != "off" {
			path := filepath.Join(filepath.Dir(workspace), "vendor")
			if _, err := os.Lstat(path); err == nil {
				return fmt.Errorf("workspace vendor tree %s requires workspace verification, which is not supported", path)
			} else if !errors.Is(err, os.ErrNotExist) {
				return fmt.Errorf("inspect workspace vendor tree: %w", err)
			}
		}
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect module directory: %w", err)
	}
	vendor := filepath.Join(dir, "vendor")
	info, err := os.Lstat(vendor)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect vendor tree: %w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("vendor path %s is not a directory", vendor)
	}
	if strings.TrimSpace(verifier) == "" {
		return fmt.Errorf("%s exists: configure a trusted vendor verifier", vendor)
	}
	module, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return fmt.Errorf("resolve module directory: %w", err)
	}
	module, err = filepath.Abs(module)
	if err != nil {
		return err
	}
	runGit := func(at string, args ...string) ([]byte, error) {
		cmd := exec.Command("git", args...)
		cmd.Dir = at
		out, err := cmd.CombinedOutput()
		if err != nil {
			return nil, fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
		}
		return out, nil
	}
	out, err := runGit(module, "rev-parse", "--show-toplevel")
	if err != nil {
		return fmt.Errorf("vendor verification needs a Git checkout: %w", err)
	}
	root, err := filepath.EvalSymlinks(strings.TrimSpace(string(out)))
	if err != nil {
		return err
	}
	rel, err := filepath.Rel(root, module)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return fmt.Errorf("module directory is outside its Git checkout")
	}
	// A clean checkout binds the clone to the source the build will consume.
	// Include ignored vendor files: Git's normal status hides them, but Go can
	// still compile them. Do not follow symlinks outside the checkout.
	clean := func() error {
		status, err := runGit(root, "status", "--porcelain", "--untracked-files=all")
		if err != nil {
			return err
		}
		if len(status) != 0 {
			return fmt.Errorf("vendor verification requires a clean checkout")
		}
		status, err = runGit(root, "status", "--porcelain", "--untracked-files=all", "--ignored", "--", filepath.Join(rel, "vendor"))
		if err != nil {
			return err
		}
		if len(status) != 0 {
			return fmt.Errorf("vendor tree contains uncommitted or ignored files")
		}
		return nil
	}
	if err := clean(); err != nil {
		return err
	}
	err = filepath.WalkDir(filepath.Join(module, "vendor"), func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.Type()&os.ModeSymlink == 0 {
			return nil
		}
		target, err := filepath.EvalSymlinks(path)
		if err != nil {
			return fmt.Errorf("resolve vendor symlink %s: %w", path, err)
		}
		r, err := filepath.Rel(root, target)
		if err != nil || r == ".." || strings.HasPrefix(r, ".."+string(filepath.Separator)) {
			return fmt.Errorf("vendor symlink %s points outside the checkout", path)
		}
		status, err := runGit(root, "status", "--porcelain", "--untracked-files=all", "--ignored", "--", r)
		if err != nil {
			return err
		}
		if len(status) != 0 {
			return fmt.Errorf("vendor symlink target %s contains uncommitted or ignored files", path)
		}
		return nil
	})
	if err != nil {
		return err
	}
	head, err := runGit(root, "rev-parse", "--verify", "HEAD")
	if err != nil {
		return err
	}
	tmp, err := os.MkdirTemp("", "fork-review-vendor-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	clone := filepath.Join(tmp, "checkout")
	if _, err := runGit(root, "-c", "core.hooksPath=/dev/null", "clone", "--no-hardlinks", "--no-checkout", "--", root, clone); err != nil {
		return err
	}
	if _, err := runGit(clone, "-c", "core.hooksPath=/dev/null", "checkout", "--detach", strings.TrimSpace(string(head))); err != nil {
		return err
	}
	if err := clean(); err != nil {
		return err
	}
	current, err := runGit(root, "rev-parse", "--verify", "HEAD")
	if err != nil {
		return err
	}
	if !bytes.Equal(head, current) {
		return fmt.Errorf("checkout HEAD changed during vendor verification")
	}
	cmd := exec.Command("sh", "-c", verifier)
	cmd.Dir = filepath.Join(clone, rel)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("vendor verifier failed: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

type execGo struct{}

func (execGo) ListModules(dir string) ([]goModule, error) {
	args := []string{"list", "-m", "-json"}
	// With a vendor directory and no workspace, go list cannot compute "all"
	// from vendor/modules.txt. The vendor verifier checks that source separately.
	if exists(filepath.Join(dir, "vendor")) {
		work, err := runGo(dir, "env", "GOWORK")
		if err != nil {
			return nil, fmt.Errorf("detect Go workspace: %w", err)
		}
		if strings.TrimSpace(string(work)) == "" || strings.TrimSpace(string(work)) == "off" {
			args = append(args, "-mod=mod")
		}
	}
	args = append(args, "all")
	out, err := runGo(dir, args...)
	if err != nil {
		return nil, err
	}
	return decodeModules(out)
}

func (execGo) Download(dir, path, version string) (goDownload, error) {
	out, err := runGo(dir, "mod", "download", "-json", path+"@"+version)
	var dl goDownload
	if jerr := json.Unmarshal(out, &dl); jerr != nil {
		if err != nil {
			return dl, err
		}
		return dl, jerr
	}
	if dl.Error != "" {
		return dl, errors.New(dl.Error)
	}
	return dl, err
}

func decodeModules(out []byte) ([]goModule, error) {
	var mods []goModule
	dec := json.NewDecoder(bytes.NewReader(out))
	for {
		var m goModule
		err := dec.Decode(&m)
		if errors.Is(err, io.EOF) {
			return mods, nil
		}
		if err != nil {
			return nil, fmt.Errorf("decode go list output: %w", err)
		}
		mods = append(mods, m)
	}
}

func runGo(dir string, args ...string) ([]byte, error) {
	cmd := exec.Command("go", args...)
	cmd.Dir = dir
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return out, fmt.Errorf("go %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
