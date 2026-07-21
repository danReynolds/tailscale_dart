//go:build !windows

package tailscale

import (
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// rstTCPPair builds a connected loopback TCP pair and returns (local, peer).
// TCP (not a unix socketpair) because only TCP can generate a genuine RST —
// SO_LINGER{on,0} + close on the peer aborts the connection instead of a
// graceful FIN, which is what drives the poller's error path.
func rstTCPPair(t *testing.T) (local, peer int) {
	t.Helper()
	lfd, err := unix.Socket(unix.AF_INET, unix.SOCK_STREAM, 0)
	if err != nil {
		t.Fatalf("listen socket: %v", err)
	}
	defer unix.Close(lfd)
	addr := &unix.SockaddrInet4{Addr: [4]byte{127, 0, 0, 1}}
	if err := unix.Bind(lfd, addr); err != nil {
		t.Fatalf("bind: %v", err)
	}
	if err := unix.Listen(lfd, 1); err != nil {
		t.Fatalf("listen: %v", err)
	}
	bound, err := unix.Getsockname(lfd)
	if err != nil {
		t.Fatalf("getsockname: %v", err)
	}
	cfd, err := unix.Socket(unix.AF_INET, unix.SOCK_STREAM, 0)
	if err != nil {
		t.Fatalf("connect socket: %v", err)
	}
	if err := unix.Connect(cfd, bound.(*unix.SockaddrInet4)); err != nil {
		unix.Close(cfd)
		t.Fatalf("connect: %v", err)
	}
	afd, _, err := unix.Accept(lfd)
	if err != nil {
		unix.Close(cfd)
		t.Fatalf("accept: %v", err)
	}
	return cfd, afd
}

// resetPeer arms SO_LINGER{on,0} and closes, sending an RST instead of a FIN.
func resetPeer(t *testing.T, fd int) {
	t.Helper()
	if err := unix.SetsockoptLinger(fd, unix.SOL_SOCKET, unix.SO_LINGER,
		&unix.Linger{Onoff: 1, Linger: 0}); err != nil {
		t.Fatalf("SO_LINGER: %v", err)
	}
	if err := unix.Close(fd); err != nil {
		t.Fatalf("close peer: %v", err)
	}
}

// waitForFlags polls until an event for [id] carrying any of [want] arrives,
// returning its full flag set, or fails the test after ~2s.
func waitForFlags(t *testing.T, p reactorPoller, id int64, want int32) int32 {
	t.Helper()
	out := make([]ReactorEvent, 8)
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		n, err := p.Wait(out, 100)
		if err != nil {
			t.Fatalf("wait: %v", err)
		}
		for i := 0; i < n; i++ {
			if out[i].ID == id && out[i].Events&want != 0 {
				return out[i].Events
			}
		}
	}
	t.Fatalf("no event with flags %#x for id %d within deadline", want, id)
	return 0
}
