package main

import (
	"testing"
	"time"
)

func TestEC2WaiterAdapter_EffectiveInstanceRunningTimeout(t *testing.T) {
	tests := []struct {
		name       string
		configured time.Duration
		want       time.Duration
	}{
		{"zero falls back to default", 0, defaultWaiterMaxWait},
		{"negative falls back to default", -5 * time.Minute, defaultWaiterMaxWait},
		{"positive value used as-is", 45 * time.Minute, 45 * time.Minute},
		{"default constant is 30 minutes", -1, 30 * time.Minute},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			a := &ec2WaiterAdapter{instanceRunningTimeout: tt.configured}
			if got := a.effectiveInstanceRunningTimeout(); got != tt.want {
				t.Errorf("effectiveInstanceRunningTimeout() = %v, want %v", got, tt.want)
			}
		})
	}
}
