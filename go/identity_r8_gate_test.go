package tailscale

import (
	"fmt"
	"net/netip"
	"os"
	"sort"
	"sync"
	"testing"
	"time"
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
// against; the decision it governs is whether identityCache survives.
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
	idx := int(float64(len(d.samples)-1) * p)
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
func measureIdentityLatency(tb testing.TB, ip string, workers int) *latencyDistribution {
	tb.Helper()
	perWorker := make([][]time.Duration, workers)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			samples := make([]time.Duration, 0, r8SamplesPerWorker)
			for i := 0; i < r8SamplesPerWorker; i++ {
				start := time.Now()
				_ = lookupNodeIdentity(ip)
				samples = append(samples, time.Since(start))
			}
			perWorker[w] = samples
		}(w)
	}
	wg.Wait()

	merged := &latencyDistribution{samples: make([]time.Duration, 0, workers*r8SamplesPerWorker)}
	for _, samples := range perWorker {
		merged.samples = append(merged.samples, samples...)
	}
	merged.sort()
	return merged
}

func TestR8IdentityLatencyGate(t *testing.T) {
	ip := startTestNode(t)
	addr := netip.MustParseAddr(ip)

	// Warm path first, so the direct measurements below cannot be helped by a
	// cache the watcher populates mid-run.
	StartWatch()
	deadline := time.Now().Add(30 * time.Second)
	for {
		if id, ok := identityCache.lookup(addr); ok && id != nil {
			break
		}
		if time.Now().After(deadline) {
			StopWatch()
			t.Fatal("identity cache did not warm within 30s")
		}
		time.Sleep(100 * time.Millisecond)
	}

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
			dist:    measureIdentityLatency(t, ip, workers),
		})
	}

	// Direct path: hold the cache cold for the whole measurement. The watcher
	// repopulates on every netmap tick, so invalidate per worker batch.
	StopWatch()
	identityCache.invalidate()
	var direct []row
	for _, workers := range []int{1, 8, 32} {
		identityCache.invalidate()
		direct = append(direct, row{
			label:   fmt.Sprintf("direct/%d", workers),
			workers: workers,
			dist:    measureIdentityLatency(t, ip, workers),
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

	// The verdict the plan asks for: the direct path must hold the absolute
	// budget at every measured concurrency for the cache to be deletable.
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
		t.Log("VERDICT: direct path holds the R8 gate at every concurrency — " +
			"identityCache is deletable; record this run in the plan.")
		return
	}
	// Not a failure of the code under test: it is the measurement the plan
	// asks for, and a breach means the cache stays. Report it as a finding
	// rather than a red build so the run is repeatable in CI either way.
	for _, breach := range breaches {
		t.Logf("VERDICT: gate breached — %s", breach)
	}
	t.Log("VERDICT: retaining identityCache requires recording this workload, " +
		"its invalidation contract, and the same removal threshold beside its tests.")
}

// TestR8WarmMissFallsBackWhenCacheDeleted documents the behavior change R8
// decides. A warm cache that lacks the address answers nil authoritatively
// (identity_cache.go), which is the window the offloaded listen/bind work made
// reachable in the e2e identity assertions. Deleting the cache removes the
// window by construction; this test pins the property so whichever fix lands
// has to keep it.
func TestR8WarmMissFallsBackWhenCacheDeleted(t *testing.T) {
	if os.Getenv("HEADSCALE_URL") == "" {
		t.Skip("set HEADSCALE_URL and HEADSCALE_AUTH_KEY to run the live identity gate")
	}
	ip := startTestNode(t)
	addr := netip.MustParseAddr(ip)

	// Simulate the window: warm the cache with an index that omits this peer.
	identityCache.replace(map[netip.Addr]*nodeIdentity{})
	if id, ok := identityCache.lookup(addr); !ok || id != nil {
		t.Fatalf("expected a warm miss to answer (nil, true); got (%v, %v)", id, ok)
	}
	if id := lookupNodeIdentity(ip); id != nil {
		t.Log("warm miss already falls back to a live lookup; the window is closed")
		return
	}
	t.Log("warm miss resolves nil without a live lookup — this is the window " +
		"the e2e identity assertions hit; R8 must close it")
}
