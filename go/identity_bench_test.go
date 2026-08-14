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

// BenchmarkLookupNodeIdentity measures both identity paths against one
// independently identified live peer. The shared parent fixture matters:
// Configure is intentionally process-once, while Go may re-enter a top-level
// benchmark during calibration.
//
//	HEADSCALE_URL=http://localhost:8080 HEADSCALE_AUTH_KEY=<key> \
//	  go test -run '^$' -bench BenchmarkLookupNodeIdentity -benchtime=500x -benchmem .
func BenchmarkLookupNodeIdentity(b *testing.B) {
	_ = startTestNode(b)
	cache := activeIdentityIndex(b)
	peer := startIdentityGatePeer(b)
	addr, identity := waitForIdentityGatePeer(b, peer)
	b.Cleanup(cache.invalidate)

	b.Run("Direct", func(b *testing.B) {
		// A cold cache forces one LocalAPI WhoIs over the in-process loopback.
		cache.invalidate()
		if id := lookupNodeIdentity(peer.ip); id == nil || id.NodeID != identity.NodeID {
			b.Fatalf("peer lookup = %#v, want node ID %q", id, identity.NodeID)
		}
		b.ReportAllocs()
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if id := lookupNodeIdentity(peer.ip); id == nil || id.NodeID != peer.nodeID {
				b.Fatalf("peer lookup = %#v, want node ID %q", id, peer.nodeID)
			}
		}
	})

	b.Run("Cached", func(b *testing.B) {
		// Seed the verified identity directly. Watcher/cache-population behavior
		// has separate tests and must not add timing noise to this cost measure.
		cache.replace(map[netip.Addr]*nodeIdentity{addr: identity})
		b.ReportAllocs()
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if id := lookupNodeIdentity(peer.ip); id == nil || id.NodeID != peer.nodeID {
				b.Fatalf("peer lookup = %#v, want node ID %q", id, peer.nodeID)
			}
		}
	})
}

// BenchmarkIdentityCacheFloor is the lower bound a cache would approach: a pure
// in-memory address->identity read with no loopback. The gap between this and
// BenchmarkLookupNodeIdentity/Direct is what a netmap/result cache could save
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
	if _, err := Configure(tb.TempDir(), "dev.tailscale.dart.bench.tailscale", 0, 0); err != nil {
		tb.Fatalf("Configure: %v", err)
	}
	if err := Start("dune-bench", key, url, true); err != nil {
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
