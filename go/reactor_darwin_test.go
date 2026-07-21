//go:build darwin || ios

package tailscale

import (
	"testing"

	"golang.org/x/sys/unix"
)

// TestKqueueErrorRidesReadFilterOnReset documents the darwin half of the
// platform contract (the twin of the epoll test): kqueue has no unmaskable
// events, so a peer RST is only observable through an armed filter. With read
// interest enabled the RST arrives as an EVFILT_READ kevent flagged EV_EOF —
// mapped to Read|Hup — and the socket error is stamped into Errno from Fflags
// (diagnostic only; the dispatch's forced read surfaces the real errno). With
// reads paused, darwin simply reports nothing until interest re-arms, which is
// the documented (lazier but convergent) counterpart to epoll's unmaskable
// delivery.
func TestKqueueErrorRidesReadFilterOnReset(t *testing.T) {
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
	if err := p.Register(local, 9, ReactorEventRead); err != nil {
		t.Fatalf("register: %v", err)
	}

	resetPeer(t, peer)

	flags := waitForFlags(t, p, 9, ReactorEventHup|ReactorEventError)
	if flags&ReactorEventRead == 0 {
		t.Fatalf("RST event flags %#x lack Read — EV_EOF should ride the read filter", flags)
	}
}
