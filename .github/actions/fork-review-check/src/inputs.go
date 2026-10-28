package main

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"regexp"
	"strings"
)

var imageDigestRe = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
var sha256Re = regexp.MustCompile(`^[0-9a-f]{64}$`)

type imageReference struct {
	Repo   string
	Owner  string
	Tag    string
	Digest string
}

type binaryReference struct {
	Repo string
	Tag  string
	URL  string
}

func parseSignerWorkflows(values []string) (map[string]string, error) {
	out := map[string]string{}
	for _, value := range values {
		repo, workflow, ok := strings.Cut(value, "=")
		if !ok || !validRepo(repo) || workflow == "" {
			return nil, fmt.Errorf("-signer-workflow %q: want fork=workflow path", value)
		}
		out[repo] = workflow
	}
	return out, nil
}

func imagePin(ctx context.Context, api forkAPI, attest attestTool, signers map[string]string, source string) (pin, inputRecord, string, error) {
	ref, failure := parseImageReference(source)
	if failure != "" {
		return pin{}, inputRecord{}, failure, nil
	}
	workflow, failure := signerWorkflow(signers, ref.Repo)
	if failure != "" {
		return pin{}, inputRecord{}, fmt.Sprintf("image %s: %s", source, failure), nil
	}
	commit, err := api.ResolveTag(ctx, ref.Repo, ref.Tag)
	if err != nil {
		return pin{}, inputRecord{}, "", fmt.Errorf("resolve image tag %s in %s: %w", ref.Tag, ref.Repo, err)
	}
	if commit == "" {
		return pin{}, inputRecord{}, fmt.Sprintf("image %s: %s has no tag %s", source, ref.Repo, ref.Tag), nil
	}
	if err := attest.Verify(ctx, "oci://"+source, attestArgs{
		Owner:          ref.Owner,
		SignerWorkflow: workflow,
		SignerDigest:   commit,
		SourceDigest:   commit,
		SourceRef:      "refs/tags/" + ref.Tag,
	}); err != nil {
		return pin{}, inputRecord{}, fmt.Sprintf("image %s: verify provenance: %v", source, err), nil
	}
	return pin{Repo: ref.Repo, Ref: ref.Tag, Tag: ref.Tag, Commit: commit}, inputRecord{
		Kind:           "image",
		Source:         source,
		Path:           "ghcr.io/" + ref.Repo,
		Version:        ref.Tag,
		Repo:           ref.Repo,
		Commit:         commit,
		Digest:         ref.Digest,
		SignerWorkflow: workflow,
		Fork:           true,
	}, "", nil
}

func binaryPin(ctx context.Context, api forkAPI, attest attestTool, download downloadTool, signers map[string]string, source, want string) (pin, inputRecord, string, error) {
	ref, failure := parseBinaryReference(source)
	if failure != "" {
		return pin{}, inputRecord{}, failure, nil
	}
	if !sha256Re.MatchString(want) {
		return pin{}, inputRecord{}, fmt.Sprintf("binary %s: -sha256 must be 64 lowercase hexadecimal characters", source), nil
	}
	workflow, failure := signerWorkflow(signers, ref.Repo)
	if failure != "" {
		return pin{}, inputRecord{}, fmt.Sprintf("binary %s: %s", source, failure), nil
	}

	path, err := download.Download(ctx, source)
	if err != nil {
		return pin{}, inputRecord{}, "", fmt.Errorf("download binary %s: %w", source, err)
	}
	defer os.Remove(path)
	got, err := sha256File(path)
	if err != nil {
		return pin{}, inputRecord{}, "", fmt.Errorf("hash binary %s: %w", source, err)
	}
	if got != want {
		return pin{}, inputRecord{}, fmt.Sprintf("binary %s: sha256 is %s, want %s", source, got, want), nil
	}

	commit, err := api.ResolveTag(ctx, ref.Repo, ref.Tag)
	if err != nil {
		return pin{}, inputRecord{}, "", fmt.Errorf("resolve binary tag %s in %s: %w", ref.Tag, ref.Repo, err)
	}
	if commit == "" {
		return pin{}, inputRecord{}, fmt.Sprintf("binary %s: %s has no tag %s", source, ref.Repo, ref.Tag), nil
	}
	if err := attest.Verify(ctx, path, attestArgs{
		Repo:           ref.Repo,
		SignerWorkflow: workflow,
		SignerDigest:   commit,
		SourceDigest:   commit,
		SourceRef:      "refs/tags/" + ref.Tag,
	}); err != nil {
		return pin{}, inputRecord{}, fmt.Sprintf("binary %s: verify provenance: %v", source, err), nil
	}
	return pin{Repo: ref.Repo, Ref: ref.Tag, Tag: ref.Tag, Commit: commit}, inputRecord{
		Kind:           "binary",
		Source:         source,
		Path:           source,
		Version:        ref.Tag,
		Repo:           ref.Repo,
		Commit:         commit,
		SHA256:         want,
		SignerWorkflow: workflow,
		Fork:           true,
	}, "", nil
}

func parseImageReference(source string) (imageReference, string) {
	image, digest, ok := strings.Cut(source, "@")
	if !ok || !imageDigestRe.MatchString(digest) {
		return imageReference{}, fmt.Sprintf("image %s needs both a fork tag and sha256 digest", source)
	}
	name, tag, ok := strings.Cut(image, ":")
	parts := strings.Split(name, "/")
	if !ok || len(parts) != 3 || parts[0] != "ghcr.io" || !validRepo(parts[1]+"/"+parts[2]) || !forkTagRe.MatchString(tag) {
		return imageReference{}, fmt.Sprintf("unknown fork image reference %s", source)
	}
	return imageReference{Repo: parts[1] + "/" + parts[2], Owner: parts[1], Tag: tag, Digest: digest}, ""
}

func parseBinaryReference(source string) (binaryReference, string) {
	u, err := url.Parse(source)
	if err != nil || u.Scheme != "https" || u.Host != "github.com" || u.RawQuery != "" || u.Fragment != "" {
		return binaryReference{}, fmt.Sprintf("unknown fork binary reference %s", source)
	}
	parts := strings.Split(strings.TrimPrefix(u.Path, "/"), "/")
	if len(parts) != 6 || !validRepo(parts[0]+"/"+parts[1]) || parts[2] != "releases" || parts[3] != "download" || !forkTagRe.MatchString(parts[4]) || parts[5] == "" {
		return binaryReference{}, fmt.Sprintf("unknown fork binary reference %s", source)
	}
	return binaryReference{Repo: parts[0] + "/" + parts[1], Tag: parts[4], URL: source}, ""
}

func signerWorkflow(signers map[string]string, repo string) (string, string) {
	workflow := signers[repo]
	if workflow == "" {
		return "", fmt.Sprintf("%s has no -signer-workflow mapping", repo)
	}
	return repo + "/" + strings.TrimPrefix(workflow, "/"), ""
}

func validRepo(repo string) bool {
	parts := strings.Split(repo, "/")
	return len(parts) == 2 && parts[0] != "" && parts[1] != ""
}
