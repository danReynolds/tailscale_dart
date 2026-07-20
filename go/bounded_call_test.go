package tailscale

import (
	"testing"
	"time"
)

// TestBoundedCallCtx_DefaultsWhenUnset: a native call with no caller timeout
// must still carry a deadline (the "no unbounded native call" invariant — an
// abandoned unbounded call would pin a helper isolate, OS thread, offload-gate
// permit, and goroutine until process exit).
func TestBoundedCallCtx_DefaultsWhenUnset(t *testing.T) {
	for _, timeout := range []time.Duration{0, -time.Second} {
		ctx, cancel := boundedCallCtx(timeout)
		deadline, ok := ctx.Deadline()
		cancel()
		if !ok {
			t.Fatalf("boundedCallCtx(%v) must carry a deadline", timeout)
		}
		remaining := time.Until(deadline)
		if remaining <= 0 || remaining > defaultNativeCallTimeout {
			t.Fatalf("default deadline out of range: %v remaining", remaining)
		}
	}
}

// TestBoundedCallCtx_HonorsCallerTimeout: an explicit caller timeout is used
// as given, not replaced by the default.
func TestBoundedCallCtx_HonorsCallerTimeout(t *testing.T) {
	const want = 250 * time.Millisecond
	ctx, cancel := boundedCallCtx(want)
	defer cancel()
	deadline, ok := ctx.Deadline()
	if !ok {
		t.Fatal("caller timeout must produce a deadline")
	}
	remaining := time.Until(deadline)
	if remaining <= 0 || remaining > want {
		t.Fatalf("caller deadline out of range: %v remaining (want <= %v)", remaining, want)
	}
	// And the deadline actually fires.
	select {
	case <-ctx.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("context did not expire at its deadline")
	}
}
