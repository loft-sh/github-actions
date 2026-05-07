package main

import (
	"context"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	ssmtypes "github.com/aws/aws-sdk-go-v2/service/ssm/types"
)

// defaultWaiterMaxWait caps how long the SDK's typed waiters
// (instance-running, instance-terminated) block. We set a ceiling to fail
// loudly instead of hanging. Instance-running is overridable per-call via
// the `-instance-running-timeout` flag for slow-boot edge cases.
const defaultWaiterMaxWait = 30 * time.Minute

// ProvisionConfig is the parsed flag set for `provision`.
type ProvisionConfig struct {
	Region          string
	RunID           string
	ConsumerTagKey  string
	ConsumerTagVal  string
	VPCCIDR         string
	SubnetCIDR      string
	AvailabilityZone string

	AMIID                 string
	AMIOwner              string
	AMIFilter             string
	AMIArchitecture       string
	AMIVirtualizationType string

	SGName        string
	SGDescription string
	IngressRules  []IngressRule

	InstanceType    string
	InstanceProfile string
	InstanceRoles   []string
	RootDevice      string
	VolumeSizeGB    int32
	UserDataFile    string

	SSMWaitTimeout         time.Duration
	SSMWaitInterval        time.Duration
	SkipSSMWait            bool
	InstanceRunningTimeout time.Duration

	OutputPath   string
	OutputFormat string
}

// ResourceIDs is the result of provisioning. Every workflow consumer needs
// these IDs to drive subsequent steps and to clean up.
type ResourceIDs struct {
	VPCID            string   `json:"vpc_id"`
	IGWID            string   `json:"igw_id"`
	SubnetID         string   `json:"subnet_id"`
	RouteTableID     string   `json:"route_table_id"`
	RouteAssocID     string   `json:"route_assoc_id"`
	SecurityGroupID  string   `json:"security_group_id"`
	AMIID            string   `json:"ami_id"`
	InstanceIDs      []string `json:"instance_ids"`
	InstanceIDByRole map[string]string `json:"instance_id_by_role"`
	PrimaryPublicIP  string   `json:"primary_public_ip"`
}

func runProvision(ctx context.Context, logger *slog.Logger, name string, args []string) error {
	fs := flag.NewFlagSet(name, flag.ExitOnError)
	cfg := ProvisionConfig{}
	var (
		consumerTag string
		instanceRoles string
	)
	fs.StringVar(&cfg.Region, "region", "", "AWS region (required)")
	fs.StringVar(&cfg.RunID, "run-id", "", "Unique run identifier; tagged on every resource as RunID (required)")
	fs.StringVar(&consumerTag, "consumer-tag", "", "Consumer tag in KEY=VALUE form (e.g. SELinuxE2E=true) (required)")
	fs.StringVar(&cfg.VPCCIDR, "vpc-cidr", "10.0.0.0/16", "VPC CIDR")
	fs.StringVar(&cfg.SubnetCIDR, "subnet-cidr", "10.0.1.0/24", "Subnet CIDR")
	fs.StringVar(&cfg.AvailabilityZone, "availability-zone", "", "AZ for the subnet; if empty, picks the first AZ in the region")

	fs.StringVar(&cfg.AMIID, "ami-id", "", "Use this exact AMI ID (skips AMI lookup)")
	fs.StringVar(&cfg.AMIOwner, "ami-owner", "", "AMI owner (account ID or alias) for lookup")
	fs.StringVar(&cfg.AMIFilter, "ami-filter", "", "AMI name filter for lookup (latest CreationDate wins)")
	fs.StringVar(&cfg.AMIArchitecture, "ami-architecture", "", "Optional architecture filter for AMI lookup (e.g. x86_64, arm64). Empty means no filter.")
	fs.StringVar(&cfg.AMIVirtualizationType, "ami-virtualization-type", "", "Optional virtualization-type filter for AMI lookup (e.g. hvm, paravirtual). Empty means no filter.")

	fs.StringVar(&cfg.SGName, "sg-name", "", "Security group name (required)")
	fs.StringVar(&cfg.SGDescription, "sg-description", "", "Security group description")
	rules := ingressFlag{rules: &cfg.IngressRules}
	fs.Var(&rules, "ingress", "Ingress rule in protocol:fromPort:toPort:cidr form; repeatable")

	fs.StringVar(&cfg.InstanceType, "instance-type", "m5.xlarge", "EC2 instance type")
	fs.StringVar(&cfg.InstanceProfile, "instance-profile", "", "IAM instance profile name")
	fs.StringVar(&instanceRoles, "instance-roles", "primary,worker1,worker2", "Comma-separated role labels (one instance per role)")
	fs.StringVar(&cfg.RootDevice, "root-device", "/dev/sda1", "Root block-device name (e.g. /dev/sda1 or /dev/xvda)")
	var volumeSizeGB int
	fs.IntVar(&volumeSizeGB, "volume-size-gb", 100, "Root volume size in GB")
	fs.StringVar(&cfg.UserDataFile, "user-data-file", "", "Path to a file with raw user-data; the binary base64-encodes it before passing to RunInstances")

	fs.DurationVar(&cfg.SSMWaitTimeout, "ssm-wait-timeout", 5*time.Minute, "How long to wait for all SSM agents to register")
	fs.DurationVar(&cfg.SSMWaitInterval, "ssm-wait-interval", 10*time.Second, "Polling interval for SSM agent registration")
	fs.BoolVar(&cfg.SkipSSMWait, "skip-ssm-wait", false, "Skip waiting for SSM agents")
	fs.DurationVar(&cfg.InstanceRunningTimeout, "instance-running-timeout", defaultWaiterMaxWait, "Max wait for all instances to reach running state")

	fs.StringVar(&cfg.OutputPath, "output", "", "Output destination; empty means stdout. Set to $GITHUB_OUTPUT or $GITHUB_ENV to feed into Actions")
	fs.StringVar(&cfg.OutputFormat, "output-format", "auto", "auto | github-output | github-env | json")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parse provision flags: %w", err)
	}
	cfg.VolumeSizeGB = int32(volumeSizeGB)

	if err := finalizeProvisionConfig(&cfg, consumerTag, instanceRoles); err != nil {
		return err
	}

	awsCfg, err := loadAWSConfig(ctx, cfg.Region)
	if err != nil {
		return fmt.Errorf("load aws config: %w", err)
	}
	ec2Client := ec2.NewFromConfig(awsCfg)
	ssmClient := ssm.NewFromConfig(awsCfg)
	waiter := &ec2WaiterAdapter{
		client:                 ec2Client,
		instanceRunningTimeout: cfg.InstanceRunningTimeout,
	}

	ids, err := Provision(ctx, logger, ec2Client, ssmClient, waiter, cfg)
	if err != nil {
		// Provision returns whatever it managed to create so the caller can
		// pipe it into cleanup. We always emit so the action can capture IDs
		// for cleanup even on failure.
		_ = emitOutput(logger, cfg.OutputPath, cfg.OutputFormat, ids)
		return err
	}
	return emitOutput(logger, cfg.OutputPath, cfg.OutputFormat, ids)
}

// finalizeProvisionConfig validates required fields and parses raw form
// values (consumerTag, instanceRolesCSV) into cfg's derived fields. Pure
// function — no AWS, no I/O — so it's directly testable.
func finalizeProvisionConfig(cfg *ProvisionConfig, consumerTag, instanceRolesCSV string) error {
	if cfg.Region == "" {
		return errors.New("-region is required")
	}
	if cfg.RunID == "" {
		return errors.New("-run-id is required")
	}
	if cfg.SGName == "" {
		return errors.New("-sg-name is required")
	}
	if consumerTag == "" {
		return errors.New("-consumer-tag is required (KEY=VALUE)")
	}
	eq := strings.IndexByte(consumerTag, '=')
	if eq <= 0 || eq == len(consumerTag)-1 {
		return fmt.Errorf("-consumer-tag must be KEY=VALUE, got %q", consumerTag)
	}
	cfg.ConsumerTagKey = consumerTag[:eq]
	cfg.ConsumerTagVal = consumerTag[eq+1:]

	if cfg.AMIID == "" && (cfg.AMIOwner == "" || cfg.AMIFilter == "") {
		return errors.New("-ami-id, OR both of -ami-owner and -ami-filter, are required")
	}
	cfg.InstanceRoles = splitCSV(instanceRolesCSV)
	if len(cfg.InstanceRoles) == 0 {
		return errors.New("-instance-roles must contain at least one role")
	}
	if cfg.VolumeSizeGB <= 0 {
		return errors.New("-volume-size-gb must be > 0")
	}
	return nil
}

// Provision is the testable core of the provision command. It mutates
// nothing on the host, only AWS via the supplied EC2/SSM clients.
func Provision(
	ctx context.Context,
	logger *slog.Logger,
	c EC2API,
	s SSMAPI,
	waiter EC2Waiter,
	cfg ProvisionConfig,
) (ResourceIDs, error) {
	ids := ResourceIDs{InstanceIDByRole: map[string]string{}}

	// VPC
	vpcOut, err := c.CreateVpc(ctx, &ec2.CreateVpcInput{
		CidrBlock:         aws.String(cfg.VPCCIDR),
		TagSpecifications: tagSpec(types.ResourceTypeVpc, cfg, ""),
	})
	if err != nil {
		return ids, fmt.Errorf("create vpc: %w", err)
	}
	ids.VPCID = aws.ToString(vpcOut.Vpc.VpcId)
	logger.Info("created vpc", "vpc_id", ids.VPCID)

	// VPC attributes — DNS support + hostnames (so the public DNS name is
	// resolvable, which the existing workflows depend on).
	if _, err := c.ModifyVpcAttribute(ctx, &ec2.ModifyVpcAttributeInput{
		VpcId:            aws.String(ids.VPCID),
		EnableDnsSupport: &types.AttributeBooleanValue{Value: aws.Bool(true)},
	}); err != nil {
		return ids, fmt.Errorf("enable dns support: %w", err)
	}
	if _, err := c.ModifyVpcAttribute(ctx, &ec2.ModifyVpcAttributeInput{
		VpcId:              aws.String(ids.VPCID),
		EnableDnsHostnames: &types.AttributeBooleanValue{Value: aws.Bool(true)},
	}); err != nil {
		return ids, fmt.Errorf("enable dns hostnames: %w", err)
	}

	// Internet gateway
	igwOut, err := c.CreateInternetGateway(ctx, &ec2.CreateInternetGatewayInput{
		TagSpecifications: tagSpec(types.ResourceTypeInternetGateway, cfg, ""),
	})
	if err != nil {
		return ids, fmt.Errorf("create internet gateway: %w", err)
	}
	ids.IGWID = aws.ToString(igwOut.InternetGateway.InternetGatewayId)
	logger.Info("created igw", "igw_id", ids.IGWID)

	if _, err := c.AttachInternetGateway(ctx, &ec2.AttachInternetGatewayInput{
		InternetGatewayId: aws.String(ids.IGWID),
		VpcId:             aws.String(ids.VPCID),
	}); err != nil {
		return ids, fmt.Errorf("attach internet gateway: %w", err)
	}

	// AZ — auto-pick the first AZ if not given
	az := cfg.AvailabilityZone
	if az == "" {
		azOut, err := c.DescribeAvailabilityZones(ctx, &ec2.DescribeAvailabilityZonesInput{})
		if err != nil {
			return ids, fmt.Errorf("describe availability zones: %w", err)
		}
		if len(azOut.AvailabilityZones) == 0 {
			return ids, errors.New("no availability zones returned for region")
		}
		az = aws.ToString(azOut.AvailabilityZones[0].ZoneName)
	}

	// Subnet
	subnetOut, err := c.CreateSubnet(ctx, &ec2.CreateSubnetInput{
		VpcId:             aws.String(ids.VPCID),
		CidrBlock:         aws.String(cfg.SubnetCIDR),
		AvailabilityZone:  aws.String(az),
		TagSpecifications: tagSpec(types.ResourceTypeSubnet, cfg, ""),
	})
	if err != nil {
		return ids, fmt.Errorf("create subnet: %w", err)
	}
	ids.SubnetID = aws.ToString(subnetOut.Subnet.SubnetId)
	logger.Info("created subnet", "subnet_id", ids.SubnetID, "az", az)

	if _, err := c.ModifySubnetAttribute(ctx, &ec2.ModifySubnetAttributeInput{
		SubnetId:            aws.String(ids.SubnetID),
		MapPublicIpOnLaunch: &types.AttributeBooleanValue{Value: aws.Bool(true)},
	}); err != nil {
		return ids, fmt.Errorf("modify subnet attribute (map-public-ip): %w", err)
	}

	// Route table + default route + association
	rtOut, err := c.CreateRouteTable(ctx, &ec2.CreateRouteTableInput{
		VpcId:             aws.String(ids.VPCID),
		TagSpecifications: tagSpec(types.ResourceTypeRouteTable, cfg, ""),
	})
	if err != nil {
		return ids, fmt.Errorf("create route table: %w", err)
	}
	ids.RouteTableID = aws.ToString(rtOut.RouteTable.RouteTableId)

	if _, err := c.CreateRoute(ctx, &ec2.CreateRouteInput{
		RouteTableId:         aws.String(ids.RouteTableID),
		DestinationCidrBlock: aws.String("0.0.0.0/0"),
		GatewayId:            aws.String(ids.IGWID),
	}); err != nil {
		return ids, fmt.Errorf("create route: %w", err)
	}

	assocOut, err := c.AssociateRouteTable(ctx, &ec2.AssociateRouteTableInput{
		RouteTableId: aws.String(ids.RouteTableID),
		SubnetId:     aws.String(ids.SubnetID),
	})
	if err != nil {
		return ids, fmt.Errorf("associate route table: %w", err)
	}
	ids.RouteAssocID = aws.ToString(assocOut.AssociationId)
	logger.Info("created route table", "rt_id", ids.RouteTableID, "assoc_id", ids.RouteAssocID)

	// Security group + ingress rules
	desc := cfg.SGDescription
	if desc == "" {
		desc = fmt.Sprintf("aws-test-infra %s", cfg.RunID)
	}
	sgOut, err := c.CreateSecurityGroup(ctx, &ec2.CreateSecurityGroupInput{
		GroupName:         aws.String(cfg.SGName),
		Description:       aws.String(desc),
		VpcId:             aws.String(ids.VPCID),
		TagSpecifications: tagSpec(types.ResourceTypeSecurityGroup, cfg, ""),
	})
	if err != nil {
		return ids, fmt.Errorf("create security group: %w", err)
	}
	ids.SecurityGroupID = aws.ToString(sgOut.GroupId)
	logger.Info("created security group", "sg_id", ids.SecurityGroupID)

	for _, rule := range cfg.IngressRules {
		ipPerm := types.IpPermission{
			IpProtocol: aws.String(rule.Protocol),
			FromPort:   aws.Int32(rule.FromPort),
			ToPort:     aws.Int32(rule.ToPort),
			IpRanges:   []types.IpRange{{CidrIp: aws.String(rule.CIDR)}},
		}
		if _, err := c.AuthorizeSecurityGroupIngress(ctx, &ec2.AuthorizeSecurityGroupIngressInput{
			GroupId:       aws.String(ids.SecurityGroupID),
			IpPermissions: []types.IpPermission{ipPerm},
		}); err != nil {
			return ids, fmt.Errorf("authorize ingress %s:%d:%d:%s: %w", rule.Protocol, rule.FromPort, rule.ToPort, rule.CIDR, err)
		}
	}

	// Resolve AMI if not given
	amiID := cfg.AMIID
	if amiID == "" {
		amiID, err = resolveAMI(ctx, c, cfg.AMIOwner, cfg.AMIFilter, cfg.AMIArchitecture, cfg.AMIVirtualizationType)
		if err != nil {
			return ids, err
		}
		logger.Info("resolved ami", "ami_id", amiID, "filter", cfg.AMIFilter)
	}
	ids.AMIID = amiID

	// User data (optional)
	var userDataB64 *string
	if cfg.UserDataFile != "" {
		raw, err := os.ReadFile(cfg.UserDataFile)
		if err != nil {
			return ids, fmt.Errorf("read user-data file: %w", err)
		}
		b64 := base64.StdEncoding.EncodeToString(raw)
		userDataB64 = aws.String(b64)
	}

	// Launch instances per role
	for _, role := range cfg.InstanceRoles {
		instOut, err := c.RunInstances(ctx, &ec2.RunInstancesInput{
			ImageId:      aws.String(amiID),
			InstanceType: types.InstanceType(cfg.InstanceType),
			MinCount:     aws.Int32(1),
			MaxCount:     aws.Int32(1),
			SubnetId:     aws.String(ids.SubnetID),
			SecurityGroupIds: []string{ids.SecurityGroupID},
			IamInstanceProfile: instanceProfileSpec(cfg.InstanceProfile),
			BlockDeviceMappings: []types.BlockDeviceMapping{{
				DeviceName: aws.String(cfg.RootDevice),
				Ebs: &types.EbsBlockDevice{
					VolumeSize:          aws.Int32(cfg.VolumeSizeGB),
					VolumeType:          types.VolumeTypeGp3,
					DeleteOnTermination: aws.Bool(true),
				},
			}},
			UserData:          userDataB64,
			TagSpecifications: tagSpec(types.ResourceTypeInstance, cfg, role),
		})
		if err != nil {
			return ids, fmt.Errorf("run instances (role=%s): %w", role, err)
		}
		if len(instOut.Instances) == 0 {
			return ids, fmt.Errorf("run instances (role=%s) returned no instances", role)
		}
		instID := aws.ToString(instOut.Instances[0].InstanceId)
		ids.InstanceIDs = append(ids.InstanceIDs, instID)
		ids.InstanceIDByRole[role] = instID
		logger.Info("launched instance", "role", role, "instance_id", instID)
	}

	// Wait for instance-running on all
	if err := waiter.WaitInstanceRunning(ctx, ids.InstanceIDs); err != nil {
		return ids, fmt.Errorf("wait instance-running: %w", err)
	}

	// Pull primary public IP (the existing workflows use the public IP of
	// the first instance — by convention, "primary" — for runner→primary
	// and worker→primary connectivity).
	if len(ids.InstanceIDs) > 0 {
		descOut, err := c.DescribeInstances(ctx, &ec2.DescribeInstancesInput{
			InstanceIds: []string{ids.InstanceIDs[0]},
		})
		if err != nil {
			return ids, fmt.Errorf("describe primary instance: %w", err)
		}
		if len(descOut.Reservations) > 0 && len(descOut.Reservations[0].Instances) > 0 {
			ids.PrimaryPublicIP = aws.ToString(descOut.Reservations[0].Instances[0].PublicIpAddress)
		}
	}

	// SSM agent registration wait
	if !cfg.SkipSSMWait {
		if err := waitSSMOnline(ctx, logger, s, ids.InstanceIDs, cfg.SSMWaitTimeout, cfg.SSMWaitInterval); err != nil {
			return ids, err
		}
	}

	return ids, nil
}

func resolveAMI(ctx context.Context, c EC2API, owner, filter, architecture, virtualizationType string) (string, error) {
	filters := []types.Filter{
		{Name: aws.String("name"), Values: []string{filter}},
		{Name: aws.String("state"), Values: []string{"available"}},
	}
	if architecture != "" {
		filters = append(filters, types.Filter{Name: aws.String("architecture"), Values: []string{architecture}})
	}
	if virtualizationType != "" {
		filters = append(filters, types.Filter{Name: aws.String("virtualization-type"), Values: []string{virtualizationType}})
	}
	out, err := c.DescribeImages(ctx, &ec2.DescribeImagesInput{
		Owners:  []string{owner},
		Filters: filters,
	})
	if err != nil {
		return "", fmt.Errorf("describe images: %w", err)
	}
	if len(out.Images) == 0 {
		return "", fmt.Errorf("no AMIs found for owner=%s filter=%s", owner, filter)
	}
	// Pick the latest by CreationDate.
	latestIdx := 0
	for i := 1; i < len(out.Images); i++ {
		if aws.ToString(out.Images[i].CreationDate) > aws.ToString(out.Images[latestIdx].CreationDate) {
			latestIdx = i
		}
	}
	return aws.ToString(out.Images[latestIdx].ImageId), nil
}

func waitSSMOnline(
	ctx context.Context,
	logger *slog.Logger,
	s SSMAPI,
	instanceIDs []string,
	timeout time.Duration,
	interval time.Duration,
) error {
	deadline := time.Now().Add(timeout)
	for {
		out, err := s.DescribeInstanceInformation(ctx, &ssm.DescribeInstanceInformationInput{
			Filters: []ssmtypes.InstanceInformationStringFilter{
				{Key: aws.String("InstanceIds"), Values: instanceIDs},
			},
		})
		if err == nil {
			online := 0
			for _, info := range out.InstanceInformationList {
				if info.PingStatus == "Online" {
					online++
				}
			}
			logger.Info("ssm wait", "online", online, "total", len(instanceIDs))
			if online == len(instanceIDs) {
				return nil
			}
		} else {
			logger.Warn("describe-instance-information errored, retrying", "err", err)
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for SSM agents (%d instances)", len(instanceIDs))
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(interval):
		}
	}
}

func tagSpec(rt types.ResourceType, cfg ProvisionConfig, role string) []types.TagSpecification {
	tags := []types.Tag{
		{Key: aws.String(cfg.ConsumerTagKey), Value: aws.String(cfg.ConsumerTagVal)},
		{Key: aws.String("RunID"), Value: aws.String(cfg.RunID)},
	}
	if role != "" {
		tags = append(tags, types.Tag{Key: aws.String("Role"), Value: aws.String(role)})
	}
	return []types.TagSpecification{{ResourceType: rt, Tags: tags}}
}

func instanceProfileSpec(name string) *types.IamInstanceProfileSpecification {
	if name == "" {
		return nil
	}
	return &types.IamInstanceProfileSpecification{Name: aws.String(name)}
}

func splitCSV(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

