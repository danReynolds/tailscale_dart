//go:build !windows

package tailscale

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"golang.org/x/sys/unix"
	"tailscale.com/client/local"
	"tailscale.com/tsnet"
)

func newFakeTransport() *http.Transport { return &http.Transport{} }

// withLiveServer publishes [s] as the process-global live server for the test
// and restores the prior value afterward. Unit tests run with srv == nil.
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

// liveGate acquires a nodeGate against a fake live server, failing the test if
// no gate is available.
func liveGate(t *testing.T) nodeGate {
	t.Helper()
	gate, ok := acquireNodeGate()
	if !ok {
		t.Fatal("acquireNodeGate must succeed while a live server is published")
	}
	return gate
}

// bumpEpoch simulates the lifecycle transition stopLocked performs, without a
// full teardown (the per-registry sweeps are exercised separately).
func bumpEpoch() { nodeEpoch.Add(1) }

func TestAcquireNodeGate_RequiresLiveServer(t *testing.T) {
	if _, ok := acquireNodeGate(); ok {
		t.Fatal("acquireNodeGate must refuse when no server is running")
	}
	withLiveServer(t, &tsnet.Server{})
	gate := liveGate(t)
	if !gate.stillCurrent() {
		t.Fatal("a just-acquired gate must be current")
	}
}

func TestNodeGate_StaleAfterTeardown(t *testing.T) {
	withLiveServer(t, &tsnet.Server{})
	gate := liveGate(t)
	bumpEpoch()
	if gate.stillCurrent() {
		t.Fatal("a gate from before the epoch bump must be stale")
	}
}

// TestNodeGate_StaleAcrossTwoLifecycles is the hardening over the old boolean
// "stopping" latch: a latch is cleared by the next Start, so an op stuck across
// two lifecycles (gated under node N, N stops, N+1 starts) would pass the
// cleared latch and commit N-era state into N+1's world. An epoch compare
// refuses any later lifecycle, not just "currently stopping".
func TestNodeGate_StaleAcrossTwoLifecycles(t *testing.T) {
	withLiveServer(t, &tsnet.Server{})
	gate := liveGate(t)

	bumpEpoch()                          // node N stops
	withLiveServer(t, &tsnet.Server{})   // node N+1 starts (no epoch change)
	if fresh := liveGate(t); !fresh.stillCurrent() {
		t.Fatal("a gate acquired under the new lifecycle must be current")
	}
	if gate.stillCurrent() {
		t.Fatal("a gate from a previous lifecycle must stay stale after the next Start")
	}
}

// TestCommitGates_RefuseStaleAcrossRegistries is the table-driven teardown-race
// harness: every registry's commit point must refuse a stale gate and leave the
// registry empty, and accept a live gate. New registries should add a row.
func TestCommitGates_RefuseStaleAcrossRegistries(t *testing.T) {
	withLiveServer(t, &tsnet.Server{})

	cases := []struct {
		name string
		// register attempts the subsystem's real commit path with [gate];
		// returns whether the registration was accepted.
		register func(t *testing.T, gate nodeGate) bool
		// count reports the registry's live entries.
		count func() int
		// sweep runs the subsystem's real stopLocked teardown sweep.
		sweep func()
	}{
		{
			name: "tcp-listener",
			register: func(t *testing.T, gate nodeGate) bool {
				ln, err := net.Listen("tcp", "127.0.0.1:0")
				if err != nil {
					t.Fatalf("listen: %v", err)
				}
				reg, err := registerTcpFdListener(gate, ln, "127.0.0.1")
				if err != nil {
					return false // registerTcpFdListener closed ln
				}
				t.Cleanup(func() { TcpCloseFdListener(reg.ID) })
				return true
			},
			count: func() int {
				tcpFdListenerMu.Lock()
				defer tcpFdListenerMu.Unlock()
				return len(tcpFdListenerRegistry)
			},
			sweep: closeAllTcpFdListeners,
		},
		{
			name: "udp-bridge",
			register: func(t *testing.T, gate nodeGate) bool {
				pc, err := net.ListenPacket("udp", "127.0.0.1:0")
				if err != nil {
					t.Fatalf("listen packet: %v", err)
				}
				dartFd, goConn, err := newDatagramSocketPairConn()
				if err != nil {
					pc.Close()
					t.Fatalf("socketpair conn: %v", err)
				}
				id := atomic.AddInt64(&udpBindingID, 1)
				if err := runUdpFdBridge(gate, id, goConn, pc); err != nil {
					// The bridge closed pc and goConn on refusal; the Dart-side
					// fd is ours to close (mirrors UdpBindFd's refusal path).
					_ = unix.Close(dartFd)
					return false
				}
				t.Cleanup(func() {
					UdpCloseBinding(id)
					_ = unix.Close(dartFd)
				})
				return true
			},
			count: func() int {
				udpFdBindingMu.Lock()
				defer udpFdBindingMu.Unlock()
				return len(udpFdBindingRegistry)
			},
			sweep: closeAllUdpBindings,
		},
		{
			name: "http-transport-cache",
			register: func(t *testing.T, gate nodeGate) bool {
				tr, oneOff := tailnetHTTPTransports.getCurrent(gate, newFakeTransport)
				if tr == nil {
					t.Fatal("getCurrent must always return a transport")
				}
				// Accepted iff the cache is now keyed to MY gate's server —
				// "anything is cached" can't tell my registration from a
				// pre-existing entry for the same server.
				tailnetHTTPTransports.mu.Lock()
				accepted := tailnetHTTPTransports.owner == any(gate.s)
				tailnetHTTPTransports.mu.Unlock()
				if accepted && oneOff {
					t.Fatal("an accepted registration must not be reported one-off")
				}
				return accepted
			},
			count: func() int {
				tailnetHTTPTransports.mu.Lock()
				defer tailnetHTTPTransports.mu.Unlock()
				if tailnetHTTPTransports.transport != nil {
					return 1
				}
				return 0
			},
			sweep: func() { tailnetHTTPTransports.reset() },
		},
		{
			name: "funnel-forwarder",
			register: func(t *testing.T, gate nodeGate) bool {
				ln, err := net.Listen("tcp", "127.0.0.1:0")
				if err != nil {
					t.Fatalf("listen: %v", err)
				}
				_, err = installFunnelForwarder(gate, 8443, "harness.ts.net", ln, "/", funnelTarget{})
				// installFunnelForwarder closed ln on refusal.
				return err == nil
			},
			count: func() int {
				funnelMu.Lock()
				defer funnelMu.Unlock()
				return len(funnelForwarders)
			},
			sweep: closeAllFunnelForwarders,
		},
		{
			name: "http-binding",
			register: func(t *testing.T, gate nodeGate) bool {
				state := &httpBindingState{
					requests: make(chan *HttpIncomingRequest, 1),
					done:     make(chan struct{}),
				}
				return registerHttpBinding(gate, atomic.AddInt64(&httpBindingID, 1), state)
			},
			count: func() int {
				httpBindingMu.Lock()
				defer httpBindingMu.Unlock()
				return len(httpBindingRegistry)
			},
			sweep: closeAllHttpBindings,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Cleanup(tc.sweep)
			if base := tc.count(); base != 0 {
				t.Fatalf("registry not empty at test start: %d", base)
			}

			// Live gate: commit accepted.
			if ok := tc.register(t, liveGate(t)); !ok {
				t.Fatal("a live gate must be accepted at the commit point")
			}
			if got := tc.count(); got != 1 {
				t.Fatalf("live registration must land in the registry: count=%d", got)
			}

			// Teardown, in stopLocked's real order: an op is in flight (its
			// gate acquired), the epoch bumps, this registry is swept.
			gate := liveGate(t)
			bumpEpoch()
			tc.sweep()
			if got := tc.count(); got != 0 {
				t.Fatalf("the teardown sweep must drain the registry: count=%d", got)
			}

			// The in-flight op reaches its commit point late: refused, and the
			// registry stays empty — nothing repopulates behind the sweep.
			if ok := tc.register(t, gate); ok {
				t.Fatal("a stale gate must be refused at the commit point")
			}
			if got := tc.count(); got != 0 {
				t.Fatalf("a refused registration must not land behind the sweep: count=%d", got)
			}
		})
	}
}

// TestCommitGates_RaceWithTeardown stresses register-vs-teardown under -race.
// The invariant is checked IN the teardown loop, at the only moment it is
// decidable: right after bump+sweep while srv is still nil, any cache entry is
// a stale-gate commit that landed behind the sweep (no fresh gate can exist).
// Two distinct lifecycles' servers alternate so pointer confusion would also
// be observable.
func TestCommitGates_RaceWithTeardown(t *testing.T) {
	serverA := &tsnet.Server{}
	serverB := &tsnet.Server{}
	withLiveServer(t, serverA)

	var wg sync.WaitGroup
	stop := make(chan struct{})
	var leaks atomic.Int64

	// Fresh-gate registrars: acquire a gate per commit, the well-behaved path.
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				if gate, ok := acquireNodeGate(); ok {
					_, _ = tailnetHTTPTransports.getCurrent(gate, newFakeTransport)
				}
			}
		}()
	}
	// Gate-holder registrars: reuse one gate across a burst of commits, so
	// every teardown strands them mid-burst with a stale gate — the actual
	// adversary the epoch refuses. (Fresh-gate registrars alone are stale only
	// in the instruction-scale window between acquire and commit, which a
	// broken guard survives for the whole run.)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				gate, ok := acquireNodeGate()
				if !ok {
					continue
				}
				for j := 0; j < 512; j++ {
					_, _ = tailnetHTTPTransports.getCurrent(gate, newFakeTransport)
				}
			}
		}()
	}

	// Teardown/Start loop: bump, CHECK owners, sweep, CHECK empty, alternate
	// the live server. Two discriminating assertions (an end-state check after
	// all writers stop is vacuous — reset() trivially empties an uncontended
	// cache):
	//
	//  1. Pre-sweep, the cache may only be owned by the lifecycle being
	//     retired: a stale gate from an EARLIER lifecycle that committed during
	//     this one leaves the other server as owner, observable for the whole
	//     lifecycle, not just a race window.
	//  2. Post-sweep, while srv is still nil, no registrar can acquire a fresh
	//     gate, so ANY entry is a stale-gate commit that landed behind the
	//     sweep — the exact race the epoch closes.
	//
	// With stillCurrent disabled the gate-holder registrars trip these within
	// a few iterations; with it working, never.
	wg.Add(1)
	go func() {
		defer wg.Done()
		current := serverA
		next := serverB
		for i := 0; i < 400; i++ {
			mu.Lock()
			nodeEpoch.Add(1)
			srv = nil
			mu.Unlock()
			tailnetHTTPTransports.mu.Lock()
			if o := tailnetHTTPTransports.owner; o != nil && o != any(current) {
				leaks.Add(1) // cross-lifecycle commit (check 1)
			}
			tailnetHTTPTransports.mu.Unlock()
			tailnetHTTPTransports.reset()
			tailnetHTTPTransports.mu.Lock()
			if tailnetHTTPTransports.transport != nil {
				leaks.Add(1) // landed behind the sweep (check 2)
			}
			tailnetHTTPTransports.mu.Unlock()
			mu.Lock()
			srv = next
			mu.Unlock()
			current, next = next, current
		}
		close(stop)
	}()

	wg.Wait()
	if got := leaks.Load(); got != 0 {
		t.Fatalf("%d stale-gate commits landed behind a teardown sweep", got)
	}

	// Final teardown: after this, nothing may remain cached.
	mu.Lock()
	nodeEpoch.Add(1)
	srv = nil
	mu.Unlock()
	tailnetHTTPTransports.reset()

	tailnetHTTPTransports.mu.Lock()
	leaked := tailnetHTTPTransports.transport != nil
	owner := tailnetHTTPTransports.owner
	tailnetHTTPTransports.mu.Unlock()
	if leaked {
		t.Fatalf("transport cache must be empty after the final sweep; owner=%v", owner)
	}
}

// TestServeForwardLocked_RefusesStaleGate covers the Serve row of the commit-
// gate matrix (the F2 re-exposure class): serveForwardLocked's gate check
// precedes every LocalAPI call, so a stale gate must refuse before touching
// the client — driven here with a client aimed at a nonexistent socket, which
// fails loudly (a different error) if the gate is broken and the LocalAPI path
// is reached — and must leave the publication registry empty.
func TestServeForwardLocked_RefusesStaleGate(t *testing.T) {
	withLiveServer(t, &tsnet.Server{})
	gate := liveGate(t)
	bumpEpoch()

	lc := &local.Client{Socket: "/nonexistent/tailscaled.sock", UseSocketOnly: true}
	out := serveForwardLocked(gate, lc, serveForwardPayload{
		TailnetPort: 443,
		LocalPort:   8080,
		Path:        "/",
	})
	if !strings.Contains(out, "raced node teardown") {
		t.Fatalf("stale gate must refuse at the commit gate, got %s", out)
	}
	servePublicationMu.Lock()
	tracked := len(servePublications)
	servePublicationMu.Unlock()
	if tracked != 0 {
		t.Fatalf("refused forward must not track a publication, %d present", tracked)
	}
}

// TestDebugNodeState smoke-checks the census used by leak diagnostics.
func TestDebugNodeState(t *testing.T) {
	snap := debugNodeState()
	if snap.Epoch != nodeEpoch.Load() {
		t.Fatalf("census epoch %d != live epoch %d", snap.Epoch, nodeEpoch.Load())
	}
}
