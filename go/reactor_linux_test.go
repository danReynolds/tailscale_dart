//go:build !windows && (linux || android)

package tailscale

import (
	"testing"

	"golang.org/x/sys/unix"
)

// TestEpollInterestFlags pins the RDHUP-masking contract: EPOLLRDHUP is armed
// only alongside read interest, while EPOLLERR/EPOLLHUP are always present
// (they are unmaskable in epoll).
func TestEpollInterestFlags(t *testing.T) {
	const alwaysOn = uint32(unix.EPOLLERR | unix.EPOLLHUP)

	writeOnly := epollInterestFlags(ReactorEventWrite)
	if writeOnly&unix.EPOLLRDHUP != 0 {
		t.Error("EPOLLRDHUP armed without read interest — would spin on peer half-close")
	}
	if writeOnly&unix.EPOLLIN != 0 {
		t.Error("EPOLLIN armed without read interest")
	}
	if writeOnly&unix.EPOLLOUT == 0 {
		t.Error("EPOLLOUT missing with write interest")
	}
	if writeOnly&alwaysOn != alwaysOn {
		t.Error("EPOLLERR|EPOLLHUP must always be present")
	}

	none := epollInterestFlags(0)
	if none&(unix.EPOLLIN|unix.EPOLLOUT|unix.EPOLLRDHUP) != 0 {
		t.Errorf("zero interest should arm only ERR|HUP, got %#x", none)
	}
	if none&alwaysOn != alwaysOn {
		t.Error("EPOLLERR|EPOLLHUP must always be present even at zero interest")
	}

	readOnly := epollInterestFlags(ReactorEventRead)
	if readOnly&unix.EPOLLIN == 0 || readOnly&unix.EPOLLRDHUP == 0 {
		t.Error("read interest must arm both EPOLLIN and EPOLLRDHUP")
	}
}

// TestEpollHalfCloseDoesNotSpinWhenReadDisabled is the M2 regression: with
// reads disabled, a peer half-close (FIN → EPOLLRDHUP) must NOT be reported, so
// epoll_wait blocks instead of returning immediately forever.
func TestEpollHalfCloseDoesNotSpinWhenReadDisabled(t *testing.T) {
	p, err := newReactorPoller()
	if err != nil {
		t.Fatalf("newReactorPoller: %v", err)
	}
	defer p.Close()

	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		t.Fatalf("socketpair: %v", err)
	}
	defer unix.Close(fds[0])
	defer unix.Close(fds[1])
	if err := setReactorNonblock(fds[0]); err != nil {
		t.Fatalf("nonblock: %v", err)
	}

	// Register with ZERO interest (reads disabled, e.g. paused / not yet
	// listened / already at EOF), then half-close the peer's write side.
	if err := p.Register(fds[0], 1, 0); err != nil {
		t.Fatalf("register: %v", err)
	}
	if err := unix.Shutdown(fds[1], unix.SHUT_WR); err != nil {
		t.Fatalf("shutdown peer write: %v", err)
	}

	// Poll several times with a short timeout. If EPOLLRDHUP were armed, every
	// call would return the fd immediately with a HUP flag (the 100% CPU spin).
	out := make([]ReactorEvent, 8)
	hupEvents := 0
	for i := 0; i < 5; i++ {
		n, err := p.Wait(out, 20)
		if err != nil {
			t.Fatalf("wait: %v", err)
		}
		for j := 0; j < n; j++ {
			if out[j].Events&ReactorEventHup != 0 {
				hupEvents++
			}
		}
	}
	if hupEvents != 0 {
		t.Fatalf("got %d HUP events with reads disabled — half-close not masked (spin)", hupEvents)
	}
}

// TestEpollHalfCloseDeliveredWhenReadEnabled guards the other side of the
// contract: masking RDHUP must not lose the EOF — with reads enabled the
// half-close is reported so the reactor can drain and deliver EOF.
func TestEpollHalfCloseDeliveredWhenReadEnabled(t *testing.T) {
	p, err := newReactorPoller()
	if err != nil {
		t.Fatalf("newReactorPoller: %v", err)
	}
	defer p.Close()

	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		t.Fatalf("socketpair: %v", err)
	}
	defer unix.Close(fds[0])
	defer unix.Close(fds[1])
	if err := setReactorNonblock(fds[0]); err != nil {
		t.Fatalf("nonblock: %v", err)
	}

	if err := p.Register(fds[0], 1, ReactorEventRead); err != nil {
		t.Fatalf("register: %v", err)
	}
	if err := unix.Shutdown(fds[1], unix.SHUT_WR); err != nil {
		t.Fatalf("shutdown peer write: %v", err)
	}

	out := make([]ReactorEvent, 8)
	sawHup := false
	for i := 0; i < 5 && !sawHup; i++ {
		n, err := p.Wait(out, 100)
		if err != nil {
			t.Fatalf("wait: %v", err)
		}
		for j := 0; j < n; j++ {
			if out[j].ID == 1 && out[j].Events&ReactorEventHup != 0 {
				sawHup = true
			}
		}
	}
	if !sawHup {
		t.Fatal("half-close not delivered with reads enabled — EOF would be lost")
	}
}

// TestEpollErrorDeliveredOnResetWithReadsDisabled pins the contract the Dart
// dispatch's terminal-read branch depends on: EPOLLERR/EPOLLHUP are unmaskable,
// so a peer RST is delivered even when the transport has reads paused (zero
// interest). Because epoll is level-triggered, that event repeats until the fd
// is closed — which is exactly why the dispatch must respond by forcing a read
// (surfacing the error and closing) rather than ignoring flags it didn't
// subscribe to.
func TestEpollErrorDeliveredOnResetWithReadsDisabled(t *testing.T) {
	p, err := newReactorPoller()
	if err != nil {
		t.Fatalf("newReactorPoller: %v", err)
	}
	defer p.Close()

	local, peer := rstTCPPair(t)
	defer unix.Close(local)
	if err := setReactorNonblock(local); err != nil {
		t.Fatalf("nonblock: %v", err)
	}
	if err := p.Register(local, 7, 0); err != nil { // zero interest: reads paused
		t.Fatalf("register: %v", err)
	}

	resetPeer(t, peer)

	flags := waitForFlags(t, p, 7, ReactorEventError|ReactorEventHup)
	if flags&(ReactorEventError|ReactorEventHup) == 0 {
		t.Fatalf("RST with reads disabled delivered flags %#x, want ERR/HUP", flags)
	}
}
