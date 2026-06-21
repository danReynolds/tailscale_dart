package tailscale

import (
	"context"
	"sort"
	"testing"
	"time"

	"tailscale.com/safesocket"
)

// timeCalls runs fn n times and reports p50/mean/max wall-clock.
func timeCalls(t *testing.T, label string, n int, fn func()) {
	t.Helper()
	ds := make([]time.Duration, n)
	for i := range ds {
		start := time.Now()
		fn()
		ds[i] = time.Since(start)
	}
	sort.Slice(ds, func(i, j int) bool { return ds[i] < ds[j] })
	var sum time.Duration
	for _, d := range ds {
		sum += d
	}
	t.Logf("%-28s p50=%-10v mean=%-10v max=%-10v (n=%d)",
		label, ds[n/2].Round(time.Microsecond), (sum / time.Duration(n)).Round(time.Microsecond), ds[n-1].Round(time.Microsecond), n)
}

// TestLoopbackLatencyBisection localizes the multi-millisecond LocalAPI loopback
// cost. Hypothesis: it is not the in-process memnet transport but the per-request
// auth-token lookup in local.Client.DoLocalRequest, which on darwin forks `lsof`
// (safesocket.readMacosSameUserProof) hunting for a macOS GUI credential file
// that does not exist in an embedded tsnet process. Setting OmitAuth skips it.
//
// Gated on Headscale like the other live tests. Diagnostic only — it asserts the
// direction of the win, not exact numbers, so it stays stable across machines.
func TestLoopbackLatencyBisection(t *testing.T) {
	ip := startTestNode(t)
	lc, err := lcOr("diag")
	if err != nil {
		t.Fatalf("LocalClient: %v", err)
	}
	ctx := context.Background()

	// 1. The suspected culprit in isolation: the per-request token lookup.
	var tokenLookup time.Duration
	timeCalls(t, "safesocket token lookup", 20, func() {
		start := time.Now()
		_, _, _ = safesocket.LocalTCPPortAndToken()
		tokenLookup += time.Since(start)
	})

	// 2. Full WhoIs round-trip with auth ON (the shipping default — OmitAuth
	//    is false because tsnet never sets it).
	lc.OmitAuth = false
	var authOn time.Duration
	timeCalls(t, "WhoIs (OmitAuth=false)", 20, func() {
		start := time.Now()
		_, _ = lc.WhoIs(ctx, ip)
		authOn += time.Since(start)
	})

	// 3. Same call with auth OFF: skips the token lookup entirely. If the
	//    hypothesis holds this collapses to the bare memnet+JSON cost.
	lc.OmitAuth = true
	var authOff time.Duration
	timeCalls(t, "WhoIs (OmitAuth=true)", 20, func() {
		start := time.Now()
		_, _ = lc.WhoIs(ctx, ip)
		authOff += time.Since(start)
	})

	// 4. A second, unrelated LocalAPI method to confirm the cost is systemic
	//    (shared DoLocalRequest path), not WhoIs-specific.
	lc.OmitAuth = false
	timeCalls(t, "StatusWithoutPeers (auth ON)", 20, func() {
		_, _ = lc.StatusWithoutPeers(ctx)
	})
	lc.OmitAuth = true
	timeCalls(t, "StatusWithoutPeers (auth OFF)", 20, func() {
		_, _ = lc.StatusWithoutPeers(ctx)
	})

	t.Logf("SUMMARY: token-lookup≈%v/call, WhoIs auth-on≈%v, auth-off≈%v",
		(tokenLookup / 20).Round(time.Microsecond),
		(authOn / 20).Round(time.Microsecond),
		(authOff / 20).Round(time.Microsecond))

	// Direction assertion: dropping the token lookup must be a large win.
	if authOff*4 > authOn {
		t.Errorf("expected OmitAuth=true to be >4x faster; got auth-on=%v auth-off=%v", authOn, authOff)
	}
}
