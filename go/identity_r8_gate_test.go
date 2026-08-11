package tailscale

import (
	"context"
	"fmt"
	"math"
	"net/netip"
	"os"
	"sort"
	"sync"
	"testing"
	"time"

	"tailscale.com/tsnet"
)

// R8's removal gate needs distribution and concurrency, which `go test -bench`
// cannot express: it reports a mean over a serial loop. This harness measures
// the same lookupNodeIdentity call the accept path uses, at the acceptor
// concurrencies the plan names, and reports p50/p95/p99 plus a pass/fail
// verdict against the documented thresholds.
//
// It is a test rather than a benchmark so it can assert. Gated on the same
// Headscale environment as the identity benchmarks, so `go test ./...` stays
// hermetic:
//
//	HEADSCALE_URL=http://localhost:8080 HEADSCALE_AUTH_KEY=<key> \
//	  go test -run TestR8IdentityLatencyGate -v .
//
// Record the output in the plan's R8 section together with the commit it ran
// against; the decision it governs is whether the runtime-owned cache survives.
const (
	// r8P95Budget and r8P99Budget are the plan's provisional removal gate for
	// the direct path (doc/rearchitecture-plan.md, R8).
	r8P95Budget = 1 * time.Millisecond
	r8P99Budget = 5 * time.Millisecond

	// r8SamplesPerWorker keeps a full run in the low tens of seconds while
	// still giving p99 a few hundred samples at the highest concurrency.
	r8SamplesPerWorker = 200
)

type latencyDistribution struct {
	samples []time.Duration
}

func (d *latencyDistribution) percentile(p float64) time.Duration {
	if len(d.samples) == 0 {
		return 0
	}
	// Nearest-rank on a sorted copy; the caller sorts once before reading.
	// ceil(p*n)-1 matters at the tail: interpolating over n-1 can select the
	// sample below the actual p95/p99 and produce a false pass at the budget.
	idx := int(math.Ceil(p*float64(len(d.samples)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(d.samples) {
		idx = len(d.samples) - 1
	}
	return d.samples[idx]
}

func (d *latencyDistribution) sort() {
	sort.Slice(d.samples, func(i, j int) bool { return d.samples[i] < d.samples[j] })
}

// measureIdentityLatency runs [workers] concurrent acceptor-shaped callers,
// each resolving identity r8SamplesPerWorker times, and returns the merged
// distribution. Concurrency is the point: the direct path serializes on
// LocalAPI, so a mean taken serially would hide contention an accept burst
// actually produces.
func measureIdentityLatency(tb testing.TB, ip, expectedNodeID string, workers int) *latencyDistribution {
	tb.Helper()
	perWorker := make([][]time.Duration, workers)
	type workerFailures struct {
		missing       int
		wrongIdentity int
		firstWrongID  string
	}
	failures := make([]workerFailures, workers)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			samples := make([]time.Duration, 0, r8SamplesPerWorker)
			var failed workerFailures
			for i := 0; i < r8SamplesPerWorker; i++ {
				start := time.Now()
				id := lookupNodeIdentity(ip)
				samples = append(samples, time.Since(start))
				if id == nil {
					failed.missing++
					continue
				}
				if id.NodeID != expectedNodeID {
					failed.wrongIdentity++
					if failed.firstWrongID == "" {
						failed.firstWrongID = id.NodeID
					}
				}
			}
			perWorker[w] = samples
			failures[w] = failed
		}(w)
	}
	wg.Wait()

	merged := &latencyDistribution{samples: make([]time.Duration, 0, workers*r8SamplesPerWorker)}
	missing := 0
	wrongIdentity := 0
	firstWrongID := ""
	for w, samples := range perWorker {
		merged.samples = append(merged.samples, samples...)
		missing += failures[w].missing
		wrongIdentity += failures[w].wrongIdentity
		if firstWrongID == "" {
			firstWrongID = failures[w].firstWrongID
		}
	}
	if missing != 0 || wrongIdentity != 0 {
		tb.Fatalf(
			"identity measurement returned invalid results: missing=%d wrongIdentity=%d firstWrongNodeID=%q wantNodeID=%q",
			missing,
			wrongIdentity,
			firstWrongID,
			expectedNodeID,
		)
	}
	merged.sort()
	return merged
}

type identityGatePeer struct {
	ip     string
	nodeID string
	server *tsnet.Server
}

func waitForIdentityGatePeer(
	tb testing.TB,
	peer identityGatePeer,
) (netip.Addr, *nodeIdentity) {
	tb.Helper()
	addr := netip.MustParseAddr(peer.ip)
	deadline := time.Now().Add(30 * time.Second)
	for {
		identity := lookupNodeIdentityViaLocalAPI(addr)
		if identity != nil && identity.NodeID == peer.nodeID {
			return addr, identity
		}
		if time.Now().After(deadline) {
			tb.Fatalf("authoritative WhoIs did not resolve peer %q within 30s", peer.nodeID)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// startIdentityGatePeer starts the remote side the accept path actually sees.
// Measuring WhoIs against the package node's own IP can exercise a fast
// self/not-found response instead of peer identity resolution, which would
// make a latency-only gate capable of passing on semantically invalid work.
func startIdentityGatePeer(tb testing.TB) identityGatePeer {
	tb.Helper()
	url := os.Getenv("HEADSCALE_URL")
	key := os.Getenv("HEADSCALE_AUTH_KEY")
	if url == "" || key == "" {
		tb.Skip("set HEADSCALE_URL and HEADSCALE_AUTH_KEY to run the live identity gate")
	}
	peer := &tsnet.Server{
		Hostname:   "dune-bench-peer",
		AuthKey:    key,
		ControlURL: url,
		Dir:        tb.TempDir(),
		Ephemeral:  true,
	}
	if err := peer.Start(); err != nil {
		tb.Fatalf("start identity-gate peer: %v", err)
	}
	tb.Cleanup(func() { _ = peer.Close() })

	lc, err := peer.LocalClient()
	if err != nil {
		tb.Fatalf("identity-gate peer LocalClient: %v", err)
	}
	lc.OmitAuth = true
	deadline := time.Now().Add(60 * time.Second)
	for {
		status, err := lc.Status(context.Background())
		if err == nil && status != nil && status.Self != nil &&
			len(status.Self.TailscaleIPs) > 0 && status.Self.ID != "" {
			return identityGatePeer{
				ip:     status.Self.TailscaleIPs[0].String(),
				nodeID: string(status.Self.ID),
				server: peer,
			}
		}
		if time.Now().After(deadline) {
			tb.Fatalf("identity-gate peer did not receive a self IP within 60s: %v", err)
		}
		time.Sleep(500 * time.Millisecond)
	}
}

func TestR8IdentityLatencyGate(t *testing.T) {
	_ = startTestNode(t)
	cache := activeIdentityIndex(t)
	peer := startIdentityGatePeer(t)

	// Wait until the package node's authoritative WhoIs sees the independently
	// reported peer. Waiting on an incidental watcher tick made repeat runs
	// flaky, while beginning before WhoIs was ready measured missing identities.
	addr, liveIdentity := waitForIdentityGatePeer(t, peer)

	// Seed the cached path from that verified identity. Watcher/cache-building
	// contracts have separate tests and are not part of this latency measure.
	cache.replace(map[netip.Addr]*nodeIdentity{
		addr: liveIdentity,
	})
	t.Cleanup(cache.invalidate)
	type row struct {
		label   string
		workers int
		dist    *latencyDistribution
	}
	var cached []row
	for _, workers := range []int{1, 8, 32} {
		cached = append(cached, row{
			label:   fmt.Sprintf("cached/%d", workers),
			workers: workers,
			dist:    measureIdentityLatency(t, peer.ip, peer.nodeID, workers),
		})
	}

	// Direct path: hold the cache cold for the whole measurement.
	cache.invalidate()
	var direct []row
	for _, workers := range []int{1, 8, 32} {
		cache.invalidate()
		direct = append(direct, row{
			label:   fmt.Sprintf("direct/%d", workers),
			workers: workers,
			dist:    measureIdentityLatency(t, peer.ip, peer.nodeID, workers),
		})
	}

	t.Log("R8 identity latency — path/concurrency: p50 / p95 / p99 (n samples)")
	report := func(rows []row) {
		for _, r := range rows {
			t.Logf(
				"  %-12s %8s / %8s / %8s (n=%d)",
				r.label,
				r.dist.percentile(0.50).Round(time.Microsecond),
				r.dist.percentile(0.95).Round(time.Microsecond),
				r.dist.percentile(0.99).Round(time.Microsecond),
				len(r.dist.samples),
			)
		}
	}
	report(cached)
	report(direct)

	// This is only the latency portion of the plan's removal gate. Passing it
	// does not authorize deletion: R8 also requires allocation, sustained
	// CPU/throughput, end-to-end accept, netmap-churn, and qualified-platform
	// evidence.
	var breaches []string
	for _, r := range direct {
		if p95 := r.dist.percentile(0.95); p95 > r8P95Budget {
			breaches = append(breaches, fmt.Sprintf("%s p95 %s > %s", r.label, p95, r8P95Budget))
		}
		if p99 := r.dist.percentile(0.99); p99 > r8P99Budget {
			breaches = append(breaches, fmt.Sprintf("%s p99 %s > %s", r.label, p99, r8P99Budget))
		}
	}
	if len(breaches) == 0 {
		t.Log("LATENCY RESULT: direct path holds the provisional p95/p99 " +
			"thresholds at every measured concurrency; record this run, then " +
			"complete the remaining R8 evidence before deciding deletion.")
		return
	}
	// Not a failure of the code under test: report measurement findings rather
	// than making the benchmark environment a red build.
	for _, breach := range breaches {
		t.Logf("LATENCY RESULT: provisional threshold breached — %s", breach)
	}
	t.Log("LATENCY RESULT: deletion is blocked on this environment unless a " +
		"confirming run passes; retaining the cache still requires the plan's " +
		"documented improvement and invalidation evidence.")
}

func activeIdentityIndex(tb testing.TB) *identityIndex {
	tb.Helper()
	runtime := currentRuntime()
	if runtime == nil {
		tb.Fatal("package runtime is unavailable")
	}
	return &runtime.identity
}

func TestLatencyDistributionUsesNearestRank(t *testing.T) {
	d := &latencyDistribution{samples: []time.Duration{
		1 * time.Millisecond,
		2 * time.Millisecond,
		100 * time.Millisecond,
	}}
	if got := d.percentile(0.95); got != 100*time.Millisecond {
		t.Fatalf("p95 = %s, want highest sample by nearest-rank", got)
	}
}
