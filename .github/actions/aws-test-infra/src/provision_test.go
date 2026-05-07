package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

func baseProvisionConfig() ProvisionConfig {
	return ProvisionConfig{
		Region:         "us-west-2",
		RunID:          "run-42",
		ConsumerTagKey: "SELinuxE2E",
		ConsumerTagVal: "true",
		VPCCIDR:        "10.0.0.0/16",
		SubnetCIDR:     "10.0.1.0/24",
		AMIOwner:       "099720109477",
		AMIFilter:      "ubuntu/images/hvm-ssd*/ubuntu-jammy-22.04-amd64-server-*",
		SGName:         "selinux-e2e-42",
		IngressRules: []IngressRule{
			{Protocol: "-1", FromPort: -1, ToPort: -1, CIDR: "10.0.0.0/16"},
			{Protocol: "tcp", FromPort: 8443, ToPort: 8443, CIDR: "0.0.0.0/0"},
		},
		InstanceType:    "m5.xlarge",
		InstanceProfile: "e2e-test-executor",
		InstanceRoles:   []string{"primary", "worker1", "worker2"},
		RootDevice:      "/dev/sda1",
		VolumeSizeGB:    100,
		SkipSSMWait:     true,
	}
}

func TestProvision_HappyPath_Ordering(t *testing.T) {
	c := &fakeEC2{}
	s := &fakeSSM{online: 3}
	w := &fakeWaiter{}

	ids, err := Provision(context.Background(), newTestLogger(), c, s, w, baseProvisionConfig())
	if err != nil {
		t.Fatalf("Provision: %v", err)
	}

	want := []string{
		"CreateVpc",
		"ModifyVpcAttribute", // dns-support
		"ModifyVpcAttribute", // dns-hostnames
		"CreateInternetGateway",
		"AttachInternetGateway",
		"DescribeAvailabilityZones",
		"CreateSubnet",
		"ModifySubnetAttribute", // map-public-ip
		"CreateRouteTable",
		"CreateRoute",
		"AssociateRouteTable",
		"CreateSecurityGroup",
		"AuthorizeSecurityGroupIngress", // rule 1
		"AuthorizeSecurityGroupIngress", // rule 2
		"DescribeImages",
		"RunInstances", // primary
		"RunInstances", // worker1
		"RunInstances", // worker2
		"DescribeInstances", // primary public IP
	}
	seq := methodSequence(c.calls)
	if err := requireOrdering(seq, want); err != nil {
		t.Fatal(err)
	}

	// Strict precedes-checks for the dependency-critical pairs in
	// provisioning. These catch insertion bugs that requireOrdering
	// would silently accept.
	//
	// IGW must be attached before subnet creation; otherwise the
	// implicit route we add below would have no working gateway.
	if err := requireBefore(seq, "AttachInternetGateway", "CreateSubnet"); err != nil {
		t.Errorf("AttachInternetGateway must precede CreateSubnet: %v", err)
	}
	// Route table must exist before associate. CreateRoute and
	// AssociateRouteTable both need the route table ID.
	if err := requireBefore(seq, "CreateRouteTable", "AssociateRouteTable"); err != nil {
		t.Errorf("CreateRouteTable must precede AssociateRouteTable: %v", err)
	}
	// Security group must be created before any ingress authorization.
	if err := requireBefore(seq, "CreateSecurityGroup", "AuthorizeSecurityGroupIngress"); err != nil {
		t.Errorf("CreateSecurityGroup must precede AuthorizeSecurityGroupIngress: %v", err)
	}
	// AMI lookup must complete before instances are launched.
	if err := requireBefore(seq, "DescribeImages", "RunInstances"); err != nil {
		t.Errorf("DescribeImages must precede RunInstances: %v", err)
	}

	if ids.VPCID == "" || ids.IGWID == "" || ids.SubnetID == "" || ids.RouteTableID == "" || ids.SecurityGroupID == "" {
		t.Errorf("ResourceIDs has empty fields: %+v", ids)
	}
	if got, want := len(ids.InstanceIDs), 3; got != want {
		t.Errorf("InstanceIDs count = %d, want %d (%v)", got, want, ids.InstanceIDs)
	}
	if ids.AMIID != "ami-newest" {
		t.Errorf("AMIID = %q, want ami-newest (latest CreationDate)", ids.AMIID)
	}
	if ids.PrimaryPublicIP != "203.0.113.1" {
		t.Errorf("PrimaryPublicIP = %q, want 203.0.113.1", ids.PrimaryPublicIP)
	}
	if got := ids.InstanceIDByRole["primary"]; got != "i-primary" {
		t.Errorf("InstanceIDByRole[primary] = %q, want i-primary", got)
	}
}

func TestProvision_TagsAppliedToEveryResource(t *testing.T) {
	c := &fakeEC2{}
	s := &fakeSSM{online: 3}
	w := &fakeWaiter{}

	if _, err := Provision(context.Background(), newTestLogger(), c, s, w, baseProvisionConfig()); err != nil {
		t.Fatalf("Provision: %v", err)
	}

	wantResourceTypes := []types.ResourceType{
		types.ResourceTypeVpc,
		types.ResourceTypeInternetGateway,
		types.ResourceTypeSubnet,
		types.ResourceTypeRouteTable,
		types.ResourceTypeSecurityGroup,
		types.ResourceTypeInstance,
	}

	for _, rt := range wantResourceTypes {
		found := false
		for _, call := range c.calls {
			for _, ts := range call.TagSpec {
				if ts.ResourceType != rt {
					continue
				}
				keyVals := map[string]string{}
				for _, t := range ts.Tags {
					keyVals[aws.ToString(t.Key)] = aws.ToString(t.Value)
				}
				if keyVals["SELinuxE2E"] != "true" {
					t.Errorf("%s: missing/wrong SELinuxE2E tag (got %q)", rt, keyVals["SELinuxE2E"])
				}
				if keyVals["RunID"] != "run-42" {
					t.Errorf("%s: missing/wrong RunID tag (got %q)", rt, keyVals["RunID"])
				}
				found = true
			}
		}
		if !found {
			t.Errorf("no call tagged a %s resource — provision must tag every created resource", rt)
		}
	}
}

func TestProvision_InstanceRoleTags(t *testing.T) {
	c := &fakeEC2{}
	s := &fakeSSM{online: 3}
	w := &fakeWaiter{}

	if _, err := Provision(context.Background(), newTestLogger(), c, s, w, baseProvisionConfig()); err != nil {
		t.Fatalf("Provision: %v", err)
	}

	rolesSeen := map[string]bool{}
	for _, call := range c.calls {
		if call.Method != "RunInstances" {
			continue
		}
		for _, ts := range call.TagSpec {
			if ts.ResourceType != types.ResourceTypeInstance {
				continue
			}
			for _, tag := range ts.Tags {
				if aws.ToString(tag.Key) == "Role" {
					rolesSeen[aws.ToString(tag.Value)] = true
				}
			}
		}
	}
	for _, want := range []string{"primary", "worker1", "worker2"} {
		if !rolesSeen[want] {
			t.Errorf("no RunInstances call tagged Role=%s — workflow consumers depend on this for cleanup", want)
		}
	}
}

func TestProvision_AMIFilters(t *testing.T) {
	// The DescribeImages filter set must include architecture and
	// virtualization-type ONLY when the caller sets them. Defaults to
	// x86_64+hvm in action.yml to match the original Bash; binary
	// defaults to empty to allow arm64 lookups via the -ami-architecture
	// flag.
	tests := []struct {
		name              string
		architecture      string
		virtualizationType string
		wantArch          string // empty = filter must be absent
		wantVirt          string
	}{
		{name: "both set (x86_64 + hvm — Bash safety net)", architecture: "x86_64", virtualizationType: "hvm", wantArch: "x86_64", wantVirt: "hvm"},
		{name: "both empty (binary default — allows any)", architecture: "", virtualizationType: "", wantArch: "", wantVirt: ""},
		{name: "architecture-only (arm64 lookup)", architecture: "arm64", virtualizationType: "", wantArch: "arm64", wantVirt: ""},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			c := &fakeEC2{}
			cfg := baseProvisionConfig()
			cfg.AMIArchitecture = tt.architecture
			cfg.AMIVirtualizationType = tt.virtualizationType

			if _, err := Provision(context.Background(), newTestLogger(), c, &fakeSSM{}, &fakeWaiter{}, cfg); err != nil {
				t.Fatalf("Provision: %v", err)
			}

			var got *ec2.DescribeImagesInput
			for _, call := range c.calls {
				if call.Method == "DescribeImages" {
					got = call.Input.(*ec2.DescribeImagesInput)
					break
				}
			}
			if got == nil {
				t.Fatal("no DescribeImages call recorded")
			}
			gotArch, gotVirt := "", ""
			for _, f := range got.Filters {
				switch aws.ToString(f.Name) {
				case "architecture":
					if len(f.Values) == 1 {
						gotArch = f.Values[0]
					}
				case "virtualization-type":
					if len(f.Values) == 1 {
						gotVirt = f.Values[0]
					}
				}
			}
			if gotArch != tt.wantArch {
				t.Errorf("architecture filter = %q, want %q", gotArch, tt.wantArch)
			}
			if gotVirt != tt.wantVirt {
				t.Errorf("virtualization-type filter = %q, want %q", gotVirt, tt.wantVirt)
			}
		})
	}
}

func TestProvision_AMILookupPicksNewestByCreationDate(t *testing.T) {
	c := &fakeEC2{}
	s := &fakeSSM{online: 0}
	w := &fakeWaiter{}
	cfg := baseProvisionConfig()

	ids, err := Provision(context.Background(), newTestLogger(), c, s, w, cfg)
	if err != nil {
		t.Fatalf("Provision: %v", err)
	}
	// fakeEC2.DescribeImages returns three images with mixed dates;
	// resolveAMI should pick "ami-newest" (2026-01-01).
	if ids.AMIID != "ami-newest" {
		t.Errorf("AMIID = %q, want ami-newest", ids.AMIID)
	}
}

func TestProvision_FailureAtEachStage(t *testing.T) {
	// Five representative failure points that prove the load-bearing
	// "return whatever IDs you collected, so cleanup can tear them down"
	// contract holds across the whole provision flow. Earlier runs of
	// this test had a row per AWS call (13 total); these 5 cover early /
	// post-VPC / mid-build / AMI-lookup / late-stage without the
	// repetition.
	tests := []struct {
		name           string
		failOn         string
		errSubstring   string
		expectVPCID    bool
		expectIGWID    bool
		expectSubnetID bool
		expectRTID     bool
		expectSGID     bool
		expectAMIID    bool
	}{
		{
			name:         "CreateVpc fails (very-early — nothing collected)",
			failOn:       "CreateVpc",
			errSubstring: "create vpc",
		},
		{
			name:         "AttachInternetGateway fails (post-VPC, post-IGW)",
			failOn:       "AttachInternetGateway",
			errSubstring: "attach",
			expectVPCID:  true,
			expectIGWID:  true,
		},
		{
			name:           "CreateSecurityGroup fails (mid-build)",
			failOn:         "CreateSecurityGroup",
			errSubstring:   "security group",
			expectVPCID:    true,
			expectIGWID:    true,
			expectSubnetID: true,
			expectRTID:     true,
		},
		{
			name:           "DescribeImages fails (AMI lookup — all infra collected, no AMI)",
			failOn:         "DescribeImages",
			errSubstring:   "describe images",
			expectVPCID:    true,
			expectIGWID:    true,
			expectSubnetID: true,
			expectRTID:     true,
			expectSGID:     true,
		},
		{
			name:           "RunInstances fails (late — everything collected except instance IDs)",
			failOn:         "RunInstances",
			errSubstring:   "run instances",
			expectVPCID:    true,
			expectIGWID:    true,
			expectSubnetID: true,
			expectRTID:     true,
			expectSGID:     true,
			expectAMIID:    true,
		},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			c := &fakeEC2{failOn: map[string]error{tt.failOn: errStaged}}
			s := &fakeSSM{online: 0}
			w := &fakeWaiter{}

			ids, err := Provision(context.Background(), newTestLogger(), c, s, w, baseProvisionConfig())
			if err == nil {
				t.Fatalf("expected error from staged %s failure", tt.failOn)
			}
			if !strings.Contains(strings.ToLower(err.Error()), tt.errSubstring) {
				t.Errorf("error %q does not mention %q (lower-cased) — debugging this failure in CI will be harder", err.Error(), tt.errSubstring)
			}
			// The "return whatever you collected so far" contract: cleanup
			// can only tear down what's reflected in ResourceIDs.
			gotIDs := map[string]bool{
				"VPCID":           ids.VPCID != "",
				"IGWID":           ids.IGWID != "",
				"SubnetID":        ids.SubnetID != "",
				"RouteTableID":    ids.RouteTableID != "",
				"SecurityGroupID": ids.SecurityGroupID != "",
				"AMIID":           ids.AMIID != "",
			}
			wantIDs := map[string]bool{
				"VPCID":           tt.expectVPCID,
				"IGWID":           tt.expectIGWID,
				"SubnetID":        tt.expectSubnetID,
				"RouteTableID":    tt.expectRTID,
				"SecurityGroupID": tt.expectSGID,
				"AMIID":           tt.expectAMIID,
			}
			for k, want := range wantIDs {
				if gotIDs[k] != want {
					t.Errorf("%s populated=%v, want %v", k, gotIDs[k], want)
				}
			}
		})
	}
}

func TestProvision_SSMWaitSucceedsWhenAllOnline(t *testing.T) {
	c := &fakeEC2{}
	s := &fakeSSM{online: 3}
	w := &fakeWaiter{}
	cfg := baseProvisionConfig()
	cfg.SkipSSMWait = false
	cfg.SSMWaitTimeout = time.Second
	cfg.SSMWaitInterval = 10 * time.Millisecond

	if _, err := Provision(context.Background(), newTestLogger(), c, s, w, cfg); err != nil {
		t.Fatalf("Provision: %v", err)
	}
	if s.calls < 1 {
		t.Errorf("expected at least one SSM call, got %d", s.calls)
	}
}

func TestProvision_SSMWaitTimeout(t *testing.T) {
	c := &fakeEC2{}
	s := &fakeSSM{online: 1} // only 1 of 3 online — never satisfies
	w := &fakeWaiter{}
	cfg := baseProvisionConfig()
	cfg.SkipSSMWait = false
	cfg.SSMWaitTimeout = 50 * time.Millisecond
	cfg.SSMWaitInterval = 10 * time.Millisecond

	_, err := Provision(context.Background(), newTestLogger(), c, s, w, cfg)
	if err == nil {
		t.Fatal("expected timeout error")
	}
	if !strings.Contains(err.Error(), "timed out") {
		t.Errorf("expected timeout error, got: %v", err)
	}
}

func TestProvision_IngressRuleEncoding(t *testing.T) {
	// Sanity-check that the SDK call shapes match what the existing Bash
	// produced — protocol, port range, and CIDR must round-trip exactly.
	c := &fakeEC2{}
	s := &fakeSSM{online: 0}
	w := &fakeWaiter{}
	cfg := baseProvisionConfig()
	cfg.SkipSSMWait = true
	cfg.IngressRules = []IngressRule{
		{Protocol: "-1", FromPort: -1, ToPort: -1, CIDR: "10.0.0.0/16"},
		{Protocol: "tcp", FromPort: 30000, ToPort: 32767, CIDR: "0.0.0.0/0"},
		{Protocol: "icmp", FromPort: -1, ToPort: -1, CIDR: "10.0.0.0/16"},
	}

	if _, err := Provision(context.Background(), newTestLogger(), c, s, w, cfg); err != nil {
		t.Fatalf("Provision: %v", err)
	}

	type encoded struct {
		Protocol string
		From     int32
		To       int32
		CIDR     string
	}
	var got []encoded
	for _, call := range c.calls {
		if call.Method != "AuthorizeSecurityGroupIngress" {
			continue
		}
		in := call.Input.(*ec2.AuthorizeSecurityGroupIngressInput)
		for _, p := range in.IpPermissions {
			cidr := ""
			if len(p.IpRanges) > 0 {
				cidr = aws.ToString(p.IpRanges[0].CidrIp)
			}
			got = append(got, encoded{
				Protocol: aws.ToString(p.IpProtocol),
				From:     aws.ToInt32(p.FromPort),
				To:       aws.ToInt32(p.ToPort),
				CIDR:     cidr,
			})
		}
	}
	want := []encoded{
		{Protocol: "-1", From: -1, To: -1, CIDR: "10.0.0.0/16"},
		{Protocol: "tcp", From: 30000, To: 32767, CIDR: "0.0.0.0/0"},
		{Protocol: "icmp", From: -1, To: -1, CIDR: "10.0.0.0/16"},
	}
	if len(got) != len(want) {
		t.Fatalf("got %d ingress calls, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("ingress[%d] = %+v, want %+v", i, got[i], want[i])
		}
	}
}
