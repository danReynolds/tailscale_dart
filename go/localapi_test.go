package tailscale

import (
	"net/netip"
	"testing"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
)

func TestPeerStatusAddrMatchesHostAndDNSName(t *testing.T) {
	peer := &ipnstate.PeerStatus{
		HostName:     "peer-1",
		DNSName:      "peer-1.tailnet.ts.net.",
		TailscaleIPs: []netip.Addr{netip.MustParseAddr("fd7a:115c:a1e0::1"), netip.MustParseAddr("100.64.0.2")},
	}

	for _, target := range []string{"peer-1", "peer-1.tailnet.ts.net"} {
		addr, ok := peerStatusAddr(peer, target)
		if !ok {
			t.Fatalf("peerStatusAddr(%q) did not match", target)
		}
		if got, want := addr.String(), "100.64.0.2"; got != want {
			t.Fatalf("peerStatusAddr(%q) = %s, want %s", target, got, want)
		}
	}
}

func TestPingWasDirectTSMPSuccess(t *testing.T) {
	pr := &ipnstate.PingResult{}
	if !pingWasDirect(pr, tailcfg.PingTSMP) {
		t.Fatal("successful TSMP ping should be treated as non-DERP")
	}
}

func TestPingWasDirectDiscoDerp(t *testing.T) {
	pr := &ipnstate.PingResult{
		DERPRegionID:   1,
		DERPRegionCode: "nyc",
	}
	if pingWasDirect(pr, tailcfg.PingDisco) {
		t.Fatal("DERP disco ping incorrectly reported as direct")
	}
}
