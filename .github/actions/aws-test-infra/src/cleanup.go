package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

// CleanupConfig is the parsed flag set for `cleanup`.
type CleanupConfig struct {
	Region string
	RunID  string

	// Resource IDs from a successful provision. All optional — anything
	// missing falls through to the tag-based sweep.
	VPCID           string
	IGWID           string
	SubnetID        string
	RouteTableID    string
	RouteAssocID    string
	SecurityGroupID string
	InstanceIDs     []string

	SkipDirect  bool
	SkipSweep   bool
	StrictSweep bool
}

func runCleanup(ctx context.Context, logger *slog.Logger, name string, args []string) error {
	fs := flag.NewFlagSet(name, flag.ExitOnError)
	cfg := CleanupConfig{}
	var instanceIDsCSV string
	fs.StringVar(&cfg.Region, "region", "", "AWS region (required)")
	fs.StringVar(&cfg.RunID, "run-id", "", "RunID tag value to use for the fallback sweep (required)")
	fs.StringVar(&cfg.VPCID, "vpc-id", "", "VPC ID")
	fs.StringVar(&cfg.IGWID, "igw-id", "", "Internet gateway ID")
	fs.StringVar(&cfg.SubnetID, "subnet-id", "", "Subnet ID")
	fs.StringVar(&cfg.RouteTableID, "route-table-id", "", "Route table ID")
	fs.StringVar(&cfg.RouteAssocID, "route-assoc-id", "", "Route table association ID")
	fs.StringVar(&cfg.SecurityGroupID, "security-group-id", "", "Security group ID")
	fs.StringVar(&instanceIDsCSV, "instance-ids", "", "Comma-separated list of instance IDs")
	fs.BoolVar(&cfg.SkipDirect, "skip-direct", false, "Skip direct cleanup (only run the tag-based sweep)")
	fs.BoolVar(&cfg.SkipSweep, "skip-sweep", false, "Skip the tag-based sweep (only run direct cleanup with the supplied IDs)")
	fs.BoolVar(&cfg.StrictSweep, "strict-sweep", false, "Fail the cleanup step on sweep errors. Default: log and continue (matches the original Bash teardown's set +e behavior).")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parse cleanup flags: %w", err)
	}
	if err := finalizeCleanupConfig(&cfg, instanceIDsCSV); err != nil {
		return err
	}

	awsCfg, err := loadAWSConfig(ctx, cfg.Region)
	if err != nil {
		return fmt.Errorf("load aws config: %w", err)
	}
	c := ec2.NewFromConfig(awsCfg)
	waiter := &ec2WaiterAdapter{client: c}

	return Cleanup(ctx, logger, c, waiter, cfg)
}

// finalizeCleanupConfig validates required fields and parses raw form
// values into cfg's derived fields. Pure function — no AWS, no I/O.
func finalizeCleanupConfig(cfg *CleanupConfig, instanceIDsCSV string) error {
	if cfg.Region == "" {
		return errors.New("-region is required")
	}
	if cfg.RunID == "" && !cfg.SkipSweep {
		return errors.New("-run-id is required (or pass -skip-sweep to disable the sweep)")
	}
	cfg.InstanceIDs = splitCSV(instanceIDsCSV)
	return nil
}

// Cleanup is the testable core of the cleanup command. It mirrors the
// existing teardown Bash exactly: best-effort direct deletion in dependency
// order, then a tag-based sweep that catches anything the direct path
// missed (typically resources from a run that failed before exporting IDs).
//
// All errors are logged but never abort the cleanup — the goal is "leave
// nothing behind on a torn-down run".
func Cleanup(
	ctx context.Context,
	logger *slog.Logger,
	c EC2API,
	waiter EC2Waiter,
	cfg CleanupConfig,
) error {
	if !cfg.SkipDirect {
		directCleanup(ctx, logger, c, waiter, cfg)
	}
	if !cfg.SkipSweep {
		if err := sweepByTag(ctx, logger, c, waiter, cfg.RunID); err != nil {
			// The original Bash teardown ran under `set +e`, so every
			// failure was silently absorbed and the step exited zero.
			// We mirror that by default — workflows use `if: always()`
			// for cleanup precisely so cleanup never fails the run, and
			// returning sweep errors here would break that contract.
			// Set `-strict-sweep` to opt back into hard failure.
			if cfg.StrictSweep {
				return err
			}
			logger.Error("sweep encountered errors; continuing because -strict-sweep is off", "err", err)
		}
	}
	return nil
}

func directCleanup(
	ctx context.Context,
	logger *slog.Logger,
	c EC2API,
	waiter EC2Waiter,
	cfg CleanupConfig,
) {
	if len(cfg.InstanceIDs) > 0 {
		logger.Info("terminating instances", "ids", cfg.InstanceIDs)
		if _, err := c.TerminateInstances(ctx, &ec2.TerminateInstancesInput{
			InstanceIds: cfg.InstanceIDs,
		}); err != nil {
			logger.Warn("terminate-instances failed", "err", err)
		} else if err := waiter.WaitInstanceTerminated(ctx, cfg.InstanceIDs); err != nil {
			logger.Warn("wait instance-terminated failed", "err", err)
		}
	}
	if cfg.SecurityGroupID != "" {
		logger.Info("deleting security group", "id", cfg.SecurityGroupID)
		if _, err := c.DeleteSecurityGroup(ctx, &ec2.DeleteSecurityGroupInput{
			GroupId: aws.String(cfg.SecurityGroupID),
		}); err != nil {
			logger.Warn("delete-security-group failed", "err", err)
		}
	}
	if cfg.RouteAssocID != "" {
		if _, err := c.DisassociateRouteTable(ctx, &ec2.DisassociateRouteTableInput{
			AssociationId: aws.String(cfg.RouteAssocID),
		}); err != nil {
			logger.Warn("disassociate-route-table failed", "err", err)
		}
	}
	if cfg.RouteTableID != "" {
		if _, err := c.DeleteRouteTable(ctx, &ec2.DeleteRouteTableInput{
			RouteTableId: aws.String(cfg.RouteTableID),
		}); err != nil {
			logger.Warn("delete-route-table failed", "err", err)
		}
	}
	if cfg.SubnetID != "" {
		if _, err := c.DeleteSubnet(ctx, &ec2.DeleteSubnetInput{
			SubnetId: aws.String(cfg.SubnetID),
		}); err != nil {
			logger.Warn("delete-subnet failed", "err", err)
		}
	}
	if cfg.IGWID != "" {
		if cfg.VPCID != "" {
			if _, err := c.DetachInternetGateway(ctx, &ec2.DetachInternetGatewayInput{
				InternetGatewayId: aws.String(cfg.IGWID),
				VpcId:             aws.String(cfg.VPCID),
			}); err != nil {
				logger.Warn("detach-internet-gateway failed", "err", err)
			}
		}
		if _, err := c.DeleteInternetGateway(ctx, &ec2.DeleteInternetGatewayInput{
			InternetGatewayId: aws.String(cfg.IGWID),
		}); err != nil {
			logger.Warn("delete-internet-gateway failed", "err", err)
		}
	}
	if cfg.VPCID != "" {
		if _, err := c.DeleteVpc(ctx, &ec2.DeleteVpcInput{
			VpcId: aws.String(cfg.VPCID),
		}); err != nil {
			logger.Warn("delete-vpc failed", "err", err)
		}
	}
}

// sweepByTag finds and deletes every resource that matches Name=tag:RunID
// Values=<runID>. The order — instances → SGs → route tables → subnets →
// IGWs → VPCs — matches the dependency chain so deletes don't fail because
// of in-use checks.
func sweepByTag(ctx context.Context, logger *slog.Logger, c EC2API, waiter EC2Waiter, runID string) error {
	logger.Info("running tag-based sweep", "run_id", runID)
	tagFilter := []types.Filter{{Name: aws.String("tag:RunID"), Values: []string{runID}}}

	// Instances
	instOut, err := c.DescribeInstances(ctx, &ec2.DescribeInstancesInput{
		Filters: append(append([]types.Filter{}, tagFilter...),
			types.Filter{Name: aws.String("instance-state-name"),
				Values: []string{"pending", "running", "stopping", "stopped"}}),
	})
	if err != nil {
		return fmt.Errorf("describe-instances (sweep): %w", err)
	}
	var sweepInstances []string
	for _, r := range instOut.Reservations {
		for _, i := range r.Instances {
			if id := aws.ToString(i.InstanceId); id != "" {
				sweepInstances = append(sweepInstances, id)
			}
		}
	}
	if len(sweepInstances) > 0 {
		logger.Info("sweep: terminating instances", "count", len(sweepInstances), "ids", strings.Join(sweepInstances, ","))
		if _, err := c.TerminateInstances(ctx, &ec2.TerminateInstancesInput{InstanceIds: sweepInstances}); err != nil {
			logger.Warn("sweep: terminate-instances failed", "err", err)
		}
		if err := waiter.WaitInstanceTerminated(ctx, sweepInstances); err != nil {
			logger.Warn("sweep: wait-instance-terminated failed", "err", err)
		}
	}

	// Security groups
	sgOut, err := c.DescribeSecurityGroups(ctx, &ec2.DescribeSecurityGroupsInput{Filters: tagFilter})
	if err != nil {
		return fmt.Errorf("describe-security-groups (sweep): %w", err)
	}
	for _, sg := range sgOut.SecurityGroups {
		id := aws.ToString(sg.GroupId)
		if id == "" {
			continue
		}
		if _, err := c.DeleteSecurityGroup(ctx, &ec2.DeleteSecurityGroupInput{GroupId: aws.String(id)}); err != nil {
			logger.Warn("sweep: delete-security-group failed", "id", id, "err", err)
		}
	}

	// Route tables — disassociate every association first, then delete.
	rtOut, err := c.DescribeRouteTables(ctx, &ec2.DescribeRouteTablesInput{Filters: tagFilter})
	if err != nil {
		return fmt.Errorf("describe-route-tables (sweep): %w", err)
	}
	for _, rt := range rtOut.RouteTables {
		id := aws.ToString(rt.RouteTableId)
		if id == "" {
			continue
		}
		for _, a := range rt.Associations {
			aid := aws.ToString(a.RouteTableAssociationId)
			if aid == "" {
				continue
			}
			if _, err := c.DisassociateRouteTable(ctx, &ec2.DisassociateRouteTableInput{
				AssociationId: aws.String(aid),
			}); err != nil {
				logger.Warn("sweep: disassociate-route-table failed", "id", aid, "err", err)
			}
		}
		if _, err := c.DeleteRouteTable(ctx, &ec2.DeleteRouteTableInput{RouteTableId: aws.String(id)}); err != nil {
			logger.Warn("sweep: delete-route-table failed", "id", id, "err", err)
		}
	}

	// Subnets
	subOut, err := c.DescribeSubnets(ctx, &ec2.DescribeSubnetsInput{Filters: tagFilter})
	if err != nil {
		return fmt.Errorf("describe-subnets (sweep): %w", err)
	}
	for _, sn := range subOut.Subnets {
		id := aws.ToString(sn.SubnetId)
		if id == "" {
			continue
		}
		if _, err := c.DeleteSubnet(ctx, &ec2.DeleteSubnetInput{SubnetId: aws.String(id)}); err != nil {
			logger.Warn("sweep: delete-subnet failed", "id", id, "err", err)
		}
	}

	// Internet gateways — detach from every attached VPC, then delete.
	igwOut, err := c.DescribeInternetGateways(ctx, &ec2.DescribeInternetGatewaysInput{Filters: tagFilter})
	if err != nil {
		return fmt.Errorf("describe-internet-gateways (sweep): %w", err)
	}
	for _, igw := range igwOut.InternetGateways {
		id := aws.ToString(igw.InternetGatewayId)
		if id == "" {
			continue
		}
		for _, att := range igw.Attachments {
			vid := aws.ToString(att.VpcId)
			if vid == "" {
				continue
			}
			if _, err := c.DetachInternetGateway(ctx, &ec2.DetachInternetGatewayInput{
				InternetGatewayId: aws.String(id),
				VpcId:             aws.String(vid),
			}); err != nil {
				logger.Warn("sweep: detach-internet-gateway failed", "igw", id, "vpc", vid, "err", err)
			}
		}
		if _, err := c.DeleteInternetGateway(ctx, &ec2.DeleteInternetGatewayInput{InternetGatewayId: aws.String(id)}); err != nil {
			logger.Warn("sweep: delete-internet-gateway failed", "id", id, "err", err)
		}
	}

	// VPCs
	vpcOut, err := c.DescribeVpcs(ctx, &ec2.DescribeVpcsInput{Filters: tagFilter})
	if err != nil {
		return fmt.Errorf("describe-vpcs (sweep): %w", err)
	}
	for _, v := range vpcOut.Vpcs {
		id := aws.ToString(v.VpcId)
		if id == "" {
			continue
		}
		if _, err := c.DeleteVpc(ctx, &ec2.DeleteVpcInput{VpcId: aws.String(id)}); err != nil {
			logger.Warn("sweep: delete-vpc failed", "id", id, "err", err)
		}
	}

	return nil
}
