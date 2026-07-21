//go:build !windows

package tailscale

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"tailscale.com/tsnet"
)

// countingTransport builds an *http.Transport whose dials are counted, so tests
// can assert exactly when a new tailnet connection would be established.
func countingTransport(dials *atomic.Int64) *http.Transport {
	return &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			dials.Add(1)
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		},
	}
}

func getOK(t *testing.T, tr *http.Transport, url string) {
	t.Helper()
	resp, err := (&http.Client{Transport: tr}).Get(url)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
}

// TestHttpTransportCache_ReusesWithinSameOwner is the win: successive requests
// under the same identity share one connection (one dial).
func TestHttpTransportCache_ReusesWithinSameOwner(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()

	var dials atomic.Int64
	var cache httpTransportCache
	owner := new(int) // stands in for a *tsnet.Server identity

	for i := 0; i < 3; i++ {
		getOK(t, cache.get(owner, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	}
	if got := dials.Load(); got != 1 {
		t.Fatalf("same-identity requests should reuse one connection: got %d dials, want 1", got)
	}
}

// TestHttpTransportCache_NoReuseAcrossIdentityChange is the load-bearing
// security boundary: after the owner (identity) changes, a request must NOT be
// served by the previous identity's pooled connection — it must dial fresh.
func TestHttpTransportCache_NoReuseAcrossIdentityChange(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()

	var dials atomic.Int64
	var cache httpTransportCache
	identityA := new(int)
	identityB := new(int)

	// Warm identity A's pool.
	getOK(t, cache.get(identityA, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	getOK(t, cache.get(identityA, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	if got := dials.Load(); got != 1 {
		t.Fatalf("identity A should have reused: got %d dials, want 1", got)
	}

	// Switch identity. The prior connection must not be reused.
	getOK(t, cache.get(identityB, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	if got := dials.Load(); got != 2 {
		t.Fatalf("identity change must force a fresh connection (not reuse A's): got %d dials, want 2", got)
	}

	// And identity B keeps its own reusable pool.
	getOK(t, cache.get(identityB, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	if got := dials.Load(); got != 2 {
		t.Fatalf("identity B should reuse its own connection: got %d dials, want 2", got)
	}
}

// TestHttpTransportCache_ResetForcesFreshConnection covers node teardown: after
// reset() (called from stopLocked), the next request must dial anew.
func TestHttpTransportCache_ResetForcesFreshConnection(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()

	var dials atomic.Int64
	var cache httpTransportCache
	owner := new(int)

	getOK(t, cache.get(owner, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	getOK(t, cache.get(owner, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	if got := dials.Load(); got != 1 {
		t.Fatalf("pre-reset reuse: got %d dials, want 1", got)
	}

	cache.reset() // node stopped

	// Even with the same owner value, a fresh transport must be built.
	getOK(t, cache.get(owner, func() *http.Transport { return countingTransport(&dials) }), server.URL)
	if got := dials.Load(); got != 2 {
		t.Fatalf("post-reset request must dial fresh: got %d dials, want 2", got)
	}
}

// TestHttpTransportCache_CrossHostIsolation confirms a pooled connection to one
// host is never handed to a request for a different host.
func TestHttpTransportCache_CrossHostIsolation(t *testing.T) {
	hostA := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("a"))
	}))
	defer hostA.Close()
	hostB := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("b"))
	}))
	defer hostB.Close()

	var dials atomic.Int64
	var cache httpTransportCache
	owner := new(int)
	build := func() *http.Transport { return countingTransport(&dials) }

	// Same identity, two different hosts: two separate connections.
	getOK(t, cache.get(owner, build), hostA.URL)
	getOK(t, cache.get(owner, build), hostB.URL)
	if got := dials.Load(); got != 2 {
		t.Fatalf("distinct hosts must use distinct connections: got %d dials, want 2", got)
	}
	// Re-hitting each host reuses its own connection (no extra dials).
	getOK(t, cache.get(owner, build), hostA.URL)
	getOK(t, cache.get(owner, build), hostB.URL)
	if got := dials.Load(); got != 2 {
		t.Fatalf("per-host reuse: got %d dials, want 2", got)
	}
}

// cacheOwner reads the cache's current owner under its own lock (race-safe).
func cacheOwner(c *httpTransportCache) any {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.owner
}

// TestGetCurrent_CachesForLiveGate: a request under the live lifecycle
// populates the cache keyed to the gated server, and a second request reuses it
// (no rebuild).
func TestGetCurrent_CachesForLiveGate(t *testing.T) {
	liveServer := &tsnet.Server{}
	withLiveServer(t, liveServer)
	var cache httpTransportCache
	builds := 0
	build := func() *http.Transport { builds++; return &http.Transport{} }

	gate := liveGate(t)
	first, oneOff1 := cache.getCurrent(gate, build)
	second, oneOff2 := cache.getCurrent(gate, build)
	if first == nil || first != second {
		t.Fatalf("live gate must cache and reuse one transport (builds=%d)", builds)
	}
	if oneOff1 || oneOff2 {
		t.Fatal("live-gate transports must not be reported one-off")
	}
	if builds != 1 {
		t.Fatalf("expected exactly one build for repeated live requests, got %d", builds)
	}
	if owner := cacheOwner(&cache); owner != any(liveServer) {
		t.Fatalf("cache must be keyed to the gated server; owner=%v", owner)
	}
}

// TestGetCurrent_OneOffForStaleGate is the teardown-race lock-in: once the
// lifecycle ends (epoch bumped), a late request gets a one-off transport and
// must NOT touch the cache — neither populating an empty cache (re-caching a
// dead server pins its whole netstack graph behind the teardown sweep) nor
// evicting a newer lifecycle's entry.
func TestGetCurrent_OneOffForStaleGate(t *testing.T) {
	serverA := &tsnet.Server{}
	withLiveServer(t, serverA)
	var cache httpTransportCache

	staleGate := liveGate(t)
	nodeEpoch.Add(1) // teardown begins
	cache.reset()    // stopLocked's sweep

	// Stale request against the empty cache: one-off, cache stays empty.
	tr, oneOff := cache.getCurrent(staleGate, func() *http.Transport { return &http.Transport{} })
	if tr == nil {
		t.Fatal("stale gate must still get a one-off transport")
	}
	if !oneOff {
		t.Fatal("a stale-gate transport must be reported one-off so the caller closes its idle conns")
	}
	if owner := cacheOwner(&cache); owner != nil {
		t.Fatalf("stale gate must not repopulate the cache; owner=%v", owner)
	}

	// New lifecycle populates; a leftover stale request must not evict it.
	serverB := &tsnet.Server{}
	withLiveServer(t, serverB)
	fresh := liveGate(t)
	cached, _ := cache.getCurrent(fresh, func() *http.Transport { return &http.Transport{} })
	if tr, _ := cache.getCurrent(staleGate, func() *http.Transport { return &http.Transport{} }); tr == cached {
		t.Fatal("stale gate must not be served the new lifecycle's cached transport")
	}
	if owner := cacheOwner(&cache); owner != any(serverB) {
		t.Fatalf("stale gate must not disturb the new lifecycle's entry; owner=%v", owner)
	}
}
