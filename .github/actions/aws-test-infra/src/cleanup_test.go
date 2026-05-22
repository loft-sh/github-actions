package main

import (
	"context"
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

// silence the unused-import warning from ec2 that the test cases use only via interface
var _ = ec2.NewFromConfig
