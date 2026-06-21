package tailscale

import (
	"context"
	"net/netip"
	"os"
	"testing"
	"time"
)

// Benchmarks for the per-accept identity cost.
//
// The fd_transport benchmark in benchmark/ measures the socketpair data plane
// directly and never crosses the tsnet accept path, so it cannot see identity
// resolution. These benchmarks cover that gap: they isolate the one thing
// accept-time identity adds — a WhoIs over the in-process LocalAPI loopback.

// BenchmarkLookupNodeIdentityLoopback measures the cold-cache fallback: one
// LocalAPI WhoIs over the in-process loopback against a live netmap. This is
// the "before" — the per-accept cost when the cache is not warm. Gated on a
// Headscale environment (same gating as the Dart e2e) because a real control
// plane is required to produce a netmap.
//
//	HEADSCALE_URL=http://localhost:8080 HEADSCALE_AUTH_KEY=<key> \
//	  go test -run '^$' -bench BenchmarkLookupNodeIdentityLoopback -benchtime=300x .
func BenchmarkLookupNodeIdentityLoopback(b *testing.B) {
	ip := startTestNode(b)
	identityCache.invalidate() // force the loopback fallback path
	if id := lookupNodeIdentity(ip); id != nil {
		b.Logf("resolved self via loopback: nodeId=%s host=%s", id.NodeID, id.HostName)
	} else {
		b.Logf("self IP %s did not resolve; still measuring loopback round-trip", ip)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = lookupNodeIdentity(ip)
	}
}

// BenchmarkLookupNodeIdentityCached measures the warm path: the same
// lookupNodeIdentity call once the state watcher has mirrored the netmap into
// the identity cache. This is the "after" — what accept-time identity costs
// with the cache in place. Same Headscale gating.
func BenchmarkLookupNodeIdentityCached(b *testing.B) {
	ip := startTestNode(b)
	StartWatch()
	b.Cleanup(StopWatch)

	addr := netip.MustParseAddr(ip)
	deadline := time.Now().Add(30 * time.Second)
	for {
		if id, ok := identityCache.lookup(addr); ok && id != nil {
			b.Logf("cache warm: self nodeId=%s", id.NodeID)
			break
		}
		if time.Now().After(deadline) {
			b.Fatal("identity cache did not warm within 30s")
		}
		time.Sleep(100 * time.Millisecond)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = lookupNodeIdentity(ip)
	}
}

// BenchmarkIdentityCacheFloor is the lower bound a cache would approach: a pure
// in-memory address->identity read with no loopback. The gap between this and
// BenchmarkLookupNodeIdentityLoopback is what a netmap/result cache could save
// per accept — the number that decides whether a cache is worth its complexity.
// Runs without a tailnet.
func BenchmarkIdentityCacheFloor(b *testing.B) {
	addr := netip.MustParseAddr("100.64.0.2")
	cache := map[netip.Addr]*nodeIdentity{
		addr: {
			NodeID:       "nABC123",
			HostName:     "peer-1",
			Tags:         []string{"tag:server"},
			TailscaleIPs: []string{"100.64.0.2"},
		},
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if cache[addr] == nil {
			b.Fatal("unexpected cache miss")
		}
	}
}

// startTestNode brings up an ephemeral node against Headscale and returns its
// self tailnet IP once the netmap is ready. Skips when the environment is
// absent so `go test ./...` stays hermetic.
func startTestNode(tb testing.TB) string {
	tb.Helper()
	url := os.Getenv("HEADSCALE_URL")
	key := os.Getenv("HEADSCALE_AUTH_KEY")
	if url == "" || key == "" {
		tb.Skip("set HEADSCALE_URL and HEADSCALE_AUTH_KEY to run the live identity benchmark")
	}
	if err := Start("dune-bench", key, url, tb.TempDir(), true); err != nil {
		tb.Fatalf("Start: %v", err)
	}
	tb.Cleanup(Stop)

	lc, err := lcOr("identityBench")
	if err != nil {
		tb.Fatalf("LocalClient: %v", err)
	}
	deadline := time.Now().Add(60 * time.Second)
	for {
		st, err := lc.Status(context.Background())
		if err == nil && st != nil && st.Self != nil && len(st.Self.TailscaleIPs) > 0 {
			return st.Self.TailscaleIPs[0].String()
		}
		if time.Now().After(deadline) {
			tb.Fatal("node did not reach Running with a self IP within 60s")
		}
		time.Sleep(500 * time.Millisecond)
	}
}
