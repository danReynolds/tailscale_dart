//go:build !windows

package tailscale

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
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

// withLiveServer publishes [s] as the process-global live server for the test and
// restores the prior value afterward. Unit tests run with srv == nil.
func withLiveServer(t *testing.T, s *tsnet.Server) {
	t.Helper()
	mu.Lock()
	prev := srv
	srv = s
	mu.Unlock()
	t.Cleanup(func() {
		mu.Lock()
		srv = prev
		mu.Unlock()
	})
}

// TestCachedTransportForLiveServer_HoldsMuAcrossPopulate is the F3 TOCTOU
// regression. The fix makes the srv liveness check atomic with populating the
// cache by holding mu across both. We assert that directly from inside the build
// callback: when the cache populates, mu must already be held (TryLock fails).
// Without the fix — which released mu before the populate — TryLock here would
// succeed, which is exactly the window a concurrent Stop() slipped through to
// leave a dead server cached.
func TestCachedTransportForLiveServer_HoldsMuAcrossPopulate(t *testing.T) {
	liveServer := &tsnet.Server{}
	var cache httpTransportCache
	muHeldDuringPopulate := false
	build := func(_ *tsnet.Server) *http.Transport {
		if mu.TryLock() {
			mu.Unlock() // mu was free: the check and the populate are NOT atomic.
		} else {
			muHeldDuringPopulate = true
		}
		return &http.Transport{}
	}

	withLiveServer(t, liveServer)

	_ = cachedTransportForLiveServer(&cache, liveServer, build)
	if !muHeldDuringPopulate {
		t.Fatal("mu must be held across the cache populate so the liveness check is atomic with it")
	}
}

// TestCachedTransportForLiveServer_SkipsCacheForDeadServer locks in the liveness
// gate: a request whose server is no longer the live srv gets a one-off transport
// and must NOT populate the shared cache (which would pin the dead server's whole
// netstack graph until the next up()+request).
func TestCachedTransportForLiveServer_SkipsCacheForDeadServer(t *testing.T) {
	liveServer := &tsnet.Server{}
	var cache httpTransportCache
	var dials atomic.Int64
	build := func(_ *tsnet.Server) *http.Transport { return countingTransport(&dials) }

	withLiveServer(t, liveServer)

	// Live server populates the cache.
	if got := cachedTransportForLiveServer(&cache, liveServer, build); got == nil {
		t.Fatal("live server must return a transport")
	}
	if owner := cacheOwner(&cache); owner != any(liveServer) {
		t.Fatalf("live server must populate the cache; owner=%v", owner)
	}

	// Node stops: cache reset and srv moves off liveServer, as stopLocked does.
	cache.reset()
	mu.Lock()
	srv = nil
	mu.Unlock()

	// A late request for the now-dead server must return a one-off and leave the
	// cache empty.
	if got := cachedTransportForLiveServer(&cache, liveServer, build); got == nil {
		t.Fatal("dead server must still return a one-off transport")
	}
	if owner := cacheOwner(&cache); owner != nil {
		t.Fatalf("dead server must not repopulate the cache (the TOCTOU leak): owner=%v", owner)
	}
}

// TestCachedTransportForLiveServer_RaceWithStop stresses the liveness gate
// against concurrent Stop()/Start()-style cache resets and srv flips. All srv
// access is under mu, as in production, so -race proves the check-and-cache path
// is synchronized with teardown, and the cache never ends up owning a server that
// isn't the live one.
func TestCachedTransportForLiveServer_RaceWithStop(t *testing.T) {
	liveServer := &tsnet.Server{}
	var cache httpTransportCache
	var dials atomic.Int64
	build := func(_ *tsnet.Server) *http.Transport { return countingTransport(&dials) }

	withLiveServer(t, liveServer)

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 300; j++ {
				_ = cachedTransportForLiveServer(&cache, liveServer, build)
			}
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		for j := 0; j < 300; j++ {
			mu.Lock()
			srv = nil
			mu.Unlock()
			cache.reset()
			mu.Lock()
			srv = liveServer
			mu.Unlock()
		}
	}()
	wg.Wait()

	// The cache must own nil or the live server, never a stale third value.
	if owner := cacheOwner(&cache); owner != nil && owner != any(liveServer) {
		t.Fatalf("cache owner must be nil or the live server, got %v", owner)
	}
}
