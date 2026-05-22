package main

import (
	"context"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
)

// EC2API is the subset of the EC2 client we use. Defined as an interface so
// tests can supply a fake without spinning up LocalStack or running real AWS.
type EC2API interface {
	CreateVpc(ctx context.Context, params *ec2.CreateVpcInput, optFns ...func(*ec2.Options)) (*ec2.CreateVpcOutput, error)
	ModifyVpcAttribute(ctx context.Context, params *ec2.ModifyVpcAttributeInput, optFns ...func(*ec2.Options)) (*ec2.ModifyVpcAttributeOutput, error)
	DeleteVpc(ctx context.Context, params *ec2.DeleteVpcInput, optFns ...func(*ec2.Options)) (*ec2.DeleteVpcOutput, error)
	DescribeVpcs(ctx context.Context, params *ec2.DescribeVpcsInput, optFns ...func(*ec2.Options)) (*ec2.DescribeVpcsOutput, error)

	CreateInternetGateway(ctx context.Context, params *ec2.CreateInternetGatewayInput, optFns ...func(*ec2.Options)) (*ec2.CreateInternetGatewayOutput, error)
	AttachInternetGateway(ctx context.Context, params *ec2.AttachInternetGatewayInput, optFns ...func(*ec2.Options)) (*ec2.AttachInternetGatewayOutput, error)
	DetachInternetGateway(ctx context.Context, params *ec2.DetachInternetGatewayInput, optFns ...func(*ec2.Options)) (*ec2.DetachInternetGatewayOutput, error)
	DeleteInternetGateway(ctx context.Context, params *ec2.DeleteInternetGatewayInput, optFns ...func(*ec2.Options)) (*ec2.DeleteInternetGatewayOutput, error)
	DescribeInternetGateways(ctx context.Context, params *ec2.DescribeInternetGatewaysInput, optFns ...func(*ec2.Options)) (*ec2.DescribeInternetGatewaysOutput, error)

	DescribeAvailabilityZones(ctx context.Context, params *ec2.DescribeAvailabilityZonesInput, optFns ...func(*ec2.Options)) (*ec2.DescribeAvailabilityZonesOutput, error)
	CreateSubnet(ctx context.Context, params *ec2.CreateSubnetInput, optFns ...func(*ec2.Options)) (*ec2.CreateSubnetOutput, error)
	ModifySubnetAttribute(ctx context.Context, params *ec2.ModifySubnetAttributeInput, optFns ...func(*ec2.Options)) (*ec2.ModifySubnetAttributeOutput, error)
	DeleteSubnet(ctx context.Context, params *ec2.DeleteSubnetInput, optFns ...func(*ec2.Options)) (*ec2.DeleteSubnetOutput, error)
	DescribeSubnets(ctx context.Context, params *ec2.DescribeSubnetsInput, optFns ...func(*ec2.Options)) (*ec2.DescribeSubnetsOutput, error)

	CreateRouteTable(ctx context.Context, params *ec2.CreateRouteTableInput, optFns ...func(*ec2.Options)) (*ec2.CreateRouteTableOutput, error)
	CreateRoute(ctx context.Context, params *ec2.CreateRouteInput, optFns ...func(*ec2.Options)) (*ec2.CreateRouteOutput, error)
	AssociateRouteTable(ctx context.Context, params *ec2.AssociateRouteTableInput, optFns ...func(*ec2.Options)) (*ec2.AssociateRouteTableOutput, error)
	DisassociateRouteTable(ctx context.Context, params *ec2.DisassociateRouteTableInput, optFns ...func(*ec2.Options)) (*ec2.DisassociateRouteTableOutput, error)
	DeleteRouteTable(ctx context.Context, params *ec2.DeleteRouteTableInput, optFns ...func(*ec2.Options)) (*ec2.DeleteRouteTableOutput, error)
	DescribeRouteTables(ctx context.Context, params *ec2.DescribeRouteTablesInput, optFns ...func(*ec2.Options)) (*ec2.DescribeRouteTablesOutput, error)

	CreateSecurityGroup(ctx context.Context, params *ec2.CreateSecurityGroupInput, optFns ...func(*ec2.Options)) (*ec2.CreateSecurityGroupOutput, error)
	AuthorizeSecurityGroupIngress(ctx context.Context, params *ec2.AuthorizeSecurityGroupIngressInput, optFns ...func(*ec2.Options)) (*ec2.AuthorizeSecurityGroupIngressOutput, error)
	DeleteSecurityGroup(ctx context.Context, params *ec2.DeleteSecurityGroupInput, optFns ...func(*ec2.Options)) (*ec2.DeleteSecurityGroupOutput, error)
	DescribeSecurityGroups(ctx context.Context, params *ec2.DescribeSecurityGroupsInput, optFns ...func(*ec2.Options)) (*ec2.DescribeSecurityGroupsOutput, error)

	DescribeImages(ctx context.Context, params *ec2.DescribeImagesInput, optFns ...func(*ec2.Options)) (*ec2.DescribeImagesOutput, error)
	RunInstances(ctx context.Context, params *ec2.RunInstancesInput, optFns ...func(*ec2.Options)) (*ec2.RunInstancesOutput, error)
	TerminateInstances(ctx context.Context, params *ec2.TerminateInstancesInput, optFns ...func(*ec2.Options)) (*ec2.TerminateInstancesOutput, error)
	DescribeInstances(ctx context.Context, params *ec2.DescribeInstancesInput, optFns ...func(*ec2.Options)) (*ec2.DescribeInstancesOutput, error)
}

// SSMAPI is the subset of the SSM client we use.
type SSMAPI interface {
	DescribeInstanceInformation(ctx context.Context, params *ssm.DescribeInstanceInformationInput, optFns ...func(*ssm.Options)) (*ssm.DescribeInstanceInformationOutput, error)
}

// EC2Waiter is the subset of EC2 waiters we use, abstracted so tests can
// short-circuit them.
type EC2Waiter interface {
	WaitInstanceRunning(ctx context.Context, ids []string) error
	WaitInstanceTerminated(ctx context.Context, ids []string) error
}

// ec2WaiterAdapter adapts the SDK's typed waiters to our interface.
//
// The instance-running max-wait is configurable so workflows that hit
// slow-boot edge cases (rare AWS capacity issues, large image pulls in
// user-data) can extend it. The SDK's default for instance-running is 10
// minutes (40 attempts × 15s); we cap higher to give a meaningful safety
// margin while still failing rather than hanging indefinitely.
//
// Termination is unconditionally fast in practice, so terminated wait
// stays at the package default.
type ec2WaiterAdapter struct {
	client                 *ec2.Client
	instanceRunningTimeout time.Duration
}

// effectiveInstanceRunningTimeout resolves the configured timeout to a
// usable value, falling back to the package default when the field is
// unset or non-positive. Extracted so the wiring is unit-testable
// independently of the SDK waiter (which can't be cheaply mocked).
func (a *ec2WaiterAdapter) effectiveInstanceRunningTimeout() time.Duration {
	if a.instanceRunningTimeout <= 0 {
		return defaultWaiterMaxWait
	}
	return a.instanceRunningTimeout
}

func (a *ec2WaiterAdapter) WaitInstanceRunning(ctx context.Context, ids []string) error {
	w := ec2.NewInstanceRunningWaiter(a.client)
	return w.Wait(ctx, &ec2.DescribeInstancesInput{InstanceIds: ids}, a.effectiveInstanceRunningTimeout())
}

func (a *ec2WaiterAdapter) WaitInstanceTerminated(ctx context.Context, ids []string) error {
	w := ec2.NewInstanceTerminatedWaiter(a.client)
	return w.Wait(ctx, &ec2.DescribeInstancesInput{InstanceIds: ids}, defaultWaiterMaxWait)
}

// loadAWSConfig builds a default-chain aws.Config bound to the given region.
// Workflows that already used aws-actions/configure-aws-credentials will have
// AWS_* env vars set; this picks them up automatically.
func loadAWSConfig(ctx context.Context, region string) (aws.Config, error) {
	return config.LoadDefaultConfig(ctx, config.WithRegion(region))
}
