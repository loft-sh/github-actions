package main

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

func TestCleanup_DirectOrdering(t *testing.T) {
	// Direct cleanup must mirror the existing Bash teardown order. Subnet
	// can't be deleted while instances are still attached; SG can't be
	// deleted while ENIs reference it; VPC can't be deleted while it owns
	// any of the above.
	c := &fakeEC2{}
	w := &fakeWaiter{}
	cfg := CleanupConfig{
		Region:          "us-west-2",
		RunID:           "run-42",
		VPCID:           "vpc-1",
		IGWID:           "igw-1",
		SubnetID:        "subnet-1",
		RouteTableID:    "rtb-1",
		RouteAssocID:    "rtbassoc-1",
		SecurityGroupID: "sg-1",
		InstanceIDs:     []string{"i-1", "i-2", "i-3"},
		SkipSweep:       true,
	}

	if err := Cleanup(context.Background(), newTestLogger(), c, w, cfg); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}

	want := []string{
		"TerminateInstances",
		"DeleteSecurityGroup",
		"DisassociateRouteTable",
		"DeleteRouteTable",
		"DeleteSubnet",
		"DetachInternetGateway",
		"DeleteInternetGateway",
		"DeleteVpc",
	}
	seq := methodSequence(c.calls)
	if err := requireOrdering(seq, want); err != nil {
		t.Fatal(err)
	}

	// Dependency-critical strict checks. AWS rejects the dependent
	// delete with InUse errors if the parent isn't torn down first;
	// these catch bugs that requireOrdering's subsequence match would
	// silently accept.
	//
	// Disassociate must IMMEDIATELY precede DeleteRouteTable: any other
	// call between them would mean we tried to delete the route table
	// while still associated, which AWS rejects.
	if err := requireImmediatelyAfter(seq, "DisassociateRouteTable", "DeleteRouteTable"); err != nil {
		t.Errorf("disassociate→delete-RT not immediate: %v", err)
	}
	// Same for IGW: detach must immediately precede delete.
	if err := requireImmediatelyAfter(seq, "DetachInternetGateway", "DeleteInternetGateway"); err != nil {
		t.Errorf("detach→delete-IGW not immediate: %v", err)
	}
	// Subnet/SG/VPC deletes can happen only after instances are
	// terminated (else "DependencyViolation" / "InvalidGroup.InUse").
	for _, after := range []string{"DeleteSecurityGroup", "DeleteSubnet", "DeleteVpc"} {
		if err := requireBefore(seq, "TerminateInstances", after); err != nil {
			t.Errorf("TerminateInstances must precede %s: %v", after, err)
		}
	}

	if len(w.termCalls) != 1 {
		t.Errorf("expected 1 wait-instance-terminated call, got %d", len(w.termCalls))
	}
}

func TestCleanup_SweepOnlyHandlesOrphans(t *testing.T) {
	// A run that fails before exporting any IDs leaves no direct cleanup
	// targets; the sweep must still find the orphaned resources and
	// delete them in dependency order.
	c := &fakeEC2{
		sweepResources: sweepFixture{
			Instances: []string{"i-orphan-1", "i-orphan-2"},
			SGs:       []string{"sg-orphan"},
			RouteTables: []routeTableFixture{
				{ID: "rtb-orphan", AssociationIDs: []string{"rtbassoc-orphan"}},
			},
			Subnets: []string{"subnet-orphan"},
			IGWs: []igwFixture{
				{ID: "igw-orphan", VPCs: []string{"vpc-orphan"}},
			},
			VPCs: []string{"vpc-orphan"},
		},
	}
	w := &fakeWaiter{}
	cfg := CleanupConfig{Region: "us-west-2", RunID: "run-42", SkipDirect: true}

	if err := Cleanup(context.Background(), newTestLogger(), c, w, cfg); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}

	// Ordering: instances → SG → RT (disassoc + delete) → subnet → IGW
	// (detach + delete) → VPC.
	want := []string{
		"DescribeInstances",
		"TerminateInstances",
		"DescribeSecurityGroups",
		"DeleteSecurityGroup",
		"DescribeRouteTables",
		"DisassociateRouteTable",
		"DeleteRouteTable",
		"DescribeSubnets",
		"DeleteSubnet",
		"DescribeInternetGateways",
		"DetachInternetGateway",
		"DeleteInternetGateway",
		"DescribeVpcs",
		"DeleteVpc",
	}
	if err := requireOrdering(methodSequence(c.calls), want); err != nil {
		t.Fatalf("sweep ordering wrong: %v", err)
	}
}

func TestCleanup_SweepFiltersByRunIDTag(t *testing.T) {
	// The sweep must filter by tag:RunID = the supplied run-id. A bug
	// here could cause cleanup to delete unrelated resources in the
	// account.
	c := &fakeEC2{}
	w := &fakeWaiter{}
	cfg := CleanupConfig{Region: "us-west-2", RunID: "run-42", SkipDirect: true}

	if err := Cleanup(context.Background(), newTestLogger(), c, w, cfg); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}

	for _, call := range c.calls {
		switch in := call.Input.(type) {
		case *ec2.DescribeVpcsInput:
			assertHasTagFilter(t, "DescribeVpcs", in.Filters, "run-42")
		case *ec2.DescribeSubnetsInput:
			assertHasTagFilter(t, "DescribeSubnets", in.Filters, "run-42")
		case *ec2.DescribeRouteTablesInput:
			assertHasTagFilter(t, "DescribeRouteTables", in.Filters, "run-42")
		case *ec2.DescribeSecurityGroupsInput:
			assertHasTagFilter(t, "DescribeSecurityGroups", in.Filters, "run-42")
		case *ec2.DescribeInternetGatewaysInput:
			assertHasTagFilter(t, "DescribeInternetGateways", in.Filters, "run-42")
		case *ec2.DescribeInstancesInput:
			assertHasTagFilter(t, "DescribeInstances", in.Filters, "run-42")
		}
	}
}

func TestCleanup_SweepIGWDetachesEveryAttachment(t *testing.T) {
	// If an orphan IGW is attached to multiple VPCs (rare but possible
	// after a botched run), every attachment must be detached before the
	// IGW can be deleted.
	c := &fakeEC2{
		sweepResources: sweepFixture{
			IGWs: []igwFixture{
				{ID: "igw-multi", VPCs: []string{"vpc-a", "vpc-b"}},
			},
		},
	}
	w := &fakeWaiter{}
	cfg := CleanupConfig{Region: "us-west-2", RunID: "run-42", SkipDirect: true}

	if err := Cleanup(context.Background(), newTestLogger(), c, w, cfg); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}

	detaches := 0
	for _, call := range c.calls {
		if call.Method == "DetachInternetGateway" {
			detaches++
		}
	}
	if detaches != 2 {
		t.Errorf("expected 2 DetachInternetGateway calls (one per attached VPC), got %d", detaches)
	}
}

func TestCleanup_SkipDirect(t *testing.T) {
	// With -skip-direct, supplied IDs must be ignored. The sweep still
	// runs but doesn't touch them (sweep only acts on tag-discovered
	// resources, and we stage no sweep resources here).
	//
	// We assert this by inspecting every Delete*/Terminate* call and
	// confirming none were issued against the supplied direct-path IDs.
	c := &fakeEC2{}
	w := &fakeWaiter{}
	cfg := CleanupConfig{
		Region:          "us-west-2",
		RunID:           "run-42",
		VPCID:           "vpc-direct",
		IGWID:           "igw-direct",
		SubnetID:        "subnet-direct",
		RouteTableID:    "rtb-direct",
		RouteAssocID:    "rtbassoc-direct",
		SecurityGroupID: "sg-direct",
		InstanceIDs:     []string{"i-direct-1", "i-direct-2"},
		SkipDirect:      true,
	}

	if err := Cleanup(context.Background(), newTestLogger(), c, w, cfg); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}

	for _, call := range c.calls {
		switch in := call.Input.(type) {
		case *ec2.TerminateInstancesInput:
			for _, id := range in.InstanceIds {
				if strings.HasPrefix(id, "i-direct") {
					t.Errorf("TerminateInstances(%s) ran despite SkipDirect=true (direct path leaked)", id)
				}
			}
		case *ec2.DeleteSecurityGroupInput:
			if aws.ToString(in.GroupId) == "sg-direct" {
				t.Errorf("DeleteSecurityGroup(sg-direct) ran despite SkipDirect=true")
			}
		case *ec2.DeleteSubnetInput:
			if aws.ToString(in.SubnetId) == "subnet-direct" {
				t.Errorf("DeleteSubnet(subnet-direct) ran despite SkipDirect=true")
			}
		case *ec2.DeleteRouteTableInput:
			if aws.ToString(in.RouteTableId) == "rtb-direct" {
				t.Errorf("DeleteRouteTable(rtb-direct) ran despite SkipDirect=true")
			}
		case *ec2.DisassociateRouteTableInput:
			if aws.ToString(in.AssociationId) == "rtbassoc-direct" {
				t.Errorf("DisassociateRouteTable(rtbassoc-direct) ran despite SkipDirect=true")
			}
		case *ec2.DeleteInternetGatewayInput:
			if aws.ToString(in.InternetGatewayId) == "igw-direct" {
				t.Errorf("DeleteInternetGateway(igw-direct) ran despite SkipDirect=true")
			}
		case *ec2.DetachInternetGatewayInput:
			if aws.ToString(in.InternetGatewayId) == "igw-direct" {
				t.Errorf("DetachInternetGateway(igw-direct) ran despite SkipDirect=true")
			}
		case *ec2.DeleteVpcInput:
			if aws.ToString(in.VpcId) == "vpc-direct" {
				t.Errorf("DeleteVpc(vpc-direct) ran despite SkipDirect=true")
			}
		}
	}
}

func TestCleanup_SweepErrorPropagationAtEachStage(t *testing.T) {
	// sweepByTag has six Describe* call sites, any of which can fail
	// (auth expiring, throttling, etc.). The default behavior is to log
	// + continue (matches Bash `set +e`); -strict-sweep reverses that.
	// This table covers each stage × strict mode so the contract is
	// pinned end-to-end, not just for DescribeInstances.
	stages := []string{
		"DescribeInstances",
		"DescribeSecurityGroups",
		"DescribeRouteTables",
		"DescribeSubnets",
		"DescribeInternetGateways",
		"DescribeVpcs",
	}
	for _, stage := range stages {
		for _, strict := range []bool{false, true} {
			stage, strict := stage, strict
			name := stage
			if strict {
				name += "/strict"
			} else {
				name += "/default"
			}
			t.Run(name, func(t *testing.T) {
				c := &fakeEC2{failOn: map[string]error{stage: errStaged}}
				w := &fakeWaiter{}
				cfg := CleanupConfig{
					Region:      "us-west-2",
					RunID:       "run-42",
					SkipDirect:  true,
					StrictSweep: strict,
				}
				err := Cleanup(context.Background(), newTestLogger(), c, w, cfg)
				if strict && err == nil {
					t.Errorf("strict-sweep on with %s failure: expected error, got nil", stage)
				}
				if !strict && err != nil {
					t.Errorf("strict-sweep off with %s failure: expected nil, got %v", stage, err)
				}
			})
		}
	}
}

func TestCleanup_IdempotentOnEmpty(t *testing.T) {
	// Cleanup with no IDs and no orphans should succeed without error.
	c := &fakeEC2{}
	w := &fakeWaiter{}
	cfg := CleanupConfig{Region: "us-west-2", RunID: "run-42"}

	if err := Cleanup(context.Background(), newTestLogger(), c, w, cfg); err != nil {
		t.Fatalf("Cleanup on empty state errored: %v", err)
	}
}

func TestCleanup_PartialIDsDoNotPanicOnMissingFields(t *testing.T) {
	// Some workflow runs fail mid-provision and only export half the
	// IDs. Cleanup must tolerate any subset.
	c := &fakeEC2{}
	w := &fakeWaiter{}
	cfg := CleanupConfig{
		Region:    "us-west-2",
		RunID:     "run-42",
		VPCID:     "vpc-1",      // present
		SubnetID:  "subnet-1",   // present
		// IGWID intentionally empty
		// RouteTableID intentionally empty
		SkipSweep: true,
	}

	if err := Cleanup(context.Background(), newTestLogger(), c, w, cfg); err != nil {
		t.Fatalf("Cleanup with partial IDs errored: %v", err)
	}

	// Should call DeleteSubnet and DeleteVpc but not DeleteInternetGateway
	for _, call := range c.calls {
		if call.Method == "DeleteInternetGateway" {
			t.Errorf("DeleteInternetGateway called despite empty IGWID")
		}
		if call.Method == "DeleteRouteTable" {
			t.Errorf("DeleteRouteTable called despite empty RouteTableID")
		}
	}
}

func TestCleanup_SharedNetworkIsNeverDeleted(t *testing.T) {
	// The direct path deletes whatever IDs it is given. Every ID here is
	// tagged Project=shared-e2e-network, so none of the network resources
	// may be deleted, detached or disassociated. Instances and the security
	// group are test-owned and must still be removed.
	c := &fakeEC2{resourceTags: map[string][]types.Tag{
		"vpc-shared":    sharedNetworkTags(),
		"igw-shared":    sharedNetworkTags(),
		"subnet-shared": sharedNetworkTags(),
		"rtb-shared":    sharedNetworkTags(),
	}}
	w := &fakeWaiter{}
	var logs bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logs, nil))
	cfg := CleanupConfig{
		Region:          "us-west-2",
		RunID:           "run-42",
		VPCID:           "vpc-shared",
		IGWID:           "igw-shared",
		SubnetID:        "subnet-shared",
		RouteTableID:    "rtb-shared",
		RouteAssocID:    "rtbassoc-shared",
		SecurityGroupID: "sg-test",
		InstanceIDs:     []string{"i-1", "i-2"},
		SkipSweep:       true,
	}

	if err := Cleanup(context.Background(), logger, c, w, cfg); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}

	for _, m := range networkMutations {
		if n := callCount(c.calls, m); n != 0 {
			t.Errorf("%s called %d times against the shared network, want 0", m, n)
		}
	}
	if n := callCount(c.calls, "TerminateInstances"); n != 1 {
		t.Errorf("TerminateInstances called %d times, want 1", n)
	}
	if len(w.termCalls) != 1 {
		t.Errorf("expected 1 wait-instance-terminated call, got %d", len(w.termCalls))
	}
	if n := callCount(c.calls, "DeleteSecurityGroup"); n != 1 {
		t.Errorf("DeleteSecurityGroup called %d times, want 1 (the security group is test-owned)", n)
	}

	// One tag lookup covers all four network IDs.
	lookups := tagLookups(c.calls)
	if len(lookups) != 1 {
		t.Fatalf("expected 1 DescribeTags call, got %d", len(lookups))
	}
	want := []string{"vpc-shared", "igw-shared", "subnet-shared", "rtb-shared"}
	if got := resourceIDFilter(lookups[0]); strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("DescribeTags resource-id filter = %v, want %v", got, want)
	}

	// Each skipped ID is named in a warning.
	for _, id := range want {
		if !strings.Contains(logs.String(), id) {
			t.Errorf("log does not name skipped shared resource %s:\n%s", id, logs.String())
		}
	}
}

func TestCleanup_SharedVPCIsNotDetachedFromItsGateway(t *testing.T) {
	// Only the VPC is tagged. The VPC must survive and nothing may be
	// detached from it, even though the gateway ID itself is untagged. The
	// other untagged network resources are deleted as usual. AWS rejects
	// the gateway delete while it stays attached, which is the safe outcome.
	c := &fakeEC2{resourceTags: map[string][]types.Tag{
		"vpc-shared": sharedNetworkTags(),
	}}
	w := &fakeWaiter{}
	cfg := CleanupConfig{
		Region:       "us-west-2",
		RunID:        "run-42",
		VPCID:        "vpc-shared",
		IGWID:        "igw-test",
		SubnetID:     "subnet-test",
		RouteTableID: "rtb-test",
		RouteAssocID: "rtbassoc-test",
		SkipSweep:    true,
	}

	if err := Cleanup(context.Background(), newTestLogger(), c, w, cfg); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}

	for _, m := range []string{"DeleteVpc", "DetachInternetGateway"} {
		if n := callCount(c.calls, m); n != 0 {
			t.Errorf("%s called %d times although the VPC is shared, want 0", m, n)
		}
	}
	for _, m := range []string{"DisassociateRouteTable", "DeleteRouteTable", "DeleteSubnet", "DeleteInternetGateway"} {
		if n := callCount(c.calls, m); n != 1 {
			t.Errorf("%s called %d times for untagged test resources, want 1", m, n)
		}
	}
}

func TestCleanup_UntaggedNetworkIsDeletedAfterTagLookup(t *testing.T) {
	// IDs that are untagged, or carry look-alike tags (right key with
	// another value, another key with the shared value), are test-owned and
	// are deleted in the same order as before. The tag lookup must have run.
	c := &fakeEC2{resourceTags: map[string][]types.Tag{
		"vpc-1":    {{Key: aws.String("Project"), Value: aws.String("some-other-project")}},
		"subnet-1": {{Key: aws.String("Name"), Value: aws.String("shared-e2e-network")}},
	}}
	w := &fakeWaiter{}
	cfg := CleanupConfig{
		Region:          "us-west-2",
		RunID:           "run-42",
		VPCID:           "vpc-1",
		IGWID:           "igw-1",
		SubnetID:        "subnet-1",
		RouteTableID:    "rtb-1",
		RouteAssocID:    "rtbassoc-1",
		SecurityGroupID: "sg-1",
		InstanceIDs:     []string{"i-1"},
		SkipSweep:       true,
	}

	if err := Cleanup(context.Background(), newTestLogger(), c, w, cfg); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}

	if n := len(tagLookups(c.calls)); n != 1 {
		t.Errorf("expected 1 DescribeTags call before the network deletes, got %d", n)
	}
	want := []string{
		"TerminateInstances",
		"DeleteSecurityGroup",
		"DescribeTags",
		"DisassociateRouteTable",
		"DeleteRouteTable",
		"DeleteSubnet",
		"DetachInternetGateway",
		"DeleteInternetGateway",
		"DeleteVpc",
	}
	if err := requireOrdering(methodSequence(c.calls), want); err != nil {
		t.Fatal(err)
	}
	for _, m := range networkMutations {
		if n := callCount(c.calls, m); n != 1 {
			t.Errorf("%s called %d times for untagged resources, want 1", m, n)
		}
	}
}

func TestCleanup_TagLookupErrorSkipsNetworkDeletes(t *testing.T) {
	// If the tags cannot be read, the direct path must not delete the
	// network blind. Instances and the security group are still removed, and
	// the RunID sweep still cleans up per-test network resources.
	c := &fakeEC2{
		failOn: map[string]error{"DescribeTags": errStaged},
		sweepResources: sweepFixture{
			Subnets: []string{"subnet-orphan"},
			VPCs:    []string{"vpc-orphan"},
		},
	}
	w := &fakeWaiter{}
	var logs bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logs, nil))
	cfg := CleanupConfig{
		Region:          "us-west-2",
		RunID:           "run-42",
		VPCID:           "vpc-direct",
		IGWID:           "igw-direct",
		SubnetID:        "subnet-direct",
		RouteTableID:    "rtb-direct",
		RouteAssocID:    "rtbassoc-direct",
		SecurityGroupID: "sg-test",
		InstanceIDs:     []string{"i-1"},
	}

	if err := Cleanup(context.Background(), logger, c, w, cfg); err != nil {
		t.Fatalf("Cleanup must not fail on a tag lookup error: %v", err)
	}

	for _, call := range c.calls {
		switch in := call.Input.(type) {
		case *ec2.DeleteVpcInput:
			if id := aws.ToString(in.VpcId); id != "vpc-orphan" {
				t.Errorf("DeleteVpc(%s) ran after a failed tag lookup; only the sweep's vpc-orphan may be deleted", id)
			}
		case *ec2.DeleteSubnetInput:
			if id := aws.ToString(in.SubnetId); id != "subnet-orphan" {
				t.Errorf("DeleteSubnet(%s) ran after a failed tag lookup; only the sweep's subnet-orphan may be deleted", id)
			}
		case *ec2.DeleteRouteTableInput, *ec2.DisassociateRouteTableInput,
			*ec2.DetachInternetGatewayInput, *ec2.DeleteInternetGatewayInput:
			t.Errorf("%s ran after a failed tag lookup", call.Method)
		}
	}
	if n := callCount(c.calls, "TerminateInstances"); n != 1 {
		t.Errorf("TerminateInstances called %d times, want 1", n)
	}
	if n := callCount(c.calls, "DeleteSecurityGroup"); n != 1 {
		t.Errorf("DeleteSecurityGroup called %d times, want 1", n)
	}
	// The sweep removed the orphans it found by RunID.
	if n := callCount(c.calls, "DeleteVpc"); n != 1 {
		t.Errorf("DeleteVpc called %d times, want 1 (sweep only)", n)
	}
	if !strings.Contains(logs.String(), "tag lookup failed") {
		t.Errorf("tag lookup error was not logged:\n%s", logs.String())
	}
}

// helpers ─────────────────────────────────────────────────────────────────

func assertHasTagFilter(t *testing.T, label string, filters []types.Filter, want string) {
	t.Helper()
	for _, f := range filters {
		if aws.ToString(f.Name) != "tag:RunID" {
			continue
		}
		for _, v := range f.Values {
			if v == want {
				return
			}
		}
	}
	t.Errorf("%s: filter list missing tag:RunID = %s", label, want)
}

// sharedNetworkTags mirrors the tags on the persistent shared e2e network.
// The literals are deliberate: they pin the tag contract, so renaming the
// production constants cannot silently change what the tests protect.
func sharedNetworkTags() []types.Tag {
	return []types.Tag{
		{Key: aws.String("Project"), Value: aws.String("shared-e2e-network")},
		{Key: aws.String("DoNotNuke"), Value: aws.String("True")},
		{Key: aws.String("ManagedBy"), Value: aws.String("Terraform")},
	}
}

// networkMutations are the calls that delete, detach or disassociate
// network resources.
var networkMutations = []string{
	"DisassociateRouteTable",
	"DeleteRouteTable",
	"DeleteSubnet",
	"DetachInternetGateway",
	"DeleteInternetGateway",
	"DeleteVpc",
}

func callCount(calls []apiCall, method string) int {
	n := 0
	for _, c := range calls {
		if c.Method == method {
			n++
		}
	}
	return n
}

func tagLookups(calls []apiCall) []*ec2.DescribeTagsInput {
	var out []*ec2.DescribeTagsInput
	for _, c := range calls {
		if in, ok := c.Input.(*ec2.DescribeTagsInput); ok {
			out = append(out, in)
		}
	}
	return out
}

// resourceIDFilter returns the values of the resource-id filter of in.
func resourceIDFilter(in *ec2.DescribeTagsInput) []string {
	for _, f := range in.Filters {
		if aws.ToString(f.Name) == "resource-id" {
			return f.Values
		}
	}
	return nil
}

// silence the unused-import warning from ec2 that the test cases use only via interface
var _ = ec2.NewFromConfig
