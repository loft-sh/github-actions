package main

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
)

// attestTool verifies the provenance of a build input; tests replace it.
type attestTool interface {
	Verify(ctx context.Context, subject string, args attestArgs) error
}

type attestArgs struct {
	Owner          string
	Repo           string
	SignerWorkflow string
	SignerDigest   string
	SourceDigest   string
	SourceRef      string
}

type execAttest struct{}

func (execAttest) Verify(ctx context.Context, subject string, a attestArgs) error {
	args := []string{"attestation", "verify", subject}
	switch {
	case a.Owner != "":
		args = append(args, "--owner", a.Owner)
	case a.Repo != "":
		args = append(args, "--repo", a.Repo)
	default:
		return fmt.Errorf("attestation verifier needs an owner or repository")
	}
	args = append(args,
		"--signer-workflow", a.SignerWorkflow,
		"--signer-digest", a.SignerDigest,
		"--source-digest", a.SourceDigest,
		"--source-ref", a.SourceRef,
		"--deny-self-hosted-runners",
		"--format", "json",
	)

	cmd := exec.CommandContext(ctx, "gh", args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if _, err := cmd.Output(); err != nil {
		return fmt.Errorf("gh %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return nil
}
