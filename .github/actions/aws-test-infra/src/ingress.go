package main

import (
	"fmt"
	"strconv"
	"strings"
)

// IngressRule describes a single security-group ingress permission.
//
// Encoded as a colon-delimited string for CLI use:
//
//	<protocol>:<fromPort>:<toPort>:<cidr>
//
// Examples (lifted from the existing workflows):
//
//	-1:-1:-1:10.0.0.0/16            (intra-VPC, all protocols)
//	tcp:8443:8443:0.0.0.0/0         (vCluster API, wide-open)
//	tcp:30000:32767:1.2.3.4/32      (NodePort range, runner-only)
//	icmp:-1:-1:10.0.0.0/16          (ICMP intra-VPC)
//
// Protocol "-1" means "all protocols". When protocol is "-1" or "icmp", AWS
// requires fromPort/toPort to be -1 (the workflow Bash sets them to -1 in
// these cases too).
type IngressRule struct {
	Protocol string
	FromPort int32
	ToPort   int32
	CIDR     string
}

func parseIngressRule(s string) (IngressRule, error) {
	parts := strings.SplitN(s, ":", 4)
	if len(parts) != 4 {
		return IngressRule{}, fmt.Errorf("ingress rule %q: expected protocol:fromPort:toPort:cidr", s)
	}

	from, err := strconv.ParseInt(parts[1], 10, 32)
	if err != nil {
		return IngressRule{}, fmt.Errorf("ingress rule %q: parse fromPort: %w", s, err)
	}
	to, err := strconv.ParseInt(parts[2], 10, 32)
	if err != nil {
		return IngressRule{}, fmt.Errorf("ingress rule %q: parse toPort: %w", s, err)
	}

	if parts[0] == "" {
		return IngressRule{}, fmt.Errorf("ingress rule %q: protocol is empty", s)
	}
	if parts[3] == "" {
		return IngressRule{}, fmt.Errorf("ingress rule %q: cidr is empty", s)
	}

	return IngressRule{
		Protocol: parts[0],
		FromPort: int32(from),
		ToPort:   int32(to),
		CIDR:     parts[3],
	}, nil
}

// ingressFlag implements flag.Value, allowing -ingress to be repeated.
type ingressFlag struct {
	rules *[]IngressRule
}

func (f *ingressFlag) String() string {
	if f.rules == nil {
		return ""
	}
	parts := make([]string, 0, len(*f.rules))
	for _, r := range *f.rules {
		parts = append(parts, fmt.Sprintf("%s:%d:%d:%s", r.Protocol, r.FromPort, r.ToPort, r.CIDR))
	}
	return strings.Join(parts, ",")
}

func (f *ingressFlag) Set(value string) error {
	rule, err := parseIngressRule(value)
	if err != nil {
		return err
	}
	*f.rules = append(*f.rules, rule)
	return nil
}
