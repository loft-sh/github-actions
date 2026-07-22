// Command aws-test-infra provisions and tears down AWS test infrastructure
// (VPC + subnet + IGW + route table + security group + EC2 instances) for
// use by GitHub Actions e2e workflows. It replaces hundreds of lines of
// duplicated Bash + aws-cli that previously lived inline in two
// vcluster-pro workflows.
//
// Two subcommands:
//
//	aws-test-infra provision [flags]
//	aws-test-infra cleanup   [flags]
//
// Both rely on the default aws-sdk-go-v2 credential chain. Workflows that
// already use aws-actions/configure-aws-credentials (OIDC + assume-role)
// pass credentials in via env vars with no extra wiring.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	if err := run(context.Background(), os.Stderr, os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "%s\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, stderr io.Writer, args []string) error {
	if len(args) < 2 {
		printUsage(stderr)
		return errors.New("subcommand required")
	}

	logger := slog.New(slog.NewTextHandler(stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()

	switch args[1] {
	case "provision":
		return runProvision(ctx, logger, args[0]+" provision", args[2:])
	case "cleanup":
		return runCleanup(ctx, logger, args[0]+" cleanup", args[2:])
	case "s3-stage":
		return runS3Stage(ctx, logger, args[0]+" s3-stage", args[2:])
	case "s3-download":
		return runS3Download(ctx, logger, args[0]+" s3-download", args[2:])
	case "s3-cleanup":
		return runS3Cleanup(ctx, logger, args[0]+" s3-cleanup", args[2:])
	case "-h", "--help", "help":
		printUsage(stderr)
		return nil
	default:
		printUsage(stderr)
		return fmt.Errorf("unknown subcommand: %s", args[1])
	}
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, `Usage: aws-test-infra <subcommand> [flags]

Subcommands:
  provision     Create VPC, subnet, IGW, route table, security group, and EC2 instances
  cleanup       Tear down resources by ID and run a tag-based fallback sweep
  s3-stage      Ensure+tag an S3 bucket, upload artifacts, and emit presigned URLs
  s3-download   Download an object to a local path (no-op if the object is absent)
  s3-cleanup    Empty and delete an S3 bucket, with a tag-based fallback sweep

Run "aws-test-infra <subcommand> -h" for subcommand flags.`)
}
