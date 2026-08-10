//go:build !windows

package tailscale

import (
	"net"
	"runtime"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/sys/unix"
	"tailscale.com/tsnet"
)

// TestUdpBindingIDsNeverDisplace locks in why the registry is keyed by a
// monotonic binding id and not the Dart-side fd: ids never collide, so two
// live bridges — even ones whose socketpairs reused the same OS fd number —
// coexist in the registry and close independently. (The fd-keyed design
// required displacement-reaping logic for exactly this case; the id key makes
// the whole class unrepresentable.)
func TestUdpBindingIDsNeverDisplace(t *testing.T) {
	withLiveServer(t, &tsnet.Server{})
	var firstClosed atomic.Bool
	id1 := atomic.AddInt64(&udpBindingID, 1)
	first := &udpBridge{}
	first.closeFn = func() {
		firstClosed.Store(true)
		deregisterUdpBridge(id1, first)
	}
	if !registerUdpBridge(liveGate(t), id1, first) {
		t.Fatal("live registration must be accepted")
	}

	id2 := atomic.AddInt64(&udpBindingID, 1)
	second := &udpBridge{}
	second.closeFn = func() { deregisterUdpBridge(id2, second) }
	if !registerUdpBridge(liveGate(t), id2, second) {
		t.Fatal("live registration must be accepted")
	}

	if firstClosed.Load() {
		t.Fatal("a new binding must not disturb an existing one")
	}
	got1, _ := currentUdpBridges().get(id1)
	got2, _ := currentUdpBridges().get(id2)
	both := got1 == first && got2 == second
	if !both {
		t.Fatal("both bindings must coexist in the registry")
	}

	UdpCloseBinding(id1)
	if !firstClosed.Load() {
		t.Fatal("UdpCloseBinding must close the addressed bridge")
	}
	kept, _ := currentUdpBridges().get(id2)
	_, gonePresent := currentUdpBridges().get(id1)
	remaining := kept == second && !gonePresent
	if !remaining {
		t.Fatal("closing one binding must not affect the other")
	}
	UdpCloseBinding(id2)
}

// TestRegisterUdpBridgeRefusesStaleGate: a registration whose lifecycle ended
// must be refused without touching the registry.
func TestRegisterUdpBridgeRefusesStaleGate(t *testing.T) {
	withLiveServer(t, &tsnet.Server{})
	stale := liveGate(t)
	nodeEpoch.Add(1)

	id := atomic.AddInt64(&udpBindingID, 1)
	bridge := &udpBridge{}
	bridge.closeFn = func() { deregisterUdpBridge(id, bridge) }
	if registerUdpBridge(stale, id, bridge) {
		t.Fatal("a stale gate must be refused at the commit point")
	}
	_, present := currentUdpBridges().get(id)
	if present {
		t.Fatal("a refused registration must not land in the registry")
	}
}

// TestDgramRawReadBlocksAfterPeerClose documents why the UDP bridge needs an
// explicit close: a raw blocking read on the Go end of a datagram socketpair is
// NOT woken when the Dart end is shut down + closed (unlike a stream socket).
// This is the leak the netpoller-wrapped conn + UdpCloseBinding path fixes.
func TestDgramRawReadBlocksAfterPeerClose(t *testing.T) {
	dartFd, goFd, err := newSocketPairCloexec(unix.SOCK_DGRAM)
	if err != nil {
		t.Fatalf("socketpair: %v", err)
	}
	defer unix.Close(goFd)

	woke := make(chan struct{})
	go func() {
		buf := make([]byte, 2048)
		_, _ = unix.Read(goFd, buf)
		close(woke)
	}()
	time.Sleep(100 * time.Millisecond)
	_ = unix.Shutdown(dartFd, unix.SHUT_RDWR)
	_ = unix.Close(dartFd)

	select {
	case <-woke:
		t.Fatal("raw datagram read woke on peer close — leak assumption is wrong")
	case <-time.After(500 * time.Millisecond):
		// Expected: a raw read stays parked, which is why an explicit close is
		// required to reclaim the goroutine.
	}
}

// TestDgramPollerCloseUnblocksRead is the mechanism the fix relies on: closing
// a netpoller-integrated conn DOES unblock a parked read, so UdpCloseBinding can
// reclaim the outbound goroutine.
func TestDgramPollerCloseUnblocksRead(t *testing.T) {
	dartFd, goConn := newTestDgramConn(t)
	defer unix.Close(dartFd)

	woke := make(chan error, 1)
	go func() {
		buf := make([]byte, 2048)
		_, err := goConn.Read(buf)
		woke <- err
	}()
	time.Sleep(100 * time.Millisecond)
	_ = goConn.Close()

	select {
	case <-woke:
		// Expected: close unblocked the read.
	case <-time.After(1 * time.Second):
		t.Fatal("conn.Close did not unblock a parked datagram read")
	}
}

// TestUdpBridgeCloseReleasesResources is the M1 regression: UdpCloseBinding must
// deregister the bridge, close the tsnet PacketConn (freeing the port), and let
// both bridge goroutines exit — including the outbound one parked in Read.
func TestUdpBridgeCloseReleasesResources(t *testing.T) {
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen packet: %v", err)
	}
	dartFd, goConn, err := newDatagramSocketPairConn()
	if err != nil {
		t.Fatalf("socketpair conn: %v", err)
	}
	defer unix.Close(dartFd)

	withLiveServer(t, &tsnet.Server{})
	base := runtime.NumGoroutine()
	id := atomic.AddInt64(&udpBindingID, 1)
	if err := runUdpFdBridge(liveGate(t), id, goConn, pc); err != nil {
		t.Fatalf("live bridge registration: %v", err)
	}

	_, registered := currentUdpBridges().get(id)
	if !registered {
		t.Fatal("bridge was not registered")
	}
	waitGoroutineCount(t, base+2, time.Second, "bridge goroutines did not start")

	UdpCloseBinding(id)

	_, stillRegistered := currentUdpBridges().get(id)
	if stillRegistered {
		t.Error("bridge still registered after UdpCloseBinding")
	}
	if _, err := pc.WriteTo([]byte("x"), &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 9}); err == nil {
		t.Error("PacketConn still usable after close (port not released)")
	}
	// The key assertion: both goroutines exit, i.e. the outbound Read was
	// unblocked by the conn close (a raw datagram read would stay parked here).
	waitGoroutineCount(t, base, 2*time.Second, "bridge goroutines leaked after close")
}

// TestCloseAllUdpBindingsTearsDownEveryBridge covers the Stop() path.
func TestCloseAllUdpBindingsTearsDownEveryBridge(t *testing.T) {
	withLiveServer(t, &tsnet.Server{})
	const n = 3
	fds := make([]int, 0, n)
	for i := 0; i < n; i++ {
		pc, err := net.ListenPacket("udp", "127.0.0.1:0")
		if err != nil {
			t.Fatalf("listen packet: %v", err)
		}
		dartFd, goConn, err := newDatagramSocketPairConn()
		if err != nil {
			t.Fatalf("socketpair conn: %v", err)
		}
		fds = append(fds, dartFd)
		if err := runUdpFdBridge(liveGate(t), atomic.AddInt64(&udpBindingID, 1), goConn, pc); err != nil {
			t.Fatalf("live bridge registration: %v", err)
		}
	}
	defer func() {
		for _, fd := range fds {
			unix.Close(fd)
		}
	}()

	runtime := currentRuntime()
	runtime.fd.closeAll()

	if remaining := runtime.fd.udpBridges.size(); remaining != 0 {
		t.Fatalf("registry still holds %d bridges after the runtime sweep", remaining)
	}
}

func newTestDgramConn(t *testing.T) (int, net.Conn) {
	t.Helper()
	dartFd, goConn, err := newDatagramSocketPairConn()
	if err != nil {
		t.Fatalf("socketpair conn: %v", err)
	}
	return dartFd, goConn
}

func waitGoroutineCount(t *testing.T, target int, d time.Duration, msg string) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if runtime.NumGoroutine() <= target {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("%s: goroutine count %d did not settle to %d within %v",
		msg, runtime.NumGoroutine(), target, d)
}
