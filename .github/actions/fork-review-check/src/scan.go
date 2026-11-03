package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var scanRepoRe = regexp.MustCompile(`(github\.com|ghcr\.io)/loft-sh/([A-Za-z0-9._-]+)`)
var scanVarRe = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)`)

// scanCheckoutRe matches actions/checkout's repository input, a source clone
// that names the fork without a github.com prefix.
var scanCheckoutRe = regexp.MustCompile(`^(?:-\s*)?repository:\s*["']?loft-sh/([A-Za-z0-9._-]+)`)

func scanFile(path string) bool {
	name := filepath.Base(path)
	switch {
	case name == "go.mod", name == "go.work", name == "Makefile":
		return true
	case name == "Dockerfile", strings.HasPrefix(name, "Dockerfile."):
		return true
	case strings.HasSuffix(name, ".Dockerfile"), strings.HasSuffix(name, ".dockerfile"):
		return true
	case strings.HasSuffix(name, ".sh"), strings.HasSuffix(name, ".mk"):
		return true
	case name == ".goreleaser.yml", name == ".goreleaser.yaml":
		return true
	}
	return scanWorkflow(path)
}

func scanWorkflow(path string) bool {
	name := filepath.Base(path)
	return strings.Contains("/"+filepath.ToSlash(path), "/.github/workflows/") &&
		(strings.HasSuffix(name, ".yml") || strings.HasSuffix(name, ".yaml"))
}

func scanComment(path, line string) bool {
	line = strings.TrimSpace(line)
	switch filepath.Base(path) {
	case "go.mod", "go.work":
		return strings.HasPrefix(line, "//")
	default:
		return strings.HasPrefix(line, "#")
	}
}

func scanExpand(value string, args map[string]string) string {
	return scanVarRe.ReplaceAllStringFunc(value, func(variable string) string {
		name := strings.TrimPrefix(variable, "$")
		name = strings.TrimSuffix(strings.TrimPrefix(name, "{"), "}")
		if value, ok := args[name]; ok {
			return value
		}
		return variable
	})
}

func scanArg(line string, args map[string]string) {
	fields := strings.Fields(line)
	if len(fields) < 2 || !strings.EqualFold(fields[0], "ARG") {
		return
	}
	name, value, ok := strings.Cut(strings.TrimSpace(line[len(fields[0]):]), "=")
	if ok {
		args[strings.TrimSpace(name)] = scanExpand(strings.Trim(value, `"'`), args)
	}
}

func scanImage(line, repo string) string {
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return ""
	}
	var image string
	switch {
	case strings.EqualFold(fields[0], "FROM"):
		for _, field := range fields[1:] {
			if !strings.HasPrefix(field, "--") {
				image = strings.Trim(field, `"'`)
				break
			}
		}
	case strings.EqualFold(fields[0], "COPY"):
		for _, field := range fields[1:] {
			if strings.HasPrefix(field, "--from=") {
				image = strings.Trim(strings.TrimPrefix(field, "--from="), `"'`)
				break
			}
		}
	}
	match := scanRepoRe.FindStringSubmatch(image)
	if len(match) != 3 || "loft-sh/"+strings.TrimSuffix(match[2], ".git") != repo {
		return ""
	}
	if !strings.HasPrefix(image, "ghcr.io/") {
		return ""
	}
	return image
}

func scanSource(line string) (string, bool) {
	fields := strings.Fields(line)
	git, clone := false, false
	for _, field := range fields {
		git = git || field == "git"
		clone = clone || field == "clone"
	}
	if !git || !clone {
		return "", false
	}
	for i, field := range fields {
		if (field == "-b" || field == "--branch") && i+1 < len(fields) {
			return strings.Trim(fields[i+1], `"'`), true
		}
		if strings.HasPrefix(field, "--branch=") {
			return strings.Trim(strings.TrimPrefix(field, "--branch="), `"'`), true
		}
	}
	return "", true
}

func sourceParts(value string) (string, string, error) {
	repo, ref, ok := strings.Cut(value, "=")
	if !ok || !validRepo(repo) || ref == "" {
		return "", "", fmt.Errorf("-source %q: want fork=tag-or-full-SHA", value)
	}
	return repo, ref, nil
}

// fork caches scan discovery. A GitHub 404 is not a fork: ghcr image names do
// not necessarily identify GitHub repositories.
func (r *inputResolver) fork(repo string) (bool, error) {
	if r.forks == nil {
		return isFork(r.ctx, r.api, repo)
	}
	if fork, ok := r.forks[repo]; ok {
		return fork, nil
	}
	info, err := r.api.Repo(r.ctx, repo)
	if isNotFound(err) {
		r.forks[repo] = false
		return false, nil
	}
	if err != nil {
		return false, err
	}
	fork := info.Fork
	if !fork {
		upstream, err := r.api.ForkUpstream(r.ctx, repo)
		if err != nil {
			return false, err
		}
		fork = upstream != ""
	}
	r.forks[repo] = fork
	return fork, nil
}

// imageRepo returns the repository that publishes ghcr.io/loft-sh/<name>: the
// repository of the same name, else the one GitHub links the package to. It
// is "" when neither exists. A failed package lookup is a rule failure, since
// the image could come from a fork.
func (r *inputResolver) imageRepo(name string) (string, string, error) {
	repo := "loft-sh/" + name
	if published, ok := r.published[repo]; ok {
		return published, "", nil
	}
	published := repo
	if _, err := r.api.Repo(r.ctx, repo); isNotFound(err) {
		published, err = r.api.PackageRepo(r.ctx, "loft-sh", name)
		if err != nil {
			return "", fmt.Sprintf("cannot tell which repository publishes ghcr.io/%s: %v", repo, err), nil
		}
	} else if err != nil {
		return "", "", fmt.Errorf("read %s: %w", repo, err)
	}
	r.published[repo] = published
	return published, "", nil
}

func (r *inputResolver) scan(opts options) error {
	r.forks = map[string]bool{}
	r.published = map[string]string{}
	covered := map[string]bool{}
	for _, source := range opts.images {
		if ref, failure := parseImageReference(source); failure == "" {
			covered["image:"+ref.Repo] = true
		}
	}
	for _, source := range opts.urls {
		if ref, failure := parseBinaryReference(source); failure == "" {
			covered["binary:"+ref.Repo] = true
		}
	}
	for _, source := range opts.sources {
		repo, _, err := sourceParts(source)
		if err != nil {
			return err
		}
		covered["source:"+repo] = true
	}

	if err := r.goDirs(opts.dirs); err != nil {
		return err
	}
	if err := r.images(opts.images); err != nil {
		return err
	}
	if err := r.binaries(opts.urls, opts.sha256); err != nil {
		return err
	}
	if err := r.sources(opts.sources, "-source"); err != nil {
		return err
	}

	goDirs := map[string]bool{}
	for _, dir := range opts.dirs {
		abs, err := filepath.Abs(dir)
		if err != nil {
			return err
		}
		goDirs[abs] = true
	}
	root := opts.root
	if root == "" {
		root = "."
	}
	return filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return fmt.Errorf("scan %s: %w", path, walkErr)
		}
		if entry.IsDir() {
			switch entry.Name() {
			case ".git", "vendor", "node_modules", "testdata":
				return filepath.SkipDir
			}
			return nil
		}
		if !entry.Type().IsRegular() || !scanFile(path) {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("read build input %s: %w", path, err)
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		args := map[string]string{}
		for i, raw := range strings.Split(string(data), "\n") {
			if scanComment(path, raw) {
				continue
			}
			line := strings.TrimSpace(raw)
			scanArg(line, args)
			line = scanExpand(line, args)
			location := fmt.Sprintf("%s:%d", filepath.ToSlash(rel), i+1)
			if match := scanCheckoutRe.FindStringSubmatch(line); match != nil && scanWorkflow(path) {
				repo := "loft-sh/" + strings.TrimSuffix(match[1], ".git")
				fork, err := r.fork(repo)
				if err != nil {
					return fmt.Errorf("read %s: %w", repo, err)
				}
				if fork {
					r.cover(location, "source", repo, "source", covered)
				}
			}
			for _, match := range scanRepoRe.FindAllStringSubmatchIndex(line, -1) {
				repo := "loft-sh/" + strings.TrimSuffix(line[match[4]:match[5]], ".git")
				if line[match[2]:match[3]] == "ghcr.io" {
					published, failure, err := r.imageRepo(strings.TrimPrefix(repo, "loft-sh/"))
					if err != nil {
						return err
					}
					if failure != "" {
						r.rc.Failures = append(r.rc.Failures, location+": "+failure)
						continue
					}
					if published == "" {
						continue
					}
					if published != repo {
						fork, err := r.fork(published)
						if err != nil {
							return fmt.Errorf("read %s: %w", published, err)
						}
						if fork {
							r.rc.Failures = append(r.rc.Failures, fmt.Sprintf(
								"%s: image ghcr.io/%s is published by fork %s under another name, which no resolver understands",
								location, repo, published))
						}
						continue
					}
				}
				fork, err := r.fork(repo)
				if err != nil {
					return fmt.Errorf("read %s: %w", repo, err)
				}
				if !fork {
					continue
				}
				suffix := line[match[1]:]
				if scanLink(suffix) {
					continue
				}
				if name := filepath.Base(path); name == "go.mod" || name == "go.work" {
					dir, err := filepath.Abs(filepath.Dir(path))
					if err != nil {
						return err
					}
					if !goDirs[dir] {
						goDirs[dir] = true
						if err := r.goDirs([]string{dir}); err != nil {
							return err
						}
					}
					continue
				}
				if strings.HasPrefix(suffix, "/releases/download/") {
					r.cover(location, "binary", repo, "url", covered)
					continue
				}
				if image := scanImage(line, repo); image != "" {
					if _, failure := parseImageReference(image); failure == "" {
						if err := r.images([]string{image}); err != nil {
							return err
						}
						continue
					}
					r.cover(location, "image", repo, "image", covered)
					continue
				}
				if ref, clone := scanSource(line); clone {
					if ref != "" && !strings.Contains(ref, "$") {
						if err := r.sources([]string{repo + "=" + ref}, location); err != nil {
							return err
						}
						continue
					}
					r.cover(location, "source", repo, "source", covered)
					continue
				}
				r.rc.Failures = append(r.rc.Failures,
					fmt.Sprintf("%s: reference to fork %s that no resolver understands", location, repo))
			}
		}
		return nil
	})
}

func (r *inputResolver) cover(location, form, repo, flag string, covered map[string]bool) {
	if !covered[form+":"+repo] {
		r.rc.Failures = append(r.rc.Failures,
			fmt.Sprintf("%s: %s reference to %s is not pinned in the file; pass it with -%s",
				location, form, repo, flag))
	}
}

func scanLink(suffix string) bool {
	for _, prefix := range []string{
		"/releases/tag/", "/blob/", "/tree/", "/pull/", "/issues/", "/commit/",
	} {
		if strings.HasPrefix(suffix, prefix) {
			return true
		}
	}
	return false
}
