package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakeAttest struct {
	err      error
	subjects []string
	args     []attestArgs
}

func (f *fakeAttest) Verify(_ context.Context, subject string, args attestArgs) error {
	f.subjects = append(f.subjects, subject)
	f.args = append(f.args, args)
	return f.err
}

type fakeDownload struct {
	path string
	url  string
}

func (f fakeDownload) Download(_ context.Context, url string) (string, error) {
	if f.url != "" && url != f.url {
		return "", fmt.Errorf("downloaded %s, want %s", url, f.url)
	}
	return f.path, nil
}

func imageSource(digest string) string {
	return "ghcr.io/loft-sh/kine:" + tag + "@" + digest
}

func TestImageModeResolvesAttestedImage(t *testing.T) {
	digest := "sha256:" + strings.Repeat("a", 64)
	source := imageSource(digest)
	attest := &fakeAttest{}
	rc, err := check(context.Background(), reviewedFork(), nil, attest, nil, options{
		mode:            "image",
		images:          multiFlag{source},
		signerWorkflows: multiFlag{fork + "=.github/workflows/release.yml"},
	}, t0)
	if err != nil {
		t.Fatal(err)
	}
	if !rc.Pass || len(rc.Forks) != 1 || len(rc.Inputs) != 1 {
		t.Fatalf("want one passing image: %+v", rc)
	}
	in := rc.Inputs[0]
	if in.Kind != "image" || in.Source != source || in.Digest != digest || in.Commit != merge || in.SignerWorkflow != fork+"/.github/workflows/release.yml" {
		t.Errorf("image input = %+v", in)
	}
	if len(attest.subjects) != 1 || attest.subjects[0] != "oci://"+source {
		t.Errorf("attestation subjects = %v", attest.subjects)
	}
	got := attest.args[0]
	if got.Owner != "loft-sh" || got.Repo != "" || got.SignerDigest != merge || got.SourceDigest != merge || got.SourceRef != "refs/tags/"+tag {
		t.Errorf("attestation args = %+v", got)
	}
}

func TestImageModeAttestationFailureIsARuleFailure(t *testing.T) {
	source := imageSource("sha256:" + strings.Repeat("a", 64))
	attest := &fakeAttest{err: fmt.Errorf("no matching attestation")}
	rc, err := check(context.Background(), reviewedFork(), nil, attest, nil, options{
		mode:            "image",
		images:          multiFlag{source},
		signerWorkflows: multiFlag{fork + "=.github/workflows/release.yml"},
	}, t0)
	if err != nil {
		t.Fatal(err)
	}
	if rc.Pass || !strings.Contains(strings.Join(rc.Failures, "\n"), source) {
		t.Fatalf("want attestation failure naming the image: %+v", rc)
	}
}

func TestImageModeRejectsUnpinnedAndUnknownImages(t *testing.T) {
	for _, source := range []string{
		"ghcr.io/loft-sh/kine:" + tag,
		"quay.io/loft-sh/kine:" + tag + "@sha256:" + strings.Repeat("a", 64),
	} {
		rc, err := check(context.Background(), reviewedFork(), nil, nil, nil, options{
			mode:            "image",
			images:          multiFlag{source},
			signerWorkflows: multiFlag{fork + "=.github/workflows/release.yml"},
		}, t0)
		if err != nil {
			t.Fatal(err)
		}
		if rc.Pass || len(rc.Failures) != 1 {
			t.Fatalf("%s should fail as one rule failure: %+v", source, rc)
		}
	}
}

func TestImageModeNeedsSignerWorkflow(t *testing.T) {
	source := imageSource("sha256:" + strings.Repeat("a", 64))
	rc, err := check(context.Background(), reviewedFork(), nil, nil, nil, options{
		mode:   "image",
		images: multiFlag{source},
	}, t0)
	if err != nil {
		t.Fatal(err)
	}
	if rc.Pass || !strings.Contains(strings.Join(rc.Failures, "\n"), "no -signer-workflow") {
		t.Fatalf("want the missing signer workflow to fail: %+v", rc)
	}
}

func TestBinaryModeResolvesAttestedAsset(t *testing.T) {
	source := "https://github.com/loft-sh/kine/releases/download/" + tag + "/kine"
	path := filepath.Join(t.TempDir(), "kine")
	if err := os.WriteFile(path, []byte("kine"), 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("kine"))
	want := hex.EncodeToString(sum[:])
	attest := &fakeAttest{}
	rc, err := check(context.Background(), reviewedFork(), nil, attest, fakeDownload{path: path, url: source}, options{
		mode:            "binary",
		urls:            multiFlag{source},
		sha256:          multiFlag{want},
		signerWorkflows: multiFlag{fork + "=.github/workflows/release.yml"},
	}, t0)
	if err != nil {
		t.Fatal(err)
	}
	if !rc.Pass || len(rc.Inputs) != 1 || rc.Inputs[0].Kind != "binary" || rc.Inputs[0].SHA256 != want {
		t.Fatalf("want one passing binary: %+v", rc)
	}
	if len(attest.args) != 1 || attest.args[0].Repo != fork || attest.args[0].Owner != "" {
		t.Errorf("attestation args = %+v", attest.args)
	}
}

func TestBinaryModeRejectsSHA256Mismatch(t *testing.T) {
	source := "https://github.com/loft-sh/kine/releases/download/" + tag + "/kine"
	path := filepath.Join(t.TempDir(), "kine")
	if err := os.WriteFile(path, []byte("kine"), 0o600); err != nil {
		t.Fatal(err)
	}
	attest := &fakeAttest{}
	rc, err := check(context.Background(), reviewedFork(), nil, attest, fakeDownload{path: path, url: source}, options{
		mode:            "binary",
		urls:            multiFlag{source},
		sha256:          multiFlag{strings.Repeat("0", 64)},
		signerWorkflows: multiFlag{fork + "=.github/workflows/release.yml"},
	}, t0)
	if err != nil {
		t.Fatal(err)
	}
	if rc.Pass || !strings.Contains(strings.Join(rc.Failures, "\n"), "sha256 is") || len(attest.args) != 0 {
		t.Fatalf("want a checksum rule failure before attestation: %+v", rc)
	}
}
