package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	ssmtypes "github.com/aws/aws-sdk-go-v2/service/ssm/types"
)

// fakeEC2 is a hand-rolled mock satisfying EC2API. Every method records
// itself in calls (so tests can assert ordering) and returns happy-path
// canned responses unless an error is staged via failOn.
type fakeEC2 struct {
	mu    sync.Mutex
	calls []apiCall

	failOn map[string]error // method name → error to return

	// When sweepResources is set, the Describe* methods used by the sweep
	// return resources tagged with the matching RunID. Used by cleanup
	// tests to feed orphaned resources into the sweep path.
	sweepResources sweepFixture
}

type apiCall struct {
	Method  string
	Input   interface{}
	TagSpec []types.TagSpecification
}

type sweepFixture struct {
	Instances []string
	SGs       []string
	RouteTables []routeTableFixture
	Subnets   []string
	IGWs      []igwFixture
	VPCs      []string
}

type routeTableFixture struct {
	ID            string
	AssociationIDs []string
}

type igwFixture struct {
	ID    string
	VPCs  []string
}

func (f *fakeEC2) record(method string, input interface{}, ts []types.TagSpecification) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, apiCall{Method: method, Input: input, TagSpec: ts})
}

func (f *fakeEC2) shouldFail(method string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.failOn == nil {
		return nil
	}
	return f.failOn[method]
}

// methods executed in order ─────────────────────────────────────────────

func (f *fakeEC2) CreateVpc(_ context.Context, in *ec2.CreateVpcInput, _ ...func(*ec2.Options)) (*ec2.CreateVpcOutput, error) {
	f.record("CreateVpc", in, in.TagSpecifications)
	if err := f.shouldFail("CreateVpc"); err != nil {
		return nil, err
	}
	return &ec2.CreateVpcOutput{Vpc: &types.Vpc{VpcId: aws.String("vpc-mock")}}, nil
}
func (f *fakeEC2) ModifyVpcAttribute(_ context.Context, in *ec2.ModifyVpcAttributeInput, _ ...func(*ec2.Options)) (*ec2.ModifyVpcAttributeOutput, error) {
	f.record("ModifyVpcAttribute", in, nil)
	return &ec2.ModifyVpcAttributeOutput{}, f.shouldFail("ModifyVpcAttribute")
}
func (f *fakeEC2) DeleteVpc(_ context.Context, in *ec2.DeleteVpcInput, _ ...func(*ec2.Options)) (*ec2.DeleteVpcOutput, error) {
	f.record("DeleteVpc", in, nil)
	return &ec2.DeleteVpcOutput{}, f.shouldFail("DeleteVpc")
}
func (f *fakeEC2) DescribeVpcs(_ context.Context, in *ec2.DescribeVpcsInput, _ ...func(*ec2.Options)) (*ec2.DescribeVpcsOutput, error) {
	f.record("DescribeVpcs", in, nil)
	if err := f.shouldFail("DescribeVpcs"); err != nil {
		return nil, err
	}
	out := &ec2.DescribeVpcsOutput{}
	for _, id := range f.sweepResources.VPCs {
		id := id
		out.Vpcs = append(out.Vpcs, types.Vpc{VpcId: aws.String(id)})
	}
	return out, nil
}

func (f *fakeEC2) CreateInternetGateway(_ context.Context, in *ec2.CreateInternetGatewayInput, _ ...func(*ec2.Options)) (*ec2.CreateInternetGatewayOutput, error) {
	f.record("CreateInternetGateway", in, in.TagSpecifications)
	return &ec2.CreateInternetGatewayOutput{InternetGateway: &types.InternetGateway{InternetGatewayId: aws.String("igw-mock")}}, f.shouldFail("CreateInternetGateway")
}
func (f *fakeEC2) AttachInternetGateway(_ context.Context, in *ec2.AttachInternetGatewayInput, _ ...func(*ec2.Options)) (*ec2.AttachInternetGatewayOutput, error) {
	f.record("AttachInternetGateway", in, nil)
	return &ec2.AttachInternetGatewayOutput{}, f.shouldFail("AttachInternetGateway")
}
func (f *fakeEC2) DetachInternetGateway(_ context.Context, in *ec2.DetachInternetGatewayInput, _ ...func(*ec2.Options)) (*ec2.DetachInternetGatewayOutput, error) {
	f.record("DetachInternetGateway", in, nil)
	return &ec2.DetachInternetGatewayOutput{}, f.shouldFail("DetachInternetGateway")
}
func (f *fakeEC2) DeleteInternetGateway(_ context.Context, in *ec2.DeleteInternetGatewayInput, _ ...func(*ec2.Options)) (*ec2.DeleteInternetGatewayOutput, error) {
	f.record("DeleteInternetGateway", in, nil)
	return &ec2.DeleteInternetGatewayOutput{}, f.shouldFail("DeleteInternetGateway")
}
func (f *fakeEC2) DescribeInternetGateways(_ context.Context, in *ec2.DescribeInternetGatewaysInput, _ ...func(*ec2.Options)) (*ec2.DescribeInternetGatewaysOutput, error) {
	f.record("DescribeInternetGateways", in, nil)
	if err := f.shouldFail("DescribeInternetGateways"); err != nil {
		return nil, err
	}
	out := &ec2.DescribeInternetGatewaysOutput{}
	for _, ig := range f.sweepResources.IGWs {
		ig := ig
		atts := make([]types.InternetGatewayAttachment, 0, len(ig.VPCs))
		for _, v := range ig.VPCs {
			v := v
			atts = append(atts, types.InternetGatewayAttachment{VpcId: aws.String(v)})
		}
		out.InternetGateways = append(out.InternetGateways, types.InternetGateway{
			InternetGatewayId: aws.String(ig.ID),
			Attachments:       atts,
		})
	}
	return out, nil
}

func (f *fakeEC2) DescribeAvailabilityZones(_ context.Context, in *ec2.DescribeAvailabilityZonesInput, _ ...func(*ec2.Options)) (*ec2.DescribeAvailabilityZonesOutput, error) {
	f.record("DescribeAvailabilityZones", in, nil)
	return &ec2.DescribeAvailabilityZonesOutput{
		AvailabilityZones: []types.AvailabilityZone{{ZoneName: aws.String("us-west-2a")}},
	}, nil
}
func (f *fakeEC2) CreateSubnet(_ context.Context, in *ec2.CreateSubnetInput, _ ...func(*ec2.Options)) (*ec2.CreateSubnetOutput, error) {
	f.record("CreateSubnet", in, in.TagSpecifications)
	return &ec2.CreateSubnetOutput{Subnet: &types.Subnet{SubnetId: aws.String("subnet-mock")}}, f.shouldFail("CreateSubnet")
}
func (f *fakeEC2) ModifySubnetAttribute(_ context.Context, in *ec2.ModifySubnetAttributeInput, _ ...func(*ec2.Options)) (*ec2.ModifySubnetAttributeOutput, error) {
	f.record("ModifySubnetAttribute", in, nil)
	return &ec2.ModifySubnetAttributeOutput{}, f.shouldFail("ModifySubnetAttribute")
}
func (f *fakeEC2) DeleteSubnet(_ context.Context, in *ec2.DeleteSubnetInput, _ ...func(*ec2.Options)) (*ec2.DeleteSubnetOutput, error) {
	f.record("DeleteSubnet", in, nil)
	return &ec2.DeleteSubnetOutput{}, f.shouldFail("DeleteSubnet")
}
func (f *fakeEC2) DescribeSubnets(_ context.Context, in *ec2.DescribeSubnetsInput, _ ...func(*ec2.Options)) (*ec2.DescribeSubnetsOutput, error) {
	f.record("DescribeSubnets", in, nil)
	if err := f.shouldFail("DescribeSubnets"); err != nil {
		return nil, err
	}
	out := &ec2.DescribeSubnetsOutput{}
	for _, id := range f.sweepResources.Subnets {
		id := id
		out.Subnets = append(out.Subnets, types.Subnet{SubnetId: aws.String(id)})
	}
	return out, nil
}

func (f *fakeEC2) CreateRouteTable(_ context.Context, in *ec2.CreateRouteTableInput, _ ...func(*ec2.Options)) (*ec2.CreateRouteTableOutput, error) {
	f.record("CreateRouteTable", in, in.TagSpecifications)
	return &ec2.CreateRouteTableOutput{RouteTable: &types.RouteTable{RouteTableId: aws.String("rtb-mock")}}, f.shouldFail("CreateRouteTable")
}
func (f *fakeEC2) CreateRoute(_ context.Context, in *ec2.CreateRouteInput, _ ...func(*ec2.Options)) (*ec2.CreateRouteOutput, error) {
	f.record("CreateRoute", in, nil)
	return &ec2.CreateRouteOutput{Return: aws.Bool(true)}, f.shouldFail("CreateRoute")
}
func (f *fakeEC2) AssociateRouteTable(_ context.Context, in *ec2.AssociateRouteTableInput, _ ...func(*ec2.Options)) (*ec2.AssociateRouteTableOutput, error) {
	f.record("AssociateRouteTable", in, nil)
	return &ec2.AssociateRouteTableOutput{AssociationId: aws.String("rtbassoc-mock")}, f.shouldFail("AssociateRouteTable")
}
func (f *fakeEC2) DisassociateRouteTable(_ context.Context, in *ec2.DisassociateRouteTableInput, _ ...func(*ec2.Options)) (*ec2.DisassociateRouteTableOutput, error) {
	f.record("DisassociateRouteTable", in, nil)
	return &ec2.DisassociateRouteTableOutput{}, f.shouldFail("DisassociateRouteTable")
}
func (f *fakeEC2) DeleteRouteTable(_ context.Context, in *ec2.DeleteRouteTableInput, _ ...func(*ec2.Options)) (*ec2.DeleteRouteTableOutput, error) {
	f.record("DeleteRouteTable", in, nil)
	return &ec2.DeleteRouteTableOutput{}, f.shouldFail("DeleteRouteTable")
}
func (f *fakeEC2) DescribeRouteTables(_ context.Context, in *ec2.DescribeRouteTablesInput, _ ...func(*ec2.Options)) (*ec2.DescribeRouteTablesOutput, error) {
	f.record("DescribeRouteTables", in, nil)
	if err := f.shouldFail("DescribeRouteTables"); err != nil {
		return nil, err
	}
	out := &ec2.DescribeRouteTablesOutput{}
	for _, rt := range f.sweepResources.RouteTables {
		rt := rt
		assocs := make([]types.RouteTableAssociation, 0, len(rt.AssociationIDs))
		for _, aid := range rt.AssociationIDs {
			aid := aid
			assocs = append(assocs, types.RouteTableAssociation{RouteTableAssociationId: aws.String(aid)})
		}
		out.RouteTables = append(out.RouteTables, types.RouteTable{
			RouteTableId: aws.String(rt.ID),
			Associations: assocs,
		})
	}
	return out, nil
}

func (f *fakeEC2) CreateSecurityGroup(_ context.Context, in *ec2.CreateSecurityGroupInput, _ ...func(*ec2.Options)) (*ec2.CreateSecurityGroupOutput, error) {
	f.record("CreateSecurityGroup", in, in.TagSpecifications)
	return &ec2.CreateSecurityGroupOutput{GroupId: aws.String("sg-mock")}, f.shouldFail("CreateSecurityGroup")
}
func (f *fakeEC2) AuthorizeSecurityGroupIngress(_ context.Context, in *ec2.AuthorizeSecurityGroupIngressInput, _ ...func(*ec2.Options)) (*ec2.AuthorizeSecurityGroupIngressOutput, error) {
	f.record("AuthorizeSecurityGroupIngress", in, nil)
	return &ec2.AuthorizeSecurityGroupIngressOutput{}, f.shouldFail("AuthorizeSecurityGroupIngress")
}
func (f *fakeEC2) DeleteSecurityGroup(_ context.Context, in *ec2.DeleteSecurityGroupInput, _ ...func(*ec2.Options)) (*ec2.DeleteSecurityGroupOutput, error) {
	f.record("DeleteSecurityGroup", in, nil)
	return &ec2.DeleteSecurityGroupOutput{}, f.shouldFail("DeleteSecurityGroup")
}
func (f *fakeEC2) DescribeSecurityGroups(_ context.Context, in *ec2.DescribeSecurityGroupsInput, _ ...func(*ec2.Options)) (*ec2.DescribeSecurityGroupsOutput, error) {
	f.record("DescribeSecurityGroups", in, nil)
	if err := f.shouldFail("DescribeSecurityGroups"); err != nil {
		return nil, err
	}
	out := &ec2.DescribeSecurityGroupsOutput{}
	for _, id := range f.sweepResources.SGs {
		id := id
		out.SecurityGroups = append(out.SecurityGroups, types.SecurityGroup{GroupId: aws.String(id)})
	}
	return out, nil
}

func (f *fakeEC2) DescribeImages(_ context.Context, in *ec2.DescribeImagesInput, _ ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error) {
	f.record("DescribeImages", in, nil)
	if err := f.shouldFail("DescribeImages"); err != nil {
		return nil, err
	}
	return &ec2.DescribeImagesOutput{
		Images: []types.Image{
			{ImageId: aws.String("ami-old"), CreationDate: aws.String("2024-01-01T00:00:00.000Z")},
			{ImageId: aws.String("ami-newest"), CreationDate: aws.String("2026-01-01T00:00:00.000Z")},
			{ImageId: aws.String("ami-mid"), CreationDate: aws.String("2025-06-01T00:00:00.000Z")},
		},
	}, nil
}
func (f *fakeEC2) RunInstances(_ context.Context, in *ec2.RunInstancesInput, _ ...func(*ec2.Options)) (*ec2.RunInstancesOutput, error) {
	f.record("RunInstances", in, in.TagSpecifications)
	if err := f.shouldFail("RunInstances"); err != nil {
		return nil, err
	}
	// Synthesize a unique instance ID from the role tag so tests can map
	// instance → role even though our fake is stateless.
	role := "unknown"
	for _, ts := range in.TagSpecifications {
		if ts.ResourceType != types.ResourceTypeInstance {
			continue
		}
		for _, t := range ts.Tags {
			if aws.ToString(t.Key) == "Role" {
				role = aws.ToString(t.Value)
			}
		}
	}
	return &ec2.RunInstancesOutput{
		Instances: []types.Instance{{InstanceId: aws.String("i-" + role)}},
	}, nil
}
func (f *fakeEC2) TerminateInstances(_ context.Context, in *ec2.TerminateInstancesInput, _ ...func(*ec2.Options)) (*ec2.TerminateInstancesOutput, error) {
	f.record("TerminateInstances", in, nil)
	return &ec2.TerminateInstancesOutput{}, f.shouldFail("TerminateInstances")
}
func (f *fakeEC2) DescribeInstances(_ context.Context, in *ec2.DescribeInstancesInput, _ ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error) {
	f.record("DescribeInstances", in, nil)
	if err := f.shouldFail("DescribeInstances"); err != nil {
		return nil, err
	}
	// If the test staged sweep instances, return them grouped under one
	// reservation. Otherwise return the input IDs with a stub public IP
	// (covers the "describe primary" call after RunInstances).
	out := &ec2.DescribeInstancesOutput{}
	if len(f.sweepResources.Instances) > 0 {
		// Only return sweep instances if filtered by tag — i.e. when the
		// caller passes Filters (not InstanceIds).
		if len(in.Filters) > 0 {
			res := types.Reservation{}
			for _, id := range f.sweepResources.Instances {
				id := id
				res.Instances = append(res.Instances, types.Instance{InstanceId: aws.String(id)})
			}
			out.Reservations = []types.Reservation{res}
			return out, nil
		}
	}
	res := types.Reservation{}
	for _, id := range in.InstanceIds {
		id := id
		res.Instances = append(res.Instances, types.Instance{
			InstanceId:      aws.String(id),
			PublicIpAddress: aws.String("203.0.113.1"),
		})
	}
	out.Reservations = []types.Reservation{res}
	return out, nil
}

// fakeSSM ─────────────────────────────────────────────────────────────────

type fakeSSM struct {
	mu       sync.Mutex
	calls    int
	online   int // how many to report online from the next call onward
}

func (s *fakeSSM) DescribeInstanceInformation(_ context.Context, _ *ssm.DescribeInstanceInformationInput, _ ...func(*ssm.Options)) (*ssm.DescribeInstanceInformationOutput, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	out := &ssm.DescribeInstanceInformationOutput{}
	for i := 0; i < s.online; i++ {
		out.InstanceInformationList = append(out.InstanceInformationList, ssmtypes.InstanceInformation{
			PingStatus: ssmtypes.PingStatusOnline,
		})
	}
	return out, nil
}

// fakeWaiter ─────────────────────────────────────────────────────────────

type fakeWaiter struct {
	runErr        error
	terminatedErr error
	runCalls      [][]string
	termCalls     [][]string
}

func (w *fakeWaiter) WaitInstanceRunning(_ context.Context, ids []string) error {
	w.runCalls = append(w.runCalls, append([]string(nil), ids...))
	return w.runErr
}

func (w *fakeWaiter) WaitInstanceTerminated(_ context.Context, ids []string) error {
	w.termCalls = append(w.termCalls, append([]string(nil), ids...))
	return w.terminatedErr
}

// helpers ────────────────────────────────────────────────────────────────

func methodSequence(calls []apiCall) []string {
	out := make([]string, 0, len(calls))
	for _, c := range calls {
		out = append(out, c.Method)
	}
	return out
}

// requireOrdering asserts that `expected` appears as a subsequence of
// methodSequence — i.e. each entry occurs after the prior in the recorded
// call list. Doesn't reject extra interleaved calls.
//
// Use this for the loose "these calls must happen, roughly in this order"
// shape. For dependency-critical pairs (terminate→wait, disassoc→delete-RT,
// detach→delete-IGW, instance-termination must precede any subnet/SG/VPC
// delete), use requireImmediatelyAfter instead — it catches insertion-of-
// wrong-call-between bugs that requireOrdering misses.
func requireOrdering(actual, expected []string) error {
	idx := 0
	for _, m := range actual {
		if idx < len(expected) && m == expected[idx] {
			idx++
		}
	}
	if idx == len(expected) {
		return nil
	}
	return fmt.Errorf("expected ordering %v not found in %v (got %d/%d)", expected, actual, idx, len(expected))
}

// requireImmediatelyAfter asserts that every occurrence of method `before`
// is immediately followed by method `after` in the recorded call list,
// with no other calls between them.
//
// Use for pairs where any intervening call would be a real bug:
//   - TerminateInstances → WaitInstanceTerminated (waiting after the call)
//   - DisassociateRouteTable → DeleteRouteTable (RT can't be deleted while associated)
//   - DetachInternetGateway → DeleteInternetGateway (IGW can't be deleted while attached)
func requireImmediatelyAfter(actual []string, before, after string) error {
	for i, m := range actual {
		if m != before {
			continue
		}
		if i+1 >= len(actual) {
			return fmt.Errorf("%s at index %d has no following call; expected %s", before, i, after)
		}
		if actual[i+1] != after {
			return fmt.Errorf("%s at index %d followed by %s, expected %s (full sequence: %v)", before, i, actual[i+1], after, actual)
		}
	}
	return nil
}

// requireBefore asserts that every occurrence of `early` happens before
// every occurrence of `late` in the recorded call list. Allows interleaved
// other calls — just enforces a partial order.
//
// Use for "X must finish before any Y starts" — e.g.
// WaitInstanceTerminated must precede every DeleteSecurityGroup /
// DeleteSubnet / DeleteVpc, or those deletes will fail with InUse errors
// in production.
//
// If `late` appears in the sequence but `early` never does, that's a
// failure: the dependency couldn't possibly have been satisfied. (The
// previous version silently passed in this case — a footgun in tests
// where the `early` step might be absent due to some other bug.)
func requireBefore(actual []string, early, late string) error {
	lastEarly := -1
	lateIndices := []int{}
	for i, m := range actual {
		if m == early {
			lastEarly = i
		}
		if m == late {
			lateIndices = append(lateIndices, i)
		}
	}
	if len(lateIndices) > 0 && lastEarly == -1 {
		return fmt.Errorf("%s appears in sequence at index %d but %s never does (full sequence: %v)", late, lateIndices[0], early, actual)
	}
	for _, i := range lateIndices {
		if i < lastEarly {
			return fmt.Errorf("%s at index %d happens before final %s at index %d (full sequence: %v)", late, i, early, lastEarly, actual)
		}
	}
	return nil
}

func tagPairs(ts []types.TagSpecification) string {
	parts := []string{}
	for _, t := range ts {
		for _, tag := range t.Tags {
			parts = append(parts, fmt.Sprintf("%s/%s=%s", t.ResourceType, aws.ToString(tag.Key), aws.ToString(tag.Value)))
		}
	}
	return strings.Join(parts, ", ")
}

var errStaged = errors.New("staged failure")
