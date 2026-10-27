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
	Kind           string `json:"kind"`
	Source         string `json:"source"`
	Module         string `json:"module,omitempty"`
	Path           string `json:"path"`
	Version        string `json:"version"`
	Repo           string `json:"repo"`
	Commit         string `json:"commit"`
	Sum            string `json:"sum,omitempty"`
	Digest         string `json:"digest,omitempty"`
	SHA256         string `json:"sha256,omitempty"`
	SignerWorkflow string `json:"signer_workflow,omitempty"`
	Fork           bool   `json:"fork"`
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

type execGo struct{}

func (execGo) ListModules(dir string) ([]goModule, error) {
	args := []string{"list", "-m", "-json"}
	// With a vendor directory and no workspace, go list cannot compute "all"
	// from vendor/modules.txt. Go already checks that file against go.mod, so
	// reading the graph from go.mod yields the same versions.
	if exists(filepath.Join(dir, "vendor")) && os.Getenv("GOWORK") != "off" && !exists(filepath.Join(dir, "go.work")) {
		args = append(args, "-mod=mod")
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
