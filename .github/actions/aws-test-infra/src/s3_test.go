package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	s3types "github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/smithy-go"
)

// captureStdout runs fn with os.Stdout redirected to a pipe and returns what
// was written, so tests can assert on stdout-bound output (json / ::add-mask::).
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	fn()
	_ = w.Close()
	os.Stdout = old
	out, _ := io.ReadAll(r)
	return string(out)
}

func TestBucketNameForRunID(t *testing.T) {
	if got := bucketNameForRunID("Conformance-Standalone-123"); got != "conformance-standalone-123" {
		t.Errorf("bucketNameForRunID = %q, want lowercased", got)
	}
}

func TestParseUploadSpec(t *testing.T) {
	tests := []struct {
		in      string
		want    uploadSpec
		wantErr bool
	}{
		{"vcluster_image=vcluster.tar", uploadSpec{Local: "vcluster_image", Key: "vcluster.tar"}, false},
		{"/tmp/a.tar.gz=kind-node.tar.gz", uploadSpec{Local: "/tmp/a.tar.gz", Key: "kind-node.tar.gz"}, false},
		{"missing-equals", uploadSpec{}, true},
		{"=key-only", uploadSpec{}, true},
		{"local-only=", uploadSpec{}, true},
	}
	for _, tt := range tests {
		got, err := parseUploadSpec(tt.in)
		if tt.wantErr {
			if err == nil {
				t.Errorf("parseUploadSpec(%q) expected error", tt.in)
			}
			continue
		}
		if err != nil || got != tt.want {
			t.Errorf("parseUploadSpec(%q) = %+v, %v; want %+v", tt.in, got, err, tt.want)
		}
	}
}

func TestParsePresignSpec(t *testing.T) {
	tests := []struct {
		in      string
		want    presignSpec
		wantErr bool
	}{
		{"vcluster.tar:get", presignSpec{Key: "vcluster.tar", Method: "get"}, false},
		{"results.tar.gz:put", presignSpec{Key: "results.tar.gz", Method: "put"}, false},
		{"results.tar.gz:PUT", presignSpec{Key: "results.tar.gz", Method: "put"}, false},
		{"no-method", presignSpec{}, true},
		{":get", presignSpec{}, true},
		{"key:delete", presignSpec{}, true},
	}
	for _, tt := range tests {
		got, err := parsePresignSpec(tt.in)
		if tt.wantErr {
			if err == nil {
				t.Errorf("parsePresignSpec(%q) expected error", tt.in)
			}
			continue
		}
		if err != nil || got != tt.want {
			t.Errorf("parsePresignSpec(%q) = %+v, %v; want %+v", tt.in, got, err, tt.want)
		}
	}
}

func TestEnsureBucket_CreatesWhenMissing(t *testing.T) {
	f := &fakeS3{headBucketErr: &s3types.NotFound{}}
	if err := ensureBucket(context.Background(), newTestLogger(), f, "my-bucket", "us-west-2", "RunTag-1"); err != nil {
		t.Fatalf("ensureBucket: %v", err)
	}
	if f.called("CreateBucket") != 1 {
		t.Errorf("expected CreateBucket to be called once, calls=%v", f.calls)
	}
	if f.called("PutBucketTagging") != 1 {
		t.Errorf("expected PutBucketTagging once, calls=%v", f.calls)
	}
	// Non-us-east-1 must carry a LocationConstraint.
	if f.createBucketInput == nil || f.createBucketInput.CreateBucketConfiguration == nil ||
		string(f.createBucketInput.CreateBucketConfiguration.LocationConstraint) != "us-west-2" {
		t.Errorf("expected LocationConstraint=us-west-2, got %+v", f.createBucketInput)
	}
	// RunID tag preserves original (un-lowercased) run id.
	if f.putTaggingInput == nil || len(f.putTaggingInput.Tagging.TagSet) != 1 ||
		aws.ToString(f.putTaggingInput.Tagging.TagSet[0].Value) != "RunTag-1" {
		t.Errorf("expected RunID tag value RunTag-1, got %+v", f.putTaggingInput)
	}
}

func TestEnsureBucket_SkipsCreateWhenPresent(t *testing.T) {
	f := &fakeS3{} // HeadBucket succeeds
	if err := ensureBucket(context.Background(), newTestLogger(), f, "b", "us-west-2", "r"); err != nil {
		t.Fatalf("ensureBucket: %v", err)
	}
	if f.called("CreateBucket") != 0 {
		t.Errorf("did not expect CreateBucket when bucket present, calls=%v", f.calls)
	}
	if f.called("PutBucketTagging") != 1 {
		t.Errorf("expected PutBucketTagging even when bucket present, calls=%v", f.calls)
	}
}

func TestEnsureBucket_USEast1NoLocationConstraint(t *testing.T) {
	f := &fakeS3{headBucketErr: &s3types.NotFound{}}
	if err := ensureBucket(context.Background(), newTestLogger(), f, "b", "us-east-1", "r"); err != nil {
		t.Fatalf("ensureBucket: %v", err)
	}
	if f.createBucketInput == nil || f.createBucketInput.CreateBucketConfiguration != nil {
		t.Errorf("us-east-1 must omit CreateBucketConfiguration, got %+v", f.createBucketInput)
	}
}

func TestS3Stage_EndToEnd(t *testing.T) {
	dir := t.TempDir()
	local := filepath.Join(dir, "vcluster_image")
	if err := os.WriteFile(local, []byte("image-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}

	f := &fakeS3{headBucketErr: &s3types.NotFound{}}
	p := &fakePresigner{}
	cfg := S3StageConfig{
		Region:    "us-west-2",
		RunID:     "conformance-standalone-9",
		Bucket:    "conformance-standalone-9",
		Uploads:   []uploadSpec{{Local: local, Key: "vcluster.tar"}},
		Presigns:  []presignSpec{{Key: "vcluster.tar", Method: "get"}, {Key: "results.tar.gz", Method: "put"}},
		ExpiresIn: 2 * time.Hour,
	}
	res, err := s3Stage(context.Background(), newTestLogger(), f, p, cfg)
	if err != nil {
		t.Fatalf("s3Stage: %v", err)
	}
	if res.Bucket != "conformance-standalone-9" {
		t.Errorf("bucket = %q", res.Bucket)
	}
	if p.lastExpiry != 2*time.Hour {
		t.Errorf("presign expiry not applied: got %v, want 2h", p.lastExpiry)
	}
	if len(f.uploadedKeys) != 1 || f.uploadedKeys[0] != "vcluster.tar" {
		t.Errorf("uploadedKeys = %v", f.uploadedKeys)
	}
	if got := res.PresignedURLs["vcluster.tar"]; got != "https://presigned.example/GET/vcluster.tar" {
		t.Errorf("GET url = %q", got)
	}
	if got := res.PresignedURLs["results.tar.gz"]; got != "https://presigned.example/PUT/results.tar.gz" {
		t.Errorf("PUT url = %q", got)
	}
}

func TestS3Stage_MissingUploadFileErrors(t *testing.T) {
	f := &fakeS3{headBucketErr: &s3types.NotFound{}}
	cfg := S3StageConfig{
		Region:  "us-west-2",
		RunID:   "r",
		Bucket:  "b",
		Uploads: []uploadSpec{{Local: "/does/not/exist", Key: "k"}},
	}
	if _, err := s3Stage(context.Background(), newTestLogger(), f, &fakePresigner{}, cfg); err == nil {
		t.Fatal("expected error for missing upload file")
	}
}

func TestS3Download_NoOpWhenMissing(t *testing.T) {
	f := &fakeS3{headObjectErr: &s3types.NotFound{}}
	dest := filepath.Join(t.TempDir(), "results.tar.gz")
	cfg := S3DownloadConfig{Region: "us-west-2", Bucket: "b", Key: "results.tar.gz", Dest: dest}
	if err := s3Download(context.Background(), newTestLogger(), f, cfg); err != nil {
		t.Fatalf("expected no-op nil, got %v", err)
	}
	if f.called("GetObject") != 0 {
		t.Errorf("did not expect GetObject when object missing")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Errorf("dest should not exist when object missing")
	}
}

func TestS3Download_WritesFile(t *testing.T) {
	f := &fakeS3{getObjectBody: "result-archive"}
	dest := filepath.Join(t.TempDir(), "results.tar.gz")
	cfg := S3DownloadConfig{Region: "us-west-2", Bucket: "b", Key: "results.tar.gz", Dest: dest}
	if err := s3Download(context.Background(), newTestLogger(), f, cfg); err != nil {
		t.Fatalf("s3Download: %v", err)
	}
	got, err := os.ReadFile(dest)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "result-archive" {
		t.Errorf("dest content = %q", string(got))
	}
}

func TestS3Cleanup_DirectDelete(t *testing.T) {
	f := &fakeS3{listPages: [][]s3types.Object{{{Key: aws.String("vcluster.tar")}, {Key: aws.String("results.tar.gz")}}}}
	cfg := S3CleanupConfig{Region: "us-west-2", Bucket: "my-bucket", SkipSweep: true}
	if err := s3Cleanup(context.Background(), newTestLogger(), f, cfg); err != nil {
		t.Fatalf("s3Cleanup: %v", err)
	}
	if len(f.deletedKeys) != 2 {
		t.Errorf("expected 2 objects deleted, got %v", f.deletedKeys)
	}
	if len(f.deletedBuckets) != 1 || f.deletedBuckets[0] != "my-bucket" {
		t.Errorf("expected my-bucket deleted, got %v", f.deletedBuckets)
	}
	if f.called("ListBuckets") != 0 {
		t.Errorf("SkipSweep should prevent ListBuckets")
	}
}

func TestS3Cleanup_SweepMatchesTagOnly(t *testing.T) {
	f := &fakeS3{
		buckets: []s3types.Bucket{
			{Name: aws.String("conformance-standalone-match")},
			{Name: aws.String("conformance-standalone-other")},
			{Name: aws.String("unrelated-bucket")},
		},
		bucketTags: map[string][]s3types.Tag{
			"conformance-standalone-match": {{Key: aws.String("RunID"), Value: aws.String("run-42")}},
			"conformance-standalone-other": {{Key: aws.String("RunID"), Value: aws.String("run-99")}},
		},
	}
	cfg := S3CleanupConfig{Region: "us-west-2", RunID: "run-42", BucketPrefix: "conformance-standalone-"}
	if err := s3Cleanup(context.Background(), newTestLogger(), f, cfg); err != nil {
		t.Fatalf("s3Cleanup: %v", err)
	}
	if len(f.deletedBuckets) != 1 || f.deletedBuckets[0] != "conformance-standalone-match" {
		t.Errorf("expected only the tag-matching bucket deleted, got %v", f.deletedBuckets)
	}
}

func TestS3Cleanup_BestEffortByDefault(t *testing.T) {
	// A cleanup with neither bucket nor sweep inputs is a no-op and must not error.
	f := &fakeS3{}
	if err := s3Cleanup(context.Background(), newTestLogger(), f, S3CleanupConfig{Region: "us-west-2"}); err != nil {
		t.Fatalf("empty cleanup should be a no-op, got %v", err)
	}
}

func TestEmitS3StageOutput_GitHubOutput(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "GITHUB_OUTPUT")
	res := S3StageResult{
		Bucket:        "my-bucket",
		PresignedURLs: map[string]string{"vcluster.tar": "https://x/GET", "results.tar.gz": "https://x/PUT"},
	}
	var emitErr error
	stdout := captureStdout(t, func() {
		emitErr = emitS3StageOutput(newTestLogger(), path, "github-output", res)
	})
	if emitErr != nil {
		t.Fatalf("emit: %v", emitErr)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	out := string(data)
	if !strings.Contains(out, "bucket=my-bucket\n") {
		t.Errorf("missing bucket line: %q", out)
	}
	if !strings.Contains(out, `"vcluster.tar":"https://x/GET"`) || !strings.Contains(out, `"results.tar.gz":"https://x/PUT"`) {
		t.Errorf("presigned_urls JSON malformed: %q", out)
	}
	// The github-output branch must mask every presigned URL (they are write-capable secrets).
	if !strings.Contains(stdout, "::add-mask::https://x/GET") || !strings.Contains(stdout, "::add-mask::https://x/PUT") {
		t.Errorf("expected an ::add-mask:: line per presigned URL on stdout, got %q", stdout)
	}
}

func TestIsNotFound(t *testing.T) {
	if !isNotFound(&s3types.NotFound{}) {
		t.Error("NotFound type should be recognized")
	}
	if isNotFound(errors.New("some other error")) {
		t.Error("generic error must not be treated as NotFound")
	}
}

// A non-404 HeadBucket error (e.g. 403) must surface, not be treated as "missing".
func TestEnsureBucket_Head403DoesNotCreate(t *testing.T) {
	f := &fakeS3{headBucketErr: &smithy.GenericAPIError{Code: "Forbidden", Message: "403"}}
	err := ensureBucket(context.Background(), newTestLogger(), f, "b", "us-west-2", "r")
	if err == nil {
		t.Fatal("expected error on 403 HeadBucket, got nil")
	}
	if f.called("CreateBucket") != 0 {
		t.Errorf("must not CreateBucket on a non-404 HeadBucket error, calls=%v", f.calls)
	}
}

// Per-object DeleteObjects failures (returned in a 200 response) must fail the delete.
func TestDeleteObjectPage_PerObjectErrorsSurfaced(t *testing.T) {
	f := &fakeS3{deleteObjectErrs: []s3types.Error{
		{Key: aws.String("locked.tar"), Code: aws.String("AccessDenied")},
	}}
	err := deleteObjectPage(context.Background(), f, "b", []s3types.Object{{Key: aws.String("locked.tar")}})
	if err == nil {
		t.Fatal("expected error when DeleteObjects reports per-object failures")
	}
	if !strings.Contains(err.Error(), "locked.tar") || !strings.Contains(err.Error(), "AccessDenied") {
		t.Errorf("error should name the failed key and code, got %v", err)
	}
}

// A multi-page object listing must be fully paginated before the bucket is deleted.
func TestEmptyAndDeleteBucket_Paginates(t *testing.T) {
	f := &fakeS3{listPages: [][]s3types.Object{
		{{Key: aws.String("a")}, {Key: aws.String("b")}},
		{{Key: aws.String("c")}},
	}}
	if err := emptyAndDeleteBucket(context.Background(), newTestLogger(), f, "b"); err != nil {
		t.Fatalf("emptyAndDeleteBucket: %v", err)
	}
	if f.called("ListObjectsV2") != 2 {
		t.Errorf("expected 2 list pages walked, calls=%v", f.calls)
	}
	if len(f.deletedKeys) != 3 {
		t.Errorf("expected all 3 objects across pages deleted, got %v", f.deletedKeys)
	}
	if len(f.deletedBuckets) != 1 {
		t.Errorf("expected bucket deleted after emptying, got %v", f.deletedBuckets)
	}
}

// With -strict, a delete error must propagate out of s3Cleanup.
func TestS3Cleanup_StrictPropagatesError(t *testing.T) {
	f := &fakeS3{deleteBucketErr: errors.New("boom")}
	cfg := S3CleanupConfig{Region: "us-west-2", Bucket: "b", SkipSweep: true, Strict: true}
	if err := s3Cleanup(context.Background(), newTestLogger(), f, cfg); err == nil {
		t.Fatal("expected strict cleanup to propagate the delete error")
	}
}

// Without -strict, the same delete error is swallowed (best-effort).
func TestS3Cleanup_BestEffortSwallowsError(t *testing.T) {
	f := &fakeS3{deleteBucketErr: errors.New("boom")}
	cfg := S3CleanupConfig{Region: "us-west-2", Bucket: "b", SkipSweep: true} // Strict=false
	if err := s3Cleanup(context.Background(), newTestLogger(), f, cfg); err != nil {
		t.Fatalf("best-effort cleanup must not fail the step, got %v", err)
	}
}

// A sweep-path delete error must also propagate under -strict.
func TestS3Cleanup_StrictPropagatesSweepError(t *testing.T) {
	f := &fakeS3{
		buckets:         []s3types.Bucket{{Name: aws.String("conformance-standalone-match")}},
		bucketTags:      map[string][]s3types.Tag{"conformance-standalone-match": {{Key: aws.String("RunID"), Value: aws.String("run-42")}}},
		deleteBucketErr: errors.New("sweep boom"),
	}
	cfg := S3CleanupConfig{Region: "us-west-2", RunID: "run-42", BucketPrefix: "conformance-standalone-", Strict: true}
	if err := s3Cleanup(context.Background(), newTestLogger(), f, cfg); err == nil {
		t.Fatal("expected strict sweep error to propagate")
	}
}

// A presign error must abort s3Stage.
func TestS3Stage_PresignErrorPropagates(t *testing.T) {
	f := &fakeS3{headBucketErr: &s3types.NotFound{}}
	p := &fakePresigner{putErr: errors.New("presign failed")}
	cfg := S3StageConfig{
		Region:   "us-west-2",
		RunID:    "r",
		Bucket:   "b",
		Presigns: []presignSpec{{Key: "results.tar.gz", Method: "put"}},
	}
	if _, err := s3Stage(context.Background(), newTestLogger(), f, p, cfg); err == nil {
		t.Fatal("expected presign error to propagate")
	}
}

// presignLifetimeWarning fires only when the session expires before the presign window closes.
func TestPresignLifetimeWarning(t *testing.T) {
	now := time.Unix(1_000_000, 0)

	// Non-expiring (static) creds: never warn.
	if _, ok := presignLifetimeWarning(aws.Credentials{CanExpire: false}, 4*time.Hour, now); ok {
		t.Error("static credentials should not produce a warning")
	}
	// Session outlives the window: no warning.
	longCreds := aws.Credentials{CanExpire: true, Expires: now.Add(5 * time.Hour)}
	if _, ok := presignLifetimeWarning(longCreds, 4*time.Hour, now); ok {
		t.Error("session longer than presign window should not warn")
	}
	// Session shorter than the window (the OIDC 1h vs 4h case): must warn.
	shortCreds := aws.Credentials{CanExpire: true, Expires: now.Add(1 * time.Hour)}
	msg, ok := presignLifetimeWarning(shortCreds, 4*time.Hour, now)
	if !ok {
		t.Fatal("expected a warning when session is shorter than the presign window")
	}
	if !strings.Contains(msg, "role-duration-seconds") {
		t.Errorf("warning should point at the fix, got %q", msg)
	}
}

// Presigned URLs must be registered with ::add-mask:: so the runner scrubs them from logs.
func TestMaskPresignedURLs(t *testing.T) {
	var b strings.Builder
	maskPresignedURLs(&b, map[string]string{
		"results.tar.gz": "https://presigned.example/PUT/results.tar.gz?sig=secret",
		"empty":          "",
	})
	out := b.String()
	if !strings.Contains(out, "::add-mask::https://presigned.example/PUT/results.tar.gz?sig=secret") {
		t.Errorf("expected add-mask command for the PUT URL, got %q", out)
	}
	if strings.Contains(out, "::add-mask::\n") {
		t.Errorf("empty URL should not be masked, got %q", out)
	}
}

// A create that reports the bucket is already ours is idempotent (no error, still tagged);
// any other create error surfaces.
func TestEnsureBucket_AlreadyOwnedIsIdempotent(t *testing.T) {
	f := &fakeS3{headBucketErr: &s3types.NotFound{}, createBucketErr: &s3types.BucketAlreadyOwnedByYou{}}
	if err := ensureBucket(context.Background(), newTestLogger(), f, "b", "us-west-2", "r"); err != nil {
		t.Fatalf("already-owned bucket must be treated as success: %v", err)
	}
	if f.called("PutBucketTagging") != 1 {
		t.Errorf("expected the bucket to still be tagged, calls=%v", f.calls)
	}
}

func TestEnsureBucket_CreateErrorSurfaces(t *testing.T) {
	f := &fakeS3{headBucketErr: &s3types.NotFound{}, createBucketErr: errors.New("quota exceeded")}
	err := ensureBucket(context.Background(), newTestLogger(), f, "b", "us-west-2", "r")
	if err == nil {
		t.Fatal("expected a generic CreateBucket error to surface")
	}
	if f.called("PutBucketTagging") != 0 {
		t.Errorf("must not tag a bucket that failed to create, calls=%v", f.calls)
	}
}

// The delete-objects loop must batch in chunks of 1000 (the S3 API limit).
func TestDeleteObjectPage_BatchesOver1000(t *testing.T) {
	objs := make([]s3types.Object, 1001)
	for i := range objs {
		objs[i] = s3types.Object{Key: aws.String(fmt.Sprintf("k%d", i))}
	}
	f := &fakeS3{}
	if err := deleteObjectPage(context.Background(), f, "b", objs); err != nil {
		t.Fatalf("deleteObjectPage: %v", err)
	}
	if f.called("DeleteObjects") != 2 {
		t.Errorf("expected 2 batches (1000 + 1), got %d calls", f.called("DeleteObjects"))
	}
	if len(f.deletedKeys) != 1001 {
		t.Errorf("expected all 1001 keys deleted, got %d", len(f.deletedKeys))
	}
}

// The json format writes a valid, round-trippable document.
func TestEmitS3StageOutput_JSONFormat(t *testing.T) {
	path := filepath.Join(t.TempDir(), "out.json")
	res := S3StageResult{Bucket: "b", PresignedURLs: map[string]string{"k": "https://u"}}
	if err := emitS3StageOutput(newTestLogger(), path, "json", res); err != nil {
		t.Fatalf("emit: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var got S3StageResult
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("not valid json: %v (%s)", err, data)
	}
	if got.Bucket != "b" || got.PresignedURLs["k"] != "https://u" {
		t.Errorf("json round-trip mismatch: %+v", got)
	}
}

// auto resolves to github-output for a file destination and to json for stdout.
func TestEmitS3StageOutput_AutoResolves(t *testing.T) {
	path := filepath.Join(t.TempDir(), "GITHUB_OUTPUT")
	if err := emitS3StageOutput(newTestLogger(), path, "auto", S3StageResult{Bucket: "b", PresignedURLs: map[string]string{}}); err != nil {
		t.Fatalf("emit: %v", err)
	}
	data, _ := os.ReadFile(path)
	if !strings.Contains(string(data), "bucket=b\n") {
		t.Errorf("auto + file destination should emit github-output, got %q", data)
	}

	out := captureStdout(t, func() {
		_ = emitS3StageOutput(newTestLogger(), "", "auto", S3StageResult{Bucket: "b2", PresignedURLs: map[string]string{}})
	})
	if !strings.Contains(out, `"bucket": "b2"`) {
		t.Errorf("auto + empty destination should emit json to stdout, got %q", out)
	}
}

func TestEmitS3StageOutput_UnknownFormat(t *testing.T) {
	if err := emitS3StageOutput(newTestLogger(), "", "xml", S3StageResult{}); err == nil {
		t.Fatal("expected an error for an unknown output format")
	}
}

// The always() teardown shape: a direct bucket delete AND a tag-based sweep in one call.
func TestS3Cleanup_DirectDeleteAndSweep(t *testing.T) {
	f := &fakeS3{
		listPages:  [][]s3types.Object{{{Key: aws.String("x")}}},
		buckets:    []s3types.Bucket{{Name: aws.String("conformance-standalone-orphan")}},
		bucketTags: map[string][]s3types.Tag{"conformance-standalone-orphan": {{Key: aws.String("RunID"), Value: aws.String("run-7")}}},
	}
	cfg := S3CleanupConfig{Region: "us-west-2", Bucket: "my-bucket", RunID: "run-7", BucketPrefix: "conformance-standalone-"}
	if err := s3Cleanup(context.Background(), newTestLogger(), f, cfg); err != nil {
		t.Fatalf("s3Cleanup: %v", err)
	}
	if !slices.Contains(f.deletedBuckets, "my-bucket") || !slices.Contains(f.deletedBuckets, "conformance-standalone-orphan") {
		t.Errorf("expected both the direct bucket and the tagged orphan deleted, got %v", f.deletedBuckets)
	}
}

// A -strict direct-delete error must propagate, and the sweep must still run (no early return).
func TestS3Cleanup_StrictDirectErrorStillRunsSweep(t *testing.T) {
	f := &fakeS3{
		deleteBucketErr: errors.New("boom"),
		buckets:         []s3types.Bucket{{Name: aws.String("conformance-standalone-orphan")}},
		bucketTags:      map[string][]s3types.Tag{"conformance-standalone-orphan": {{Key: aws.String("RunID"), Value: aws.String("run-7")}}},
	}
	cfg := S3CleanupConfig{Region: "us-west-2", Bucket: "my-bucket", RunID: "run-7", BucketPrefix: "conformance-standalone-", Strict: true}
	if err := s3Cleanup(context.Background(), newTestLogger(), f, cfg); err == nil {
		t.Fatal("expected strict cleanup to propagate the direct-delete error")
	}
	if f.called("ListBuckets") == 0 {
		t.Error("sweep must still run after a direct-delete error (no early return)")
	}
}

// A sweep requested without a run-id is skipped (best-effort) and errors under -strict.
func TestS3Cleanup_SweepWithoutRunID(t *testing.T) {
	cfg := S3CleanupConfig{Region: "us-west-2", BucketPrefix: "conformance-standalone-"} // RunID empty
	f := &fakeS3{buckets: []s3types.Bucket{{Name: aws.String("conformance-standalone-x")}}}
	if err := s3Cleanup(context.Background(), newTestLogger(), f, cfg); err != nil {
		t.Fatalf("non-strict must not error: %v", err)
	}
	if f.called("ListBuckets") != 0 {
		t.Error("sweep must be skipped when run-id is empty")
	}

	cfg.Strict = true
	if err := s3Cleanup(context.Background(), newTestLogger(), &fakeS3{}, cfg); err == nil {
		t.Fatal("expected strict cleanup to error when a sweep is requested without run-id")
	}
}

// A non-404 HeadObject error (e.g. 403) must surface, not be treated as "object absent".
func TestS3Download_Non404ErrorSurfaces(t *testing.T) {
	f := &fakeS3{headObjectErr: &smithy.GenericAPIError{Code: "Forbidden", Message: "403"}}
	cfg := S3DownloadConfig{Region: "us-west-2", Bucket: "b", Key: "results.tar.gz", Dest: filepath.Join(t.TempDir(), "r.tar.gz")}
	if err := s3Download(context.Background(), newTestLogger(), f, cfg); err == nil {
		t.Fatal("expected a non-404 HeadObject error to surface")
	}
	if f.called("GetObject") != 0 {
		t.Errorf("must not GetObject when HeadObject failed with a non-404 error")
	}
}

// A GetObject failure after a successful HeadObject must surface (before any file is created).
func TestS3Download_GetObjectErrorSurfaces(t *testing.T) {
	f := &fakeS3{getObjectErr: errors.New("connection reset")}
	dest := filepath.Join(t.TempDir(), "r.tar.gz")
	cfg := S3DownloadConfig{Region: "us-west-2", Bucket: "b", Key: "results.tar.gz", Dest: dest}
	if err := s3Download(context.Background(), newTestLogger(), f, cfg); err == nil {
		t.Fatal("expected a GetObject error to surface")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Errorf("dest must not exist when the download failed")
	}
}

// A body that fails mid-stream must surface AND not leave a truncated file behind.
func TestS3Download_CopyErrorRemovesPartialFile(t *testing.T) {
	f := &fakeS3{getObjectReadErr: errors.New("stream reset mid-copy")}
	dest := filepath.Join(t.TempDir(), "r.tar.gz")
	cfg := S3DownloadConfig{Region: "us-west-2", Bucket: "b", Key: "results.tar.gz", Dest: dest}
	if err := s3Download(context.Background(), newTestLogger(), f, cfg); err == nil {
		t.Fatal("expected a mid-stream copy error to surface")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Errorf("a truncated dest file must be removed on copy failure")
	}
}

// The sweep must paginate ListBuckets and reap tagged orphans on every page.
func TestSweepBuckets_Paginates(t *testing.T) {
	f := &fakeS3{
		bucketPages: [][]s3types.Bucket{
			{{Name: aws.String("conformance-standalone-a")}},
			{{Name: aws.String("conformance-standalone-b")}},
		},
		bucketTags: map[string][]s3types.Tag{
			"conformance-standalone-a": {{Key: aws.String("RunID"), Value: aws.String("run-9")}},
			"conformance-standalone-b": {{Key: aws.String("RunID"), Value: aws.String("run-9")}},
		},
	}
	if err := sweepBuckets(context.Background(), newTestLogger(), f, "us-west-2", "conformance-standalone-", "run-9"); err != nil {
		t.Fatalf("sweepBuckets: %v", err)
	}
	if f.called("ListBuckets") != 2 {
		t.Errorf("expected 2 ListBuckets pages walked, got %d", f.called("ListBuckets"))
	}
	if !slices.Contains(f.deletedBuckets, "conformance-standalone-a") || !slices.Contains(f.deletedBuckets, "conformance-standalone-b") {
		t.Errorf("expected the tagged orphan on each page swept, got %v", f.deletedBuckets)
	}
}

// A ListBuckets error must surface out of the sweep.
func TestSweepBuckets_ListErrorSurfaces(t *testing.T) {
	f := &fakeS3{listBucketsErr: errors.New("throttled")}
	if err := sweepBuckets(context.Background(), newTestLogger(), f, "us-west-2", "conformance-standalone-", "run-9"); err == nil {
		t.Fatal("expected a ListBuckets error to surface")
	}
}

// A transport-level DeleteObjects error must surface (distinct from per-object errors).
func TestDeleteObjectPage_TransportErrorSurfaces(t *testing.T) {
	f := &fakeS3{deleteObjectsErr: errors.New("500 InternalError")}
	err := deleteObjectPage(context.Background(), f, "b", []s3types.Object{{Key: aws.String("k")}})
	if err == nil {
		t.Fatal("expected a transport DeleteObjects error to surface")
	}
}

// A GET presign failure must abort s3Stage (symmetric with the PUT case).
func TestS3Stage_PresignGetErrorPropagates(t *testing.T) {
	f := &fakeS3{headBucketErr: &s3types.NotFound{}}
	p := &fakePresigner{getErr: errors.New("presign get failed")}
	cfg := S3StageConfig{
		Region:   "us-west-2",
		RunID:    "r",
		Bucket:   "b",
		Presigns: []presignSpec{{Key: "vcluster.tar", Method: "get"}},
	}
	if _, err := s3Stage(context.Background(), newTestLogger(), f, p, cfg); err == nil {
		t.Fatal("expected a GET presign error to propagate")
	}
}

// With no -expires-in, s3Stage must presign using the default lifetime, not zero.
func TestS3Stage_DefaultExpiryWhenUnset(t *testing.T) {
	f := &fakeS3{headBucketErr: &s3types.NotFound{}}
	p := &fakePresigner{}
	cfg := S3StageConfig{
		Region:   "us-west-2",
		RunID:    "r",
		Bucket:   "b",
		Presigns: []presignSpec{{Key: "results.tar.gz", Method: "put"}},
		// ExpiresIn intentionally left zero to exercise the fallback.
	}
	if _, err := s3Stage(context.Background(), newTestLogger(), f, p, cfg); err != nil {
		t.Fatalf("s3Stage: %v", err)
	}
	if p.lastExpiry != defaultPresignExpiry {
		t.Errorf("zero ExpiresIn should fall back to %v, got %v", defaultPresignExpiry, p.lastExpiry)
	}
}

// A PutBucketTagging failure must surface (an un-tagged bucket would escape the sweep).
func TestEnsureBucket_TagErrorSurfaces(t *testing.T) {
	f := &fakeS3{headBucketErr: &s3types.NotFound{}, putTaggingErr: errors.New("access denied")}
	if err := ensureBucket(context.Background(), newTestLogger(), f, "b", "us-west-2", "r"); err == nil {
		t.Fatal("expected a PutBucketTagging error to surface")
	}
}

// A PutObject failure must abort s3Stage.
func TestS3Stage_UploadErrorSurfaces(t *testing.T) {
	local := filepath.Join(t.TempDir(), "artifact")
	if err := os.WriteFile(local, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	f := &fakeS3{headBucketErr: &s3types.NotFound{}, putObjectErr: errors.New("upload failed")}
	cfg := S3StageConfig{Region: "us-west-2", RunID: "r", Bucket: "b", Uploads: []uploadSpec{{Local: local, Key: "k"}}}
	if _, err := s3Stage(context.Background(), newTestLogger(), f, &fakePresigner{}, cfg); err == nil {
		t.Fatal("expected a PutObject error to surface")
	}
}

// A non-NoSuchTagSet tag-read error during the sweep must skip the bucket without deleting it.
func TestSweepBuckets_TagReadErrorSkips(t *testing.T) {
	f := &fakeS3{
		buckets:             []s3types.Bucket{{Name: aws.String("conformance-standalone-x")}},
		getBucketTaggingErr: errors.New("throttled"),
	}
	if err := sweepBuckets(context.Background(), newTestLogger(), f, "us-west-2", "conformance-standalone-", "run-1"); err != nil {
		t.Fatalf("best-effort sweep should not error on a tag-read failure: %v", err)
	}
	if len(f.deletedBuckets) != 0 {
		t.Errorf("must not delete a bucket whose tags could not be read, got %v", f.deletedBuckets)
	}
}

// A ListObjectsV2 error (not NoSuchBucket) must surface from emptyAndDeleteBucket.
func TestEmptyAndDeleteBucket_ListErrorSurfaces(t *testing.T) {
	f := &fakeS3{listObjectsErr: errors.New("throttled")}
	if err := emptyAndDeleteBucket(context.Background(), newTestLogger(), f, "b"); err == nil {
		t.Fatal("expected a ListObjectsV2 error to surface")
	}
	if f.called("DeleteBucket") != 0 {
		t.Error("must not delete the bucket when listing its objects failed")
	}
}

// s3Download creates the dest's parent directory if it does not exist.
func TestS3Download_CreatesNestedDest(t *testing.T) {
	f := &fakeS3{getObjectBody: "archive"}
	dest := filepath.Join(t.TempDir(), "nested", "sub", "results.tar.gz")
	cfg := S3DownloadConfig{Region: "us-west-2", Bucket: "b", Key: "results.tar.gz", Dest: dest}
	if err := s3Download(context.Background(), newTestLogger(), f, cfg); err != nil {
		t.Fatalf("s3Download: %v", err)
	}
	got, err := os.ReadFile(dest)
	if err != nil {
		t.Fatalf("nested dest not written: %v", err)
	}
	if string(got) != "archive" {
		t.Errorf("dest content = %q", got)
	}
}

// A NoSuchBucket during listing means the bucket is already gone: a no-op, not an error.
func TestEmptyAndDeleteBucket_AlreadyGoneIsNoOp(t *testing.T) {
	f := &fakeS3{listObjectsErr: &s3types.NoSuchBucket{}}
	if err := emptyAndDeleteBucket(context.Background(), newTestLogger(), f, "b"); err != nil {
		t.Fatalf("an already-gone bucket must be a no-op, got %v", err)
	}
	if f.called("DeleteBucket") != 0 {
		t.Error("must not call DeleteBucket for an already-gone bucket")
	}
}
