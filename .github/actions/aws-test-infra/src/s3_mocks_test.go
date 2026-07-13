package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	v4 "github.com/aws/aws-sdk-go-v2/aws/signer/v4"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	s3types "github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/smithy-go"
)

// fakeS3 is a hand-rolled S3API mock (mirrors fakeEC2): it records calls and
// returns happy-path responses unless a field stages an error or fixture.
type fakeS3 struct {
	mu    sync.Mutex
	calls []string

	// staged behavior
	headBucketErr       error
	createBucketErr     error
	putTaggingErr       error // error from PutBucketTagging
	putObjectErr        error // error from PutObject
	headObjectErr       error
	getObjectBody       string
	getObjectErr        error           // error from GetObject itself (Head succeeded)
	getObjectReadErr    error           // error raised mid-stream while reading the body
	listObjectsErr      error           // error from ListObjectsV2
	deleteObjectsErr    error           // transport-level error from DeleteObjects
	deleteObjectErrs    []s3types.Error // per-object failures in a 200 response
	deleteBucketErr     error           // error from DeleteBucket
	listBucketsErr      error           // error from ListBuckets
	getBucketTaggingErr error           // generic (non-NoSuchTagSet) error from GetBucketTagging

	// object listing for cleanup: one entry per ListObjectsV2 page. Each page
	// reports IsTruncated=true until the last one so pagination is exercised.
	listPages [][]s3types.Object
	listIdx   int

	// bucket sweep fixtures
	buckets    []s3types.Bucket
	bucketTags map[string][]s3types.Tag

	// bucketPages, if set, makes ListBuckets return one page per entry with a
	// continuation token until the last, so the sweep pagination loop is exercised.
	bucketPages    [][]s3types.Bucket
	listBucketsIdx int

	// captured inputs / effects
	createBucketInput *s3.CreateBucketInput
	putTaggingInput   *s3.PutBucketTaggingInput
	uploadedKeys      []string
	deletedKeys       []string
	deletedBuckets    []string
}

func (f *fakeS3) record(m string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, m)
}

func (f *fakeS3) called(m string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.calls {
		if c == m {
			n++
		}
	}
	return n
}

func (f *fakeS3) HeadBucket(_ context.Context, _ *s3.HeadBucketInput, _ ...func(*s3.Options)) (*s3.HeadBucketOutput, error) {
	f.record("HeadBucket")
	if f.headBucketErr != nil {
		return nil, f.headBucketErr
	}
	return &s3.HeadBucketOutput{}, nil
}

func (f *fakeS3) CreateBucket(_ context.Context, in *s3.CreateBucketInput, _ ...func(*s3.Options)) (*s3.CreateBucketOutput, error) {
	f.record("CreateBucket")
	f.createBucketInput = in
	if f.createBucketErr != nil {
		return nil, f.createBucketErr
	}
	return &s3.CreateBucketOutput{}, nil
}

func (f *fakeS3) PutBucketTagging(_ context.Context, in *s3.PutBucketTaggingInput, _ ...func(*s3.Options)) (*s3.PutBucketTaggingOutput, error) {
	f.record("PutBucketTagging")
	f.putTaggingInput = in
	if f.putTaggingErr != nil {
		return nil, f.putTaggingErr
	}
	return &s3.PutBucketTaggingOutput{}, nil
}

func (f *fakeS3) PutObject(_ context.Context, in *s3.PutObjectInput, _ ...func(*s3.Options)) (*s3.PutObjectOutput, error) {
	f.record("PutObject")
	if f.putObjectErr != nil {
		return nil, f.putObjectErr
	}
	f.uploadedKeys = append(f.uploadedKeys, aws.ToString(in.Key))
	return &s3.PutObjectOutput{}, nil
}

func (f *fakeS3) HeadObject(_ context.Context, _ *s3.HeadObjectInput, _ ...func(*s3.Options)) (*s3.HeadObjectOutput, error) {
	f.record("HeadObject")
	if f.headObjectErr != nil {
		return nil, f.headObjectErr
	}
	return &s3.HeadObjectOutput{}, nil
}

func (f *fakeS3) GetObject(_ context.Context, _ *s3.GetObjectInput, _ ...func(*s3.Options)) (*s3.GetObjectOutput, error) {
	f.record("GetObject")
	if f.getObjectErr != nil {
		return nil, f.getObjectErr
	}
	if f.getObjectReadErr != nil {
		return &s3.GetObjectOutput{Body: io.NopCloser(&errReader{err: f.getObjectReadErr})}, nil
	}
	return &s3.GetObjectOutput{Body: io.NopCloser(bytes.NewBufferString(f.getObjectBody))}, nil
}

// errReader fails on Read, simulating a body that errors mid-stream.
type errReader struct{ err error }

func (r *errReader) Read([]byte) (int, error) { return 0, r.err }

func (f *fakeS3) ListObjectsV2(_ context.Context, _ *s3.ListObjectsV2Input, _ ...func(*s3.Options)) (*s3.ListObjectsV2Output, error) {
	f.record("ListObjectsV2")
	if f.listObjectsErr != nil {
		return nil, f.listObjectsErr
	}
	var page []s3types.Object
	if f.listIdx < len(f.listPages) {
		page = f.listPages[f.listIdx]
	}
	f.listIdx++
	// Report truncation (with a continuation token) while more pages remain so
	// the caller's pagination loop is genuinely exercised.
	truncated := f.listIdx < len(f.listPages)
	out := &s3.ListObjectsV2Output{Contents: page, IsTruncated: aws.Bool(truncated)}
	if truncated {
		out.NextContinuationToken = aws.String(fmt.Sprintf("token-%d", f.listIdx))
	}
	return out, nil
}

func (f *fakeS3) DeleteObjects(_ context.Context, in *s3.DeleteObjectsInput, _ ...func(*s3.Options)) (*s3.DeleteObjectsOutput, error) {
	f.record("DeleteObjects")
	if f.deleteObjectsErr != nil {
		return nil, f.deleteObjectsErr
	}
	if in.Delete != nil {
		for _, o := range in.Delete.Objects {
			f.deletedKeys = append(f.deletedKeys, aws.ToString(o.Key))
		}
	}
	// Per-object failures ride back in a 200 response (nil transport error).
	return &s3.DeleteObjectsOutput{Errors: f.deleteObjectErrs}, nil
}

func (f *fakeS3) DeleteBucket(_ context.Context, in *s3.DeleteBucketInput, _ ...func(*s3.Options)) (*s3.DeleteBucketOutput, error) {
	f.record("DeleteBucket")
	if f.deleteBucketErr != nil {
		return nil, f.deleteBucketErr
	}
	f.deletedBuckets = append(f.deletedBuckets, aws.ToString(in.Bucket))
	return &s3.DeleteBucketOutput{}, nil
}

func (f *fakeS3) ListBuckets(_ context.Context, _ *s3.ListBucketsInput, _ ...func(*s3.Options)) (*s3.ListBucketsOutput, error) {
	f.record("ListBuckets")
	if f.listBucketsErr != nil {
		return nil, f.listBucketsErr
	}
	if len(f.bucketPages) > 0 {
		var page []s3types.Bucket
		if f.listBucketsIdx < len(f.bucketPages) {
			page = f.bucketPages[f.listBucketsIdx]
		}
		f.listBucketsIdx++
		out := &s3.ListBucketsOutput{Buckets: page}
		if f.listBucketsIdx < len(f.bucketPages) {
			out.ContinuationToken = aws.String(fmt.Sprintf("bkt-token-%d", f.listBucketsIdx))
		}
		return out, nil
	}
	return &s3.ListBucketsOutput{Buckets: f.buckets}, nil
}

func (f *fakeS3) GetBucketTagging(_ context.Context, in *s3.GetBucketTaggingInput, _ ...func(*s3.Options)) (*s3.GetBucketTaggingOutput, error) {
	f.record("GetBucketTagging")
	if f.getBucketTaggingErr != nil {
		return nil, f.getBucketTaggingErr
	}
	name := aws.ToString(in.Bucket)
	tags, ok := f.bucketTags[name]
	if !ok {
		// Untagged bucket: the real API returns NoSuchTagSet; the sweep treats
		// that as "no RunID tag → skip quietly".
		return nil, &smithy.GenericAPIError{Code: "NoSuchTagSet", Message: "The TagSet does not exist"}
	}
	return &s3.GetBucketTaggingOutput{TagSet: tags}, nil
}

// fakePresigner satisfies S3Presigner, returning deterministic URLs and
// recording the expiry the caller applied via the PresignOptions functions.
type fakePresigner struct {
	getErr     error
	putErr     error
	lastExpiry time.Duration
}

func (p *fakePresigner) applyExpiry(optFns []func(*s3.PresignOptions)) {
	var o s3.PresignOptions
	for _, fn := range optFns {
		fn(&o)
	}
	p.lastExpiry = o.Expires
}

func (p *fakePresigner) PresignGetObject(_ context.Context, in *s3.GetObjectInput, optFns ...func(*s3.PresignOptions)) (*v4.PresignedHTTPRequest, error) {
	p.applyExpiry(optFns)
	if p.getErr != nil {
		return nil, p.getErr
	}
	return &v4.PresignedHTTPRequest{URL: "https://presigned.example/GET/" + aws.ToString(in.Key), Method: "GET"}, nil
}

func (p *fakePresigner) PresignPutObject(_ context.Context, in *s3.PutObjectInput, optFns ...func(*s3.PresignOptions)) (*v4.PresignedHTTPRequest, error) {
	p.applyExpiry(optFns)
	if p.putErr != nil {
		return nil, p.putErr
	}
	return &v4.PresignedHTTPRequest{URL: "https://presigned.example/PUT/" + aws.ToString(in.Key), Method: "PUT"}, nil
}
