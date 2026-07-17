//go:build !windows

package tailscale

import (
	"net"
	"runtime"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// TestDgramRawReadBlocksAfterPeerClose documents why the UDP bridge needs an
// explicit close: a raw blocking read on the Go end of a datagram socketpair is
// NOT woken when the Dart end is shut down + closed (unlike a stream socket).
// This is the leak the netpoller-wrapped conn + UdpCloseFd path fixes.
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
// a netpoller-integrated conn DOES unblock a parked read, so UdpCloseFd can
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

// TestUdpBridgeCloseReleasesResources is the M1 regression: UdpCloseFd must
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

	base := runtime.NumGoroutine()
	runUdpFdBridge(dartFd, goConn, pc)

	udpFdBindingMu.Lock()
	_, registered := udpFdBindingRegistry[dartFd]
	udpFdBindingMu.Unlock()
	if !registered {
		t.Fatal("bridge was not registered")
	}
	waitGoroutineCount(t, base+2, time.Second, "bridge goroutines did not start")

	UdpCloseFd(dartFd)

	udpFdBindingMu.Lock()
	_, stillRegistered := udpFdBindingRegistry[dartFd]
	udpFdBindingMu.Unlock()
	if stillRegistered {
		t.Error("bridge still registered after UdpCloseFd")
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
		runUdpFdBridge(dartFd, goConn, pc)
	}
	defer func() {
		for _, fd := range fds {
			unix.Close(fd)
		}
	}()

	closeAllUdpBindings()

	udpFdBindingMu.Lock()
	remaining := len(udpFdBindingRegistry)
	udpFdBindingMu.Unlock()
	if remaining != 0 {
		t.Fatalf("registry still holds %d bridges after closeAllUdpBindings", remaining)
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
