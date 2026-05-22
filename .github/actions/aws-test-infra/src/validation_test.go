package main

import (
	"strings"
	"testing"
)

// validProvisionConfig returns a config that passes finalizeProvisionConfig
// — tests below mutate one field at a time to verify each validation
// branch.
func validProvisionConfig() ProvisionConfig {
	return ProvisionConfig{
		Region:       "us-west-2",
		RunID:        "run-42",
		SGName:       "sg-test",
		AMIOwner:     "099720109477",
		AMIFilter:    "ubuntu-jammy*",
		VolumeSizeGB: 100,
	}
}

func TestFinalizeProvisionConfig_HappyPath(t *testing.T) {
	cfg := validProvisionConfig()
	if err := finalizeProvisionConfig(&cfg, "SELinuxE2E=true", "primary,worker1,worker2"); err != nil {
		t.Fatalf("happy path errored: %v", err)
	}
	if cfg.ConsumerTagKey != "SELinuxE2E" || cfg.ConsumerTagVal != "true" {
		t.Errorf("consumer-tag mis-parsed: key=%q val=%q", cfg.ConsumerTagKey, cfg.ConsumerTagVal)
	}
	if len(cfg.InstanceRoles) != 3 || cfg.InstanceRoles[0] != "primary" {
		t.Errorf("InstanceRoles mis-parsed: %v", cfg.InstanceRoles)
	}
}

func TestFinalizeProvisionConfig_RejectsBadInput(t *testing.T) {
	tests := []struct {
		name        string
		mutate      func(*ProvisionConfig)
		consumerTag string
		roles       string
		wantErrSub  string
	}{
		{
			name:        "missing region",
			mutate:      func(c *ProvisionConfig) { c.Region = "" },
			consumerTag: "SELinuxE2E=true",
			roles:       "primary",
			wantErrSub:  "-region is required",
		},
		{
			name:        "missing run-id",
			mutate:      func(c *ProvisionConfig) { c.RunID = "" },
			consumerTag: "SELinuxE2E=true",
			roles:       "primary",
			wantErrSub:  "-run-id is required",
		},
		{
			name:        "missing sg-name",
			mutate:      func(c *ProvisionConfig) { c.SGName = "" },
			consumerTag: "SELinuxE2E=true",
			roles:       "primary",
			wantErrSub:  "-sg-name is required",
		},
		{
			name:        "empty consumer-tag",
			mutate:      func(c *ProvisionConfig) {},
			consumerTag: "",
			roles:       "primary",
			wantErrSub:  "-consumer-tag is required",
		},
		{
			// Covers the three sub-cases of the same check
			// (`eq <= 0 || eq == len(consumerTag)-1`): missing-equals,
			// empty-key, empty-value all hit the same branch.
			name:        "consumer-tag malformed",
			mutate:      func(c *ProvisionConfig) {},
			consumerTag: "SELinuxE2Etrue",
			roles:       "primary",
			wantErrSub:  "must be KEY=VALUE",
		},
		{
			name: "no AMI source",
			mutate: func(c *ProvisionConfig) {
				c.AMIID = ""
				c.AMIOwner = ""
				c.AMIFilter = ""
			},
			consumerTag: "SELinuxE2E=true",
			roles:       "primary",
			wantErrSub:  "-ami-id, OR both of -ami-owner and -ami-filter",
		},
		{
			// Both empty and whitespace-only inputs hit the same
			// `len(cfg.InstanceRoles) == 0` check after splitCSV.
			name:        "instance-roles produces no roles",
			mutate:      func(c *ProvisionConfig) {},
			consumerTag: "SELinuxE2E=true",
			roles:       " , ,",
			wantErrSub:  "instance-roles must contain at least one role",
		},
		{
			name:        "non-positive volume-size",
			mutate:      func(c *ProvisionConfig) { c.VolumeSizeGB = 0 },
			consumerTag: "SELinuxE2E=true",
			roles:       "primary",
			wantErrSub:  "-volume-size-gb must be > 0",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			cfg := validProvisionConfig()
			tt.mutate(&cfg)
			err := finalizeProvisionConfig(&cfg, tt.consumerTag, tt.roles)
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tt.wantErrSub)
			}
			if !strings.Contains(err.Error(), tt.wantErrSub) {
				t.Errorf("error %q does not contain %q", err.Error(), tt.wantErrSub)
			}
		})
	}
}

func TestFinalizeProvisionConfig_AMIIDAloneIsValid(t *testing.T) {
	// Passing -ami-id with no owner/filter should be accepted: the binary
	// uses the literal AMI and skips DescribeImages.
	cfg := validProvisionConfig()
	cfg.AMIOwner = ""
	cfg.AMIFilter = ""
	cfg.AMIID = "ami-pinned"
	if err := finalizeProvisionConfig(&cfg, "SELinuxE2E=true", "primary"); err != nil {
		t.Errorf("ami-id-only config rejected: %v", err)
	}
}

func TestFinalizeCleanupConfig_RejectsBadInput(t *testing.T) {
	tests := []struct {
		name       string
		cfg        CleanupConfig
		wantErrSub string
	}{
		{
			name:       "missing region",
			cfg:        CleanupConfig{RunID: "run-42"},
			wantErrSub: "-region is required",
		},
		{
			name:       "missing run-id with sweep enabled",
			cfg:        CleanupConfig{Region: "us-west-2"},
			wantErrSub: "-run-id is required",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			err := finalizeCleanupConfig(&tt.cfg, "")
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tt.wantErrSub)
			}
			if !strings.Contains(err.Error(), tt.wantErrSub) {
				t.Errorf("error %q does not contain %q", err.Error(), tt.wantErrSub)
			}
		})
	}
}

func TestFinalizeCleanupConfig_SkipSweepRelaxesRunID(t *testing.T) {
	// With -skip-sweep, run-id isn't needed (no tag-based discovery).
	// This is the only way to opt out of the sweep-needs-run-id check.
	cfg := CleanupConfig{Region: "us-west-2", SkipSweep: true}
	if err := finalizeCleanupConfig(&cfg, ""); err != nil {
		t.Errorf("skip-sweep without run-id rejected: %v", err)
	}
}
