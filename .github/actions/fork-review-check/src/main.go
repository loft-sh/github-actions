// Command fork-review-check verifies that every fork commit a product build
// consumes reached its loft-sh fork through a merged pull request approved by
// someone other than its author (loft-sh/architecture,
// engineering-enablement/designs/fork-review-check.md).
//
// For each fork commit S it walks the range from the trusted upstream base to
// S and applies the design's rules:
//
//  1. S is the approved final head, or the merge result, of a merged fork PR.
//  2. Every commit in the range belongs to a merged fork PR approved at its
//     final head, after its last force push, by someone with write or higher
//     permission on the fork who is neither the PR author nor the commit author.
//  3. With -as-of, every approval predates that time (the product release).
//  4. It fails and names every commit that breaks a rule.
//
// It reads GitHub, the go command and attestation evidence. For vendored modules,
// it runs a trusted verifier in a temporary checkout. It can write a receipt and
// temporary downloaded release assets.
//
//	fork-review-check ref -repo loft-sh/kine -ref v0.16.5.vcluster.1
//	fork-review-check go -dir . -dir ./sub
//	fork-review-check scan -root .
//	fork-review-check image -image ghcr.io/loft-sh/kine:v0.16.5.vcluster.1@sha256:...
//	fork-review-check binary -url https://github.com/loft-sh/kine/releases/download/v0.16.5.vcluster.1/kine -sha256 ...
//
// Exit codes: 0 pass (or -advisory), 1 a rule failed, 2 the check could not run.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/google/go-github/v88/github"
)

// version is stamped into every receipt; the action overrides it with the ref
// it runs from.
var version = "dev"

const receiptSchema = "fork-review-check/v1"

type receipt struct {
	Schema     string        `json:"schema"`
	CLIVersion string        `json:"cli_version"`
	Mode       string        `json:"mode"`
	CheckedAt  time.Time     `json:"checked_at"`
	AsOf       *time.Time    `json:"as_of,omitempty"`
	Inputs     []inputRecord `json:"inputs"`
	Forks      []forkResult  `json:"forks"`
	Failures   []string      `json:"failures,omitempty"`
	Pass       bool          `json:"pass"`
}

// multiFlag collects a repeatable string flag.
type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

type options struct {
	mode            string
	repo            string
	ref             string
	root            string
	sources         multiFlag
	dirs            multiFlag
	vendorVerifier  string
	images          multiFlag
	urls            multiFlag
	sha256          multiFlag
	upstreams       multiFlag
	signerWorkflows multiFlag
	asOf            string
	receipt         string
	advisory        bool
}

func main() {
	log.SetFlags(0)
	os.Exit(run(os.Args[1:], os.Stdout))
}

func run(args []string, stdout io.Writer) int {
	opts, err := parseArgs(args)
	if err != nil {
		log.Printf("::error::%v", err)
		return 2
	}

	token := os.Getenv("GITHUB_TOKEN")
	if token == "" {
		log.Print("::error::GITHUB_TOKEN is required")
		return 2
	}
	gh, err := github.NewClient(github.WithAuthToken(token))
	if err != nil {
		log.Printf("::error::create github client: %v", err)
		return 2
	}

	rc, err := check(context.Background(), githubAPI{gh: gh}, execGo{}, execAttest{}, execDownload{}, opts, time.Now().UTC())
	if err != nil {
		log.Printf("::error::%v", err)
		return 2
	}
	if v := os.Getenv("FORK_REVIEW_CHECK_VERSION"); v != "" {
		rc.CLIVersion = v
	}

	if err := writeReceipt(rc, opts.receipt); err != nil {
		log.Printf("::error::write receipt: %v", err)
		return 2
	}
	report := renderText(rc)
	fmt.Fprint(stdout, report)
	appendSummary(renderMarkdown(rc))

	if rc.Pass {
		return 0
	}
	if opts.advisory {
		log.Print("::warning::fork review check failed; advisory mode, not blocking")
		return 0
	}
	log.Print("::error::fork review check failed")
	return 1
}

func parseArgs(args []string) (options, error) {
	var opts options
	if len(args) == 0 {
		return opts, errors.New("usage: fork-review-check ref|go|image|binary|scan [flags]")
	}
	opts.mode = args[0]

	fs := flag.NewFlagSet("fork-review-check "+opts.mode, flag.ContinueOnError)
	fs.StringVar(&opts.repo, "repo", "", "ref mode: fork repository, owner/name")
	fs.StringVar(&opts.ref, "ref", "", "ref mode: fork release tag or commit SHA")
	fs.StringVar(&opts.root, "root", ".", "scan mode: root directory to inspect")
	fs.Var(&opts.dirs, "dir", "go mode: module directory to resolve (repeatable)")
	fs.Var(&opts.images, "image", "image mode: digest-pinned ghcr.io fork image (repeatable)")
	fs.Var(&opts.urls, "url", "binary mode: GitHub release asset URL (repeatable)")
	fs.Var(&opts.sha256, "sha256", "binary mode: release asset SHA-256, paired with -url (repeatable)")
	fs.Var(&opts.sources, "source", "scan mode: fork=tag-or-full-SHA source clone pin (repeatable)")
	fs.StringVar(&opts.vendorVerifier, "vendor-verifier", "", "go and scan modes: trusted command to verify vendor in an isolated checkout")
	fs.Var(&opts.upstreams, "upstream", "fork=upstream[@branch] used when a fork has no fork-upstream property; in ref mode a bare upstream applies to -repo (repeatable)")
	fs.Var(&opts.signerWorkflows, "signer-workflow", "fork=workflow path used to verify an image or binary (repeatable)")
	fs.StringVar(&opts.asOf, "as-of", "", "RFC 3339 time every approval must predate (rule 3), normally the product release time")
	fs.StringVar(&opts.receipt, "receipt", "", "write the JSON receipt to this path")
	fs.BoolVar(&opts.advisory, "advisory", false, "report failures as warnings and exit 0")
	if err := fs.Parse(args[1:]); err != nil {
		return opts, err
	}

	switch opts.mode {
	case "scan":
		if len(opts.urls) != len(opts.sha256) {
			return opts, errors.New("scan mode needs paired -url and -sha256 flags")
		}
	case "ref":
		if opts.repo == "" || opts.ref == "" {
			return opts, errors.New("ref mode needs -repo and -ref")
		}
	case "go":
		if len(opts.dirs) == 0 {
			opts.dirs = multiFlag{"."}
		}
	case "image":
		if len(opts.images) == 0 {
			return opts, errors.New("image mode needs -image")
		}
	case "binary":
		if len(opts.urls) == 0 || len(opts.sha256) == 0 || len(opts.urls) != len(opts.sha256) {
			return opts, errors.New("binary mode needs paired -url and -sha256 flags")
		}
	default:
		return opts, fmt.Errorf("unknown mode %q: want ref, go, image, binary or scan", opts.mode)
	}
	return opts, nil
}

type inputResolver struct {
	ctx            context.Context
	api            forkAPI
	tool           goTool
	attest         attestTool
	download       downloadTool
	vendorVerifier string
	signers        map[string]string
	rc             *receipt
	pins           []pin
	forks          map[string]bool
	// published maps a ghcr.io/loft-sh image name to the repository that publishes it.
	published map[string]string
}

func (r *inputResolver) add(p pin, in inputRecord, failure string, err error) error {
	if err != nil {
		return err
	}
	if failure != "" {
		r.rc.Failures = append(r.rc.Failures, failure)
		return nil
	}
	r.pins = append(r.pins, p)
	r.rc.Inputs = append(r.rc.Inputs, in)
	return nil
}

func (r *inputResolver) goDirs(dirs []string) error {
	for _, dir := range dirs {
		if err := verifyVendor(dir, r.vendorVerifier); err != nil {
			r.rc.Failures = append(r.rc.Failures, fmt.Sprintf("%s: verify vendor: %v", dir, err))
			continue
		}
		inputs, failures, err := goForkInputs(r.tool, dir)
		if err != nil {
			return err
		}
		r.rc.Failures = append(r.rc.Failures, failures...)
		for _, in := range inputs {
			fork, err := r.fork(in.Repo)
			if err != nil {
				return fmt.Errorf("read %s: %w", in.Repo, err)
			}
			in.Fork = fork
			r.rc.Inputs = append(r.rc.Inputs, in)
			if fork {
				r.pins = append(r.pins, pinFromGoInput(in))
			}
		}
	}
	return nil
}

func (r *inputResolver) images(sources []string) error {
	for _, source := range sources {
		if err := r.add(imagePin(r.ctx, r.api, r.attest, r.signers, source)); err != nil {
			return err
		}
	}
	return nil
}

func (r *inputResolver) binaries(urls, hashes []string) error {
	if len(urls) != len(hashes) {
		return errors.New("binary inputs need paired -url and -sha256 flags")
	}
	for i, source := range urls {
		if err := r.add(binaryPin(r.ctx, r.api, r.attest, r.download, r.signers, source, hashes[i])); err != nil {
			return err
		}
	}
	return nil
}

func (r *inputResolver) sources(values []string, source string) error {
	for _, value := range values {
		repo, ref, err := sourceParts(value)
		if err != nil {
			return err
		}
		p, failure, err := refPin(r.ctx, r.api, repo, ref)
		in := inputRecord{
			Kind:    "fork-source",
			Source:  source,
			Path:    repo,
			Version: ref,
			Repo:    repo,
			Commit:  p.Commit,
			Fork:    true,
		}
		if err := r.add(p, in, failure, err); err != nil {
			return err
		}
	}
	return nil
}

// check resolves the pins for the mode and evaluates every fork.
func check(ctx context.Context, api forkAPI, tool goTool, attest attestTool, download downloadTool, opts options, now time.Time) (receipt, error) {
	rc := receipt{Schema: receiptSchema, CLIVersion: version, Mode: opts.mode, CheckedAt: now, Inputs: []inputRecord{}, Forks: []forkResult{}}

	var asOf time.Time
	if opts.asOf != "" {
		t, err := time.Parse(time.RFC3339, opts.asOf)
		if err != nil {
			return rc, fmt.Errorf("parse -as-of: %w", err)
		}
		asOf = t.UTC()
		rc.AsOf = &asOf
	}
	overrides, err := parseUpstreams(opts.upstreams, opts.repo)
	if err != nil {
		return rc, err
	}
	signers, err := parseSignerWorkflows(opts.signerWorkflows)
	if err != nil {
		return rc, err
	}

	r := inputResolver{
		ctx: ctx, api: api, tool: tool, attest: attest, download: download,
		signers: signers, rc: &rc, vendorVerifier: opts.vendorVerifier,
	}
	switch opts.mode {
	case "ref":
		p, failure, err := refPin(ctx, api, opts.repo, opts.ref)
		in := inputRecord{
			Kind:    "fork-ref",
			Source:  "-ref",
			Path:    opts.repo,
			Version: opts.ref,
			Repo:    opts.repo,
			Commit:  p.Commit,
			Fork:    true,
		}
		if err := r.add(p, in, failure, err); err != nil {
			return rc, err
		}
	case "go":
		if err := r.goDirs(opts.dirs); err != nil {
			return rc, err
		}
	case "image":
		if err := r.images(opts.images); err != nil {
			return rc, err
		}
	case "binary":
		if err := r.binaries(opts.urls, opts.sha256); err != nil {
			return rc, err
		}
	case "scan":
		if err := r.scan(opts); err != nil {
			return rc, err
		}
	}
	if opts.mode == "scan" {
		sort.Strings(rc.Failures)
	}

	c := newChecker(api, asOf, overrides)
	seen := map[string]bool{}
	for _, p := range r.pins {
		key := p.Repo + "@" + p.Commit + "@" + p.Tag
		if seen[key] {
			continue
		}
		seen[key] = true
		rc.Forks = append(rc.Forks, c.checkFork(ctx, p))
	}
	sort.SliceStable(rc.Forks, func(i, j int) bool { return rc.Forks[i].Repo < rc.Forks[j].Repo })

	rc.Pass = len(rc.Failures) == 0
	for _, f := range rc.Forks {
		if !f.Pass {
			rc.Pass = false
		}
	}
	return rc, nil
}

// refPin resolves a fork ref given by hand: a tag, or a full commit SHA.
func refPin(ctx context.Context, api forkAPI, repo, ref string) (pin, string, error) {
	sha, err := api.ResolveTag(ctx, repo, ref)
	if err != nil {
		return pin{}, "", fmt.Errorf("resolve %s in %s: %w", ref, repo, err)
	}
	if sha != "" {
		return pin{Repo: repo, Ref: ref, Tag: ref, Commit: sha}, "", nil
	}
	if fullSHARe.MatchString(ref) {
		return pin{Repo: repo, Ref: ref, Commit: ref}, "", nil
	}
	return pin{}, fmt.Sprintf("%s has no tag %s, and it is not a full commit SHA", repo, ref), nil
}

// isFork reports whether a loft-sh repository holds fork code: GitHub marks
// it a fork, or an org owner gave it a fork-upstream property.
func isFork(ctx context.Context, api forkAPI, repo string) (bool, error) {
	info, err := api.Repo(ctx, repo)
	if err != nil {
		return false, err
	}
	if info.Fork {
		return true, nil
	}
	upstream, err := api.ForkUpstream(ctx, repo)
	return upstream != "", err
}

func parseUpstreams(values []string, refRepo string) (map[string]upstreamOverride, error) {
	out := map[string]upstreamOverride{}
	for _, v := range values {
		fork, upstream, ok := strings.Cut(v, "=")
		if !ok {
			if refRepo == "" {
				return nil, fmt.Errorf("-upstream %q: want fork=upstream outside ref mode", v)
			}
			fork, upstream = refRepo, v
		}
		repo, branch, _ := strings.Cut(upstream, "@")
		if !strings.Contains(fork, "/") || !strings.Contains(repo, "/") {
			return nil, fmt.Errorf("-upstream %q: repositories are owner/name", v)
		}
		out[fork] = upstreamOverride{Repo: repo, Ref: branch}
	}
	return out, nil
}

func writeReceipt(rc receipt, path string) error {
	if path == "" {
		return nil
	}
	data, err := json.MarshalIndent(rc, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(data, '\n'), 0o644)
}

// appendSummary writes to the job summary when running in Actions.
func appendSummary(md string) {
	path := os.Getenv("GITHUB_STEP_SUMMARY")
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		log.Printf("::warning::write job summary: %v", err)
		return
	}
	defer f.Close()
	_, _ = f.WriteString(md)
}
