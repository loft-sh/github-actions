package main

import (
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func sampleIDs() ResourceIDs {
	return ResourceIDs{
		VPCID:           "vpc-abc",
		IGWID:           "igw-def",
		SubnetID:        "subnet-001",
		RouteTableID:    "rtb-002",
		RouteAssocID:    "rtbassoc-003",
		SecurityGroupID: "sg-004",
		AMIID:           "ami-005",
		InstanceIDs:     []string{"i-1", "i-2", "i-3"},
		InstanceIDByRole: map[string]string{
			"primary": "i-1",
			"worker1": "i-2",
			"worker2": "i-3",
		},
		PrimaryPublicIP: "1.2.3.4",
	}
}

func TestEmitOutput_GitHubOutput(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "GITHUB_OUTPUT")

	if err := emitOutput(newTestLogger(), path, "github-output", sampleIDs()); err != nil {
		t.Fatalf("emitOutput: %v", err)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	s := string(body)
	for _, want := range []string{
		"vpc_id=vpc-abc",
		"igw_id=igw-def",
		"subnet_id=subnet-001",
		"route_table_id=rtb-002",
		"route_assoc_id=rtbassoc-003",
		"security_group_id=sg-004",
		"ami_id=ami-005",
		"primary_public_ip=1.2.3.4",
		"instance_ids=i-1,i-2,i-3",
		"instance_id_primary=i-1",
		"instance_id_worker1=i-2",
		"instance_id_worker2=i-3",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("output missing %q\nfull output:\n%s", want, s)
		}
	}

	// instance_id_by_role must round-trip as valid JSON the action consumer
	// can parse with fromJSON. Map ordering is non-deterministic; assert
	// the three pairs by parsing.
	for _, line := range strings.Split(s, "\n") {
		const prefix = "instance_id_by_role="
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		var got map[string]string
		if err := json.Unmarshal([]byte(line[len(prefix):]), &got); err != nil {
			t.Fatalf("instance_id_by_role is not valid JSON: %v\n%s", err, line)
		}
		if got["primary"] != "i-1" || got["worker1"] != "i-2" || got["worker2"] != "i-3" {
			t.Errorf("instance_id_by_role mis-parsed: %+v", got)
		}
		return
	}
	t.Errorf("instance_id_by_role line not found in output:\n%s", s)
}

func TestEmitOutput_NonStandardRoles(t *testing.T) {
	// Consumers with arbitrary role names (e.g. "primary,secondary") must
	// be able to retrieve instance IDs via the JSON map output, since the
	// hardcoded primary/worker1/worker2 outputs only cover the common case.
	dir := t.TempDir()
	path := filepath.Join(dir, "GITHUB_OUTPUT")

	ids := ResourceIDs{
		InstanceIDs:      []string{"i-a", "i-b"},
		InstanceIDByRole: map[string]string{"primary": "i-a", "secondary": "i-b"},
	}
	if err := emitOutput(newTestLogger(), path, "github-output", ids); err != nil {
		t.Fatalf("emitOutput: %v", err)
	}
	body, _ := os.ReadFile(path)
	s := string(body)

	for _, line := range strings.Split(s, "\n") {
		const prefix = "instance_id_by_role="
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		var got map[string]string
		if err := json.Unmarshal([]byte(line[len(prefix):]), &got); err != nil {
			t.Fatalf("not valid JSON: %v", err)
		}
		if got["primary"] != "i-a" || got["secondary"] != "i-b" {
			t.Errorf("non-standard roles not preserved: %+v", got)
		}
		return
	}
	t.Errorf("instance_id_by_role line missing for non-standard roles:\n%s", s)
}

func TestEmitOutput_AutoFormatInfersFromPath(t *testing.T) {
	dir := t.TempDir()

	envPath := filepath.Join(dir, "GITHUB_ENV")
	if err := emitOutput(newTestLogger(), envPath, "auto", sampleIDs()); err != nil {
		t.Fatalf("emitOutput: %v", err)
	}
	body, _ := os.ReadFile(envPath)
	if !strings.Contains(string(body), "vpc_id=vpc-abc") {
		t.Errorf("expected key=value format for GITHUB_ENV path, got:\n%s", body)
	}

	// A plain path that doesn't match either marker should default to JSON.
	jsonPath := filepath.Join(dir, "out.txt")
	if err := emitOutput(newTestLogger(), jsonPath, "auto", sampleIDs()); err != nil {
		t.Fatalf("emitOutput: %v", err)
	}
	body, _ = os.ReadFile(jsonPath)
	var got ResourceIDs
	if err := json.Unmarshal(body, &got); err != nil {
		t.Errorf("expected JSON for unrecognized path, got: %s\nerr: %v", body, err)
	}
}

func TestEmitOutput_AppendsRatherThanOverwrites(t *testing.T) {
	// GITHUB_OUTPUT and GITHUB_ENV are both append-mode files in real
	// GitHub Actions. A run that calls emitOutput twice (e.g. provision
	// success path + an additional metadata write) must accumulate both
	// sets of pairs, not lose the first one.
	dir := t.TempDir()
	path := filepath.Join(dir, "GITHUB_OUTPUT")

	first := sampleIDs()
	first.VPCID = "vpc-first"
	if err := emitOutput(newTestLogger(), path, "github-output", first); err != nil {
		t.Fatalf("first emit: %v", err)
	}
	second := sampleIDs()
	second.VPCID = "vpc-second"
	if err := emitOutput(newTestLogger(), path, "github-output", second); err != nil {
		t.Fatalf("second emit: %v", err)
	}

	body, _ := os.ReadFile(path)
	s := string(body)
	if !strings.Contains(s, "vpc_id=vpc-first") {
		t.Errorf("expected first emission to be preserved, got:\n%s", s)
	}
	if !strings.Contains(s, "vpc_id=vpc-second") {
		t.Errorf("expected second emission to be appended, got:\n%s", s)
	}
}
