package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
)

// emitOutput writes ResourceIDs to the destination chosen by the caller.
//
// destination semantics:
//
//   - "" (empty)              → JSON to stdout
//   - $GITHUB_OUTPUT path     → key=value lines (consumable by `${{ steps.x.outputs.* }}`)
//   - $GITHUB_ENV path        → key=value lines (visible to subsequent steps as env vars)
//   - any other path          → file in the chosen format
//
// format chooses the encoding when the destination doesn't make it obvious:
//
//   - "auto"          → infer from destination path
//   - "github-output" / "github-env" → key=value lines (identical encoding;
//     the only difference is which file the action runner reads them from)
//   - "json"          → pretty-printed JSON
func emitOutput(logger *slog.Logger, destination, format string, ids ResourceIDs) error {
	if format == "" {
		format = "auto"
	}
	if format == "auto" {
		switch {
		case destination == "":
			format = "json"
		case strings.HasSuffix(destination, "GITHUB_OUTPUT") || strings.Contains(destination, "/runner/file_commands/set_output"):
			format = "github-output"
		case strings.HasSuffix(destination, "GITHUB_ENV") || strings.Contains(destination, "/runner/file_commands/set_env"):
			format = "github-env"
		default:
			format = "json"
		}
	}

	var w io.Writer
	if destination == "" {
		w = os.Stdout
	} else {
		// GITHUB_OUTPUT / GITHUB_ENV are append-mode files per Actions docs.
		f, err := os.OpenFile(destination, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			return fmt.Errorf("open output destination %q: %w", destination, err)
		}
		defer f.Close()
		w = f
	}

	switch format {
	case "json":
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		if err := enc.Encode(ids); err != nil {
			return fmt.Errorf("encode json output: %w", err)
		}
	case "github-output", "github-env":
		if err := writeKeyValuePairs(w, ids); err != nil {
			return fmt.Errorf("write key-value output: %w", err)
		}
	default:
		return fmt.Errorf("unknown output format: %s", format)
	}

	logger.Info("emitted output", "destination", destinationLabel(destination), "format", format)
	return nil
}

func destinationLabel(d string) string {
	if d == "" {
		return "stdout"
	}
	return d
}

func writeKeyValuePairs(w io.Writer, ids ResourceIDs) error {
	pairs := []struct {
		k, v string
	}{
		{"vpc_id", ids.VPCID},
		{"igw_id", ids.IGWID},
		{"subnet_id", ids.SubnetID},
		{"route_table_id", ids.RouteTableID},
		{"route_assoc_id", ids.RouteAssocID},
		{"security_group_id", ids.SecurityGroupID},
		{"ami_id", ids.AMIID},
		{"primary_public_ip", ids.PrimaryPublicIP},
		{"instance_ids", strings.Join(ids.InstanceIDs, ",")},
	}
	for _, p := range pairs {
		if _, err := fmt.Fprintf(w, "%s=%s\n", p.k, p.v); err != nil {
			return err
		}
	}
	for role, id := range ids.InstanceIDByRole {
		if _, err := fmt.Fprintf(w, "instance_id_%s=%s\n", role, id); err != nil {
			return err
		}
	}
	// JSON-map of role → instance ID. Consumers with arbitrary role names
	// (anything other than primary/worker1/worker2) read this with
	// `${{ fromJSON(steps.provision.outputs.instance-id-by-role).<role> }}`.
	roleJSON, err := json.Marshal(ids.InstanceIDByRole)
	if err != nil {
		return fmt.Errorf("encode instance-id-by-role: %w", err)
	}
	if _, err := fmt.Fprintf(w, "instance_id_by_role=%s\n", roleJSON); err != nil {
		return err
	}
	return nil
}
