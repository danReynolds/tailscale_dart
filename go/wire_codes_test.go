package tailscale

import (
	"errors"
	"testing"
)

func TestLifecycleErrorCodePrecedence(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want string
	}{
		{
			name: "logout uncertainty wins over cleanup failure",
			err:  errors.Join(ErrRuntimeCleanupFailed, ErrLogoutIndeterminate),
			want: "logoutIndeterminate",
		},
		{
			name: "cleanup failure wins over retryable lifecycle error",
			err:  errors.Join(ErrLifecycleBusy, ErrRuntimeCleanupFailed),
			want: "runtimeCleanupFailed",
		},
		{
			name: "abandonment wins over stale runtime",
			err:  errors.Join(ErrRuntimeStale, ErrStartupAbandoned),
			want: "startupAbandoned",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := LifecycleErrorCode(test.err); got != test.want {
				t.Fatalf("LifecycleErrorCode() = %q, want %q", got, test.want)
			}
		})
	}
}
