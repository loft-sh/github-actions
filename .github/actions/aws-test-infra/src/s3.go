package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	v4 "github.com/aws/aws-sdk-go-v2/aws/signer/v4"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	s3types "github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/smithy-go"
)

// deleteObjectsBatchSize is the S3 DeleteObjects limit (1000 keys per request).
const deleteObjectsBatchSize = 1000

// defaultPresignExpiry is used when the caller does not pass -expires-in.
const defaultPresignExpiry = 4 * time.Hour

// S3API is the subset of the S3 client we use, as an interface so tests can pass a fake.
type S3API interface {
	HeadBucket(ctx context.Context, params *s3.HeadBucketInput, optFns ...func(*s3.Options)) (*s3.HeadBucketOutput, error)
	CreateBucket(ctx context.Context, params *s3.CreateBucketInput, optFns ...func(*s3.Options)) (*s3.CreateBucketOutput, error)
	PutBucketTagging(ctx context.Context, params *s3.PutBucketTaggingInput, optFns ...func(*s3.Options)) (*s3.PutBucketTaggingOutput, error)
	PutObject(ctx context.Context, params *s3.PutObjectInput, optFns ...func(*s3.Options)) (*s3.PutObjectOutput, error)
	HeadObject(ctx context.Context, params *s3.HeadObjectInput, optFns ...func(*s3.Options)) (*s3.HeadObjectOutput, error)
	GetObject(ctx context.Context, params *s3.GetObjectInput, optFns ...func(*s3.Options)) (*s3.GetObjectOutput, error)
	ListObjectsV2(ctx context.Context, params *s3.ListObjectsV2Input, optFns ...func(*s3.Options)) (*s3.ListObjectsV2Output, error)
	DeleteObjects(ctx context.Context, params *s3.DeleteObjectsInput, optFns ...func(*s3.Options)) (*s3.DeleteObjectsOutput, error)
	DeleteBucket(ctx context.Context, params *s3.DeleteBucketInput, optFns ...func(*s3.Options)) (*s3.DeleteBucketOutput, error)
	ListBuckets(ctx context.Context, params *s3.ListBucketsInput, optFns ...func(*s3.Options)) (*s3.ListBucketsOutput, error)
	GetBucketTagging(ctx context.Context, params *s3.GetBucketTaggingInput, optFns ...func(*s3.Options)) (*s3.GetBucketTaggingOutput, error)
}

// S3Presigner is the subset of the presign client we use. The SDK signs both GET
// and PUT URLs, so no boto3 shim is needed.
type S3Presigner interface {
	PresignGetObject(ctx context.Context, params *s3.GetObjectInput, optFns ...func(*s3.PresignOptions)) (*v4.PresignedHTTPRequest, error)
	PresignPutObject(ctx context.Context, params *s3.PutObjectInput, optFns ...func(*s3.PresignOptions)) (*v4.PresignedHTTPRequest, error)
}

// bucketNameForRunID lowercases the run ID, since bucket names must be lowercase.
// It assumes the run ID is otherwise S3/DNS-safe (no underscores, <=63 chars); the
// conformance run-id shape (conformance-<mode>-<run>-<attempt>) satisfies that. A
// malformed run ID surfaces as a CreateBucket error rather than an early message.
func bucketNameForRunID(runID string) string {
	return strings.ToLower(runID)
}

// uploadSpec is a local-file → object-key pair for s3-stage.
type uploadSpec struct {
	Local string
	Key   string
}

func parseUploadSpec(s string) (uploadSpec, error) {
	local, key, ok := strings.Cut(s, "=")
	if !ok || local == "" || key == "" {
		return uploadSpec{}, fmt.Errorf("upload %q: expected local-path=object-key", s)
	}
	return uploadSpec{Local: local, Key: key}, nil
}

// presignSpec is an object-key + HTTP method (get|put) pair for s3-stage.
type presignSpec struct {
	Key    string
	Method string
}

func parsePresignSpec(s string) (presignSpec, error) {
	key, method, ok := strings.Cut(s, ":")
	if !ok || key == "" {
		return presignSpec{}, fmt.Errorf("presign %q: expected object-key:method", s)
	}
	method = strings.ToLower(method)
	if method != "get" && method != "put" {
		return presignSpec{}, fmt.Errorf("presign %q: method must be get or put, got %q", s, method)
	}
	return presignSpec{Key: key, Method: method}, nil
}

// uploadFlag / presignFlag implement flag.Value so -upload / -presign repeat.
type uploadFlag struct{ specs *[]uploadSpec }

func (f *uploadFlag) String() string { return "" }
func (f *uploadFlag) Set(value string) error {
	spec, err := parseUploadSpec(value)
	if err != nil {
		return err
	}
	*f.specs = append(*f.specs, spec)
	return nil
}

type presignFlag struct{ specs *[]presignSpec }

func (f *presignFlag) String() string { return "" }
func (f *presignFlag) Set(value string) error {
	spec, err := parsePresignSpec(value)
	if err != nil {
		return err
	}
	*f.specs = append(*f.specs, spec)
	return nil
}

// ---- s3-stage ----

// S3StageConfig is the parsed flag set for `s3-stage`.
type S3StageConfig struct {
	Region    string
	RunID     string
	Bucket    string // derived from RunID when empty
	Uploads   []uploadSpec
	Presigns  []presignSpec
	ExpiresIn time.Duration

	OutputPath   string
	OutputFormat string
}

// S3StageResult is what s3-stage emits: the bucket used and each presigned URL by key.
type S3StageResult struct {
	Bucket        string            `json:"bucket"`
	PresignedURLs map[string]string `json:"presigned_urls"`
}

func runS3Stage(ctx context.Context, logger *slog.Logger, name string, args []string) error {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	cfg := S3StageConfig{}
	fs.StringVar(&cfg.Region, "region", "", "AWS region (required)")
	fs.StringVar(&cfg.RunID, "run-id", "", "Unique run identifier; bucket name derives from it and it is tagged as RunID (required)")
	fs.StringVar(&cfg.Bucket, "bucket", "", "Bucket name; defaults to the lowercased run-id")
	fs.Var(&uploadFlag{specs: &cfg.Uploads}, "upload", "Upload in local-path=object-key form; repeatable")
	fs.Var(&presignFlag{specs: &cfg.Presigns}, "presign", "Presign in object-key:method form (method get|put); repeatable")
	fs.DurationVar(&cfg.ExpiresIn, "expires-in", defaultPresignExpiry, "Presigned URL lifetime (e.g. 4h, 14400s)")
	fs.StringVar(&cfg.OutputPath, "output", "", "Output destination; empty means stdout. Set to $GITHUB_OUTPUT to feed into Actions")
	fs.StringVar(&cfg.OutputFormat, "output-format", "auto", "auto | github-output | json")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parse s3-stage flags: %w", err)
	}
	if cfg.Region == "" || cfg.RunID == "" {
		return errors.New("s3-stage: -region and -run-id are required")
	}
	if cfg.Bucket == "" {
		cfg.Bucket = bucketNameForRunID(cfg.RunID)
	}

	awsCfg, err := loadAWSConfig(ctx, cfg.Region)
	if err != nil {
		return fmt.Errorf("load aws config: %w", err)
	}

	// A presigned URL only works while its signing credentials are still valid.
	// Warn if -expires-in outlives a short OIDC/STS session, which would 403 mid-run.
	if creds, cerr := awsCfg.Credentials.Retrieve(ctx); cerr != nil {
		logger.Warn("could not inspect credential lifetime; cannot verify presigned URLs outlive the session", "error", cerr)
	} else if msg, ok := presignLifetimeWarning(creds, cfg.ExpiresIn, time.Now()); ok {
		fmt.Printf("::warning title=Presigned URL may expire early::%s\n", msg)
		logger.Warn("presigned URL lifetime exceeds credential lifetime", "detail", msg)
	}

	client := s3.NewFromConfig(awsCfg)
	presigner := s3.NewPresignClient(client)

	res, err := s3Stage(ctx, logger, client, presigner, cfg)
	if err != nil {
		return err
	}
	return emitS3StageOutput(logger, cfg.OutputPath, cfg.OutputFormat, res)
}

// presignLifetimeWarning returns a warning (and true) when the signing credentials
// expire before the presign window closes; a URL cannot outlive the creds that
// signed it. Returns ("", false) for the safe cases (non-expiring or long-enough creds).
func presignLifetimeWarning(creds aws.Credentials, expiresIn time.Duration, now time.Time) (string, bool) {
	if !creds.CanExpire {
		return "", false
	}
	presignUntil := now.Add(expiresIn)
	if !creds.Expires.Before(presignUntil) {
		return "", false
	}
	remaining := creds.Expires.Sub(now)
	if remaining < 0 {
		remaining = 0
	}
	return fmt.Sprintf(
		"requested presign lifetime %s exceeds remaining credential lifetime ~%s; "+
			"presigned URLs will start returning 403 once the session expires. "+
			"Raise role-duration-seconds on configure-aws-credentials (and the role's max session duration) to cover the run.",
		expiresIn.Round(time.Second), remaining.Round(time.Second),
	), true
}

// s3Stage is the testable core: ensure+tag the bucket, upload files, presign keys.
func s3Stage(ctx context.Context, logger *slog.Logger, api S3API, presigner S3Presigner, cfg S3StageConfig) (S3StageResult, error) {
	if err := ensureBucket(ctx, logger, api, cfg.Bucket, cfg.Region, cfg.RunID); err != nil {
		return S3StageResult{}, err
	}

	for _, up := range cfg.Uploads {
		if err := uploadObject(ctx, logger, api, cfg.Bucket, up); err != nil {
			return S3StageResult{}, err
		}
	}

	expires := cfg.ExpiresIn
	if expires <= 0 {
		expires = defaultPresignExpiry
	}
	urls := make(map[string]string, len(cfg.Presigns))
	for _, ps := range cfg.Presigns {
		url, err := presignObject(ctx, presigner, cfg.Bucket, ps, expires)
		if err != nil {
			return S3StageResult{}, err
		}
		urls[ps.Key] = url
		logger.Info("presigned URL ready", "bucket", cfg.Bucket, "key", ps.Key, "method", ps.Method)
	}

	return S3StageResult{Bucket: cfg.Bucket, PresignedURLs: urls}, nil
}

// ensureBucket creates the bucket if it is missing, then always applies the RunID tag.
func ensureBucket(ctx context.Context, logger *slog.Logger, api S3API, bucket, region, runID string) error {
	_, err := api.HeadBucket(ctx, &s3.HeadBucketInput{Bucket: aws.String(bucket)})
	if err != nil {
		// Only a real 404 means "create it"; surface anything else (e.g. a 403)
		// instead of blindly creating and masking the real cause.
		if !isNotFound(err) {
			return fmt.Errorf("head bucket %q: %w", bucket, err)
		}
		input := &s3.CreateBucketInput{Bucket: aws.String(bucket)}
		// us-east-1 rejects a LocationConstraint; every other region requires it.
		if region != "us-east-1" {
			input.CreateBucketConfiguration = &s3types.CreateBucketConfiguration{
				LocationConstraint: s3types.BucketLocationConstraint(region),
			}
		}
		if _, cerr := api.CreateBucket(ctx, input); cerr != nil {
			// An already-owned/existing bucket is success (idempotent).
			if !bucketAlreadyOurs(cerr) {
				return fmt.Errorf("create bucket %q: %w", bucket, cerr)
			}
		} else {
			logger.Info("created bucket", "bucket", bucket, "region", region)
		}
	}

	_, err = api.PutBucketTagging(ctx, &s3.PutBucketTaggingInput{
		Bucket:  aws.String(bucket),
		Tagging: &s3types.Tagging{TagSet: []s3types.Tag{{Key: aws.String("RunID"), Value: aws.String(runID)}}},
	})
	if err != nil {
		return fmt.Errorf("tag bucket %q: %w", bucket, err)
	}
	return nil
}

func bucketAlreadyOurs(err error) bool {
	var owned *s3types.BucketAlreadyOwnedByYou
	var exists *s3types.BucketAlreadyExists
	return errors.As(err, &owned) || errors.As(err, &exists)
}

func uploadObject(ctx context.Context, logger *slog.Logger, api S3API, bucket string, up uploadSpec) error {
	f, err := os.Open(up.Local)
	if err != nil {
		return fmt.Errorf("open upload %q: %w", up.Local, err)
	}
	defer f.Close()
	if _, err := api.PutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(up.Key),
		Body:   f,
	}); err != nil {
		return fmt.Errorf("upload %q to s3://%s/%s: %w", up.Local, bucket, up.Key, err)
	}
	logger.Info("uploaded object", "bucket", bucket, "key", up.Key, "local", up.Local)
	return nil
}

func presignObject(ctx context.Context, presigner S3Presigner, bucket string, ps presignSpec, expires time.Duration) (string, error) {
	withExpiry := func(o *s3.PresignOptions) { o.Expires = expires }
	switch ps.Method {
	case "get":
		req, err := presigner.PresignGetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(bucket), Key: aws.String(ps.Key)}, withExpiry)
		if err != nil {
			return "", fmt.Errorf("presign GET %q: %w", ps.Key, err)
		}
		return req.URL, nil
	case "put":
		req, err := presigner.PresignPutObject(ctx, &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String(ps.Key)}, withExpiry)
		if err != nil {
			return "", fmt.Errorf("presign PUT %q: %w", ps.Key, err)
		}
		return req.URL, nil
	default:
		return "", fmt.Errorf("presign %q: unsupported method %q", ps.Key, ps.Method)
	}
}

// ---- s3-download ----

// S3DownloadConfig is the parsed flag set for `s3-download`.
type S3DownloadConfig struct {
	Region string
	Bucket string
	Key    string
	Dest   string
}

func runS3Download(ctx context.Context, logger *slog.Logger, name string, args []string) error {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	cfg := S3DownloadConfig{}
	fs.StringVar(&cfg.Region, "region", "", "AWS region (required)")
	fs.StringVar(&cfg.Bucket, "bucket", "", "Bucket name (required)")
	fs.StringVar(&cfg.Key, "key", "", "Object key to download (required)")
	fs.StringVar(&cfg.Dest, "dest", "", "Local destination path (required)")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parse s3-download flags: %w", err)
	}
	if cfg.Region == "" || cfg.Bucket == "" || cfg.Key == "" || cfg.Dest == "" {
		return errors.New("s3-download: -region, -bucket, -key and -dest are required")
	}

	awsCfg, err := loadAWSConfig(ctx, cfg.Region)
	if err != nil {
		return fmt.Errorf("load aws config: %w", err)
	}
	return s3Download(ctx, logger, s3.NewFromConfig(awsCfg), cfg)
}

// s3Download copies s3://bucket/key to dest. A missing object is a no-op, not an error.
func s3Download(ctx context.Context, logger *slog.Logger, api S3API, cfg S3DownloadConfig) error {
	if _, err := api.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(cfg.Bucket), Key: aws.String(cfg.Key)}); err != nil {
		if isNotFound(err) {
			logger.Info("object not present; skipping download", "bucket", cfg.Bucket, "key", cfg.Key)
			return nil
		}
		return fmt.Errorf("head s3://%s/%s: %w", cfg.Bucket, cfg.Key, err)
	}

	out, err := api.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(cfg.Bucket), Key: aws.String(cfg.Key)})
	if err != nil {
		return fmt.Errorf("get s3://%s/%s: %w", cfg.Bucket, cfg.Key, err)
	}
	defer out.Body.Close()

	if err := os.MkdirAll(filepath.Dir(cfg.Dest), 0o755); err != nil {
		return fmt.Errorf("create dest dir for %q: %w", cfg.Dest, err)
	}
	f, err := os.Create(cfg.Dest)
	if err != nil {
		return fmt.Errorf("create dest %q: %w", cfg.Dest, err)
	}
	defer f.Close()
	if _, err := io.Copy(f, out.Body); err != nil {
		// Don't leave a truncated file behind for a later reader to trip on.
		_ = os.Remove(cfg.Dest)
		return fmt.Errorf("write dest %q: %w", cfg.Dest, err)
	}
	logger.Info("downloaded object", "bucket", cfg.Bucket, "key", cfg.Key, "dest", cfg.Dest)
	return nil
}

// ---- s3-cleanup ----

// S3CleanupConfig is the parsed flag set for `s3-cleanup`.
type S3CleanupConfig struct {
	Region       string
	Bucket       string
	RunID        string
	BucketPrefix string
	SkipSweep    bool
	Strict       bool
}

func runS3Cleanup(ctx context.Context, logger *slog.Logger, name string, args []string) error {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	cfg := S3CleanupConfig{}
	fs.StringVar(&cfg.Region, "region", "", "AWS region (required)")
	fs.StringVar(&cfg.Bucket, "bucket", "", "Bucket to delete directly (empty skips direct delete)")
	fs.StringVar(&cfg.RunID, "run-id", "", "Run ID matched against the RunID tag during the sweep")
	fs.StringVar(&cfg.BucketPrefix, "bucket-prefix", "", "Name prefix for the tag-based sweep fallback")
	fs.BoolVar(&cfg.SkipSweep, "skip-sweep", false, "Skip the tag-based sweep; only delete the supplied bucket")
	fs.BoolVar(&cfg.Strict, "strict", false, "Fail on delete/sweep errors. Default false matches the Bash teardown (best-effort).")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parse s3-cleanup flags: %w", err)
	}
	if cfg.Region == "" {
		return errors.New("s3-cleanup: -region is required")
	}

	awsCfg, err := loadAWSConfig(ctx, cfg.Region)
	if err != nil {
		return fmt.Errorf("load aws config: %w", err)
	}
	return s3Cleanup(ctx, logger, s3.NewFromConfig(awsCfg), cfg)
}

// s3Cleanup deletes the given bucket (if any) then sweeps orphans by tag.
// Best-effort by default: errors are logged; with -strict the first one is returned.
func s3Cleanup(ctx context.Context, logger *slog.Logger, api S3API, cfg S3CleanupConfig) error {
	var firstErr error
	note := func(err error) {
		if err == nil {
			return
		}
		if cfg.Strict && firstErr == nil {
			firstErr = err
		}
		logger.Warn("s3-cleanup error (best-effort)", "error", err)
	}

	if cfg.Bucket != "" {
		note(emptyAndDeleteBucket(ctx, logger, api, cfg.Bucket))
	}

	if !cfg.SkipSweep && cfg.BucketPrefix != "" {
		if cfg.RunID == "" {
			// Without a RunID we cannot tell our orphans apart from anyone
			// else's, so we skip rather than delete blindly. Mirror the EC2
			// cleanup guard: surface it (fatal under -strict, warning otherwise).
			note(errors.New("s3-cleanup: sweep requested (bucket-prefix set) but run-id is empty; skipping sweep"))
		} else {
			note(sweepBuckets(ctx, logger, api, cfg.Region, cfg.BucketPrefix, cfg.RunID))
		}
	}

	return firstErr
}

func sweepBuckets(ctx context.Context, logger *slog.Logger, api S3API, region, prefix, runID string) error {
	var sweepErr error
	var token *string
	for {
		// Filter to this region: ListBuckets is global, but the client (and the
		// delete calls) are region-bound, so a same-tag bucket elsewhere would
		// just fail the follow-up calls. Paginate so buckets past the first page
		// are not silently skipped.
		out, err := api.ListBuckets(ctx, &s3.ListBucketsInput{
			BucketRegion:      aws.String(region),
			Prefix:            aws.String(prefix), // server-side filter; the HasPrefix below stays as a safety net
			ContinuationToken: token,
		})
		if err != nil {
			return fmt.Errorf("list buckets: %w", err)
		}
		for _, b := range out.Buckets {
			name := aws.ToString(b.Name)
			if !strings.HasPrefix(name, prefix) {
				continue
			}
			tags, terr := api.GetBucketTagging(ctx, &s3.GetBucketTaggingInput{Bucket: aws.String(name)})
			if terr != nil {
				// NoSuchTagSet just means no RunID tag: skip quietly. Any other error
				// might hide a bucket that is ours, so warn rather than skip silently.
				if !isNoSuchTagSet(terr) {
					logger.Warn("could not read tags during sweep; skipping bucket (may leak if it is ours)",
						"bucket", name, "error", terr)
				}
				continue
			}
			if !hasRunIDTag(tags.TagSet, runID) {
				continue
			}
			logger.Info("sweeping orphaned bucket", "bucket", name, "run_id", runID)
			if derr := emptyAndDeleteBucket(ctx, logger, api, name); derr != nil {
				// Log every failure so no leaked bucket is invisible; keep the
				// first as the returned error (mirrors the EC2 cleanup sweep).
				logger.Warn("failed to sweep orphaned bucket", "bucket", name, "error", derr)
				if sweepErr == nil {
					sweepErr = derr
				}
			}
		}
		if aws.ToString(out.ContinuationToken) == "" {
			break
		}
		token = out.ContinuationToken
	}
	return sweepErr
}

func hasRunIDTag(tags []s3types.Tag, runID string) bool {
	for _, t := range tags {
		if aws.ToString(t.Key) == "RunID" && aws.ToString(t.Value) == runID {
			return true
		}
	}
	return false
}

// emptyAndDeleteBucket removes every object then deletes the bucket (S3 requires
// the bucket be empty first).
func emptyAndDeleteBucket(ctx context.Context, logger *slog.Logger, api S3API, bucket string) error {
	var token *string
	for {
		list, err := api.ListObjectsV2(ctx, &s3.ListObjectsV2Input{
			Bucket:            aws.String(bucket),
			ContinuationToken: token,
		})
		if err != nil {
			if isNoSuchBucket(err) {
				return nil // already gone
			}
			return fmt.Errorf("list objects in %q: %w", bucket, err)
		}
		if err := deleteObjectPage(ctx, api, bucket, list.Contents); err != nil {
			return err
		}
		if aws.ToBool(list.IsTruncated) && list.NextContinuationToken != nil {
			token = list.NextContinuationToken
			continue
		}
		break
	}

	if _, err := api.DeleteBucket(ctx, &s3.DeleteBucketInput{Bucket: aws.String(bucket)}); err != nil {
		if isNoSuchBucket(err) {
			return nil
		}
		return fmt.Errorf("delete bucket %q: %w", bucket, err)
	}
	logger.Info("deleted bucket", "bucket", bucket)
	return nil
}

func deleteObjectPage(ctx context.Context, api S3API, bucket string, contents []s3types.Object) error {
	ids := make([]s3types.ObjectIdentifier, 0, len(contents))
	for _, obj := range contents {
		ids = append(ids, s3types.ObjectIdentifier{Key: obj.Key})
	}
	for start := 0; start < len(ids); start += deleteObjectsBatchSize {
		end := min(start+deleteObjectsBatchSize, len(ids))
		out, err := api.DeleteObjects(ctx, &s3.DeleteObjectsInput{
			Bucket: aws.String(bucket),
			Delete: &s3types.Delete{Objects: ids[start:end], Quiet: aws.Bool(true)},
		})
		if err != nil {
			return fmt.Errorf("delete objects in %q: %w", bucket, err)
		}
		// DeleteObjects returns 200 even when some keys fail; those are in out.Errors.
		// Surface them, else the later DeleteBucket fails with BucketNotEmpty.
		if out != nil && len(out.Errors) > 0 {
			return fmt.Errorf("delete objects in %q: %s", bucket, summarizeDeleteErrors(out.Errors))
		}
	}
	return nil
}

// summarizeDeleteErrors renders per-object DeleteObjects failures compactly:
// the total count plus up to the first few "key (code)" pairs.
func summarizeDeleteErrors(errs []s3types.Error) string {
	const maxShown = 3
	var b strings.Builder
	fmt.Fprintf(&b, "%d object(s) failed to delete", len(errs))
	shown := min(len(errs), maxShown)
	for i := 0; i < shown; i++ {
		if i == 0 {
			b.WriteString(": ")
		} else {
			b.WriteString(", ")
		}
		fmt.Fprintf(&b, "%s (%s)", aws.ToString(errs[i].Key), aws.ToString(errs[i].Code))
	}
	if len(errs) > shown {
		fmt.Fprintf(&b, ", … (%d more)", len(errs)-shown)
	}
	return b.String()
}

// apiErrorCodeIs reports whether err is an AWS API error with one of the given codes.
func apiErrorCodeIs(err error, codes ...string) bool {
	var apiErr smithy.APIError
	if !errors.As(err, &apiErr) {
		return false
	}
	return slices.Contains(codes, apiErr.ErrorCode())
}

// isNotFound reports whether err is an S3 404 (missing object/bucket for Head*).
func isNotFound(err error) bool {
	return apiErrorCodeIs(err, "NotFound", "NoSuchKey", "NoSuchBucket", "404")
}

func isNoSuchBucket(err error) bool { return apiErrorCodeIs(err, "NoSuchBucket") }

func isNoSuchTagSet(err error) bool { return apiErrorCodeIs(err, "NoSuchTagSet") }

// emitS3StageOutput writes the stage result to GITHUB_OUTPUT (key=value) or stdout (JSON),
// following the same destination semantics as emitOutput.
func emitS3StageOutput(logger *slog.Logger, destination, format string, res S3StageResult) error {
	if format == "" || format == "auto" {
		if destination == "" {
			format = "json"
		} else {
			format = "github-output"
		}
	}

	w, err := openDestWriter(destination)
	if err != nil {
		return err
	}
	defer w.Close()

	switch format {
	case "json":
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		if err := enc.Encode(res); err != nil {
			return fmt.Errorf("encode json output: %w", err)
		}
	case "github-output":
		// GITHUB_OUTPUT is not masked, so register each URL with ::add-mask:: first
		// (a write-capable PUT URL is a secret). Mask commands go to stdout, not the file.
		maskPresignedURLs(os.Stdout, res.PresignedURLs)

		urlsJSON, err := json.Marshal(res.PresignedURLs)
		if err != nil {
			return fmt.Errorf("encode presigned_urls: %w", err)
		}
		if _, err := fmt.Fprintf(w, "bucket=%s\npresigned_urls=%s\n", res.Bucket, urlsJSON); err != nil {
			return fmt.Errorf("write github output: %w", err)
		}
	default:
		return fmt.Errorf("unknown output format: %s", format)
	}
	logger.Info("emitted s3-stage output", "destination", destinationLabel(destination), "format", format)
	return nil
}

// maskPresignedURLs writes an Actions ::add-mask:: command for each URL so the
// runner scrubs it from later logs.
func maskPresignedURLs(w io.Writer, urls map[string]string) {
	for _, u := range urls {
		if u == "" {
			continue
		}
		fmt.Fprintf(w, "::add-mask::%s\n", u)
	}
}
