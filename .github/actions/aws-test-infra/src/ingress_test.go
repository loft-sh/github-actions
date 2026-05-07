package main

import "testing"

func TestParseIngressRule(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    IngressRule
		wantErr bool
	}{
		{
			name:  "intra-vpc all protocols",
			input: "-1:-1:-1:10.0.0.0/16",
			want:  IngressRule{Protocol: "-1", FromPort: -1, ToPort: -1, CIDR: "10.0.0.0/16"},
		},
		{
			name:  "tcp wide-open vCluster API",
			input: "tcp:8443:8443:0.0.0.0/0",
			want:  IngressRule{Protocol: "tcp", FromPort: 8443, ToPort: 8443, CIDR: "0.0.0.0/0"},
		},
		{
			name:  "tcp NodePort range scoped to runner",
			input: "tcp:30000:32767:1.2.3.4/32",
			want:  IngressRule{Protocol: "tcp", FromPort: 30000, ToPort: 32767, CIDR: "1.2.3.4/32"},
		},
		{
			name:  "icmp intra-vpc",
			input: "icmp:-1:-1:10.0.0.0/16",
			want:  IngressRule{Protocol: "icmp", FromPort: -1, ToPort: -1, CIDR: "10.0.0.0/16"},
		},
		{name: "missing fields", input: "tcp:8443:8443", wantErr: true},
		{name: "empty protocol", input: ":8443:8443:0.0.0.0/0", wantErr: true},
		{name: "empty cidr", input: "tcp:8443:8443:", wantErr: true},
		{name: "non-numeric port", input: "tcp:abc:8443:0.0.0.0/0", wantErr: true},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseIngressRule(tt.input)
			if (err != nil) != tt.wantErr {
				t.Fatalf("parseIngressRule(%q) err=%v wantErr=%v", tt.input, err, tt.wantErr)
			}
			if tt.wantErr {
				return
			}
			if got != tt.want {
				t.Errorf("parseIngressRule(%q) = %+v, want %+v", tt.input, got, tt.want)
			}
		})
	}
}

func TestIngressFlagAccumulates(t *testing.T) {
	var rules []IngressRule
	f := ingressFlag{rules: &rules}

	for _, in := range []string{
		"-1:-1:-1:10.0.0.0/16",
		"tcp:8443:8443:0.0.0.0/0",
		"icmp:-1:-1:10.0.0.0/16",
	} {
		if err := f.Set(in); err != nil {
			t.Fatalf("Set(%q): %v", in, err)
		}
	}

	if len(rules) != 3 {
		t.Fatalf("got %d rules, want 3", len(rules))
	}
	if rules[1].Protocol != "tcp" || rules[1].FromPort != 8443 {
		t.Errorf("rule[1] mis-parsed: %+v", rules[1])
	}
}
