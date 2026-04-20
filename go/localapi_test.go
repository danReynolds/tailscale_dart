package tailscale

import (
	"net/netip"
	"testing"

	"tailscale.com/ipn/ipnstate"
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

func TestPingPathUnknownWhenRouteMetadataMissing(t *testing.T) {
	pr := &ipnstate.PingResult{}
	if got := pingPath(pr); got != "unknown" {
		t.Fatalf("pingPath(empty) = %q, want unknown", got)
	}
}

func TestPingPathDerp(t *testing.T) {
	pr := &ipnstate.PingResult{
		DERPRegionID:   1,
		DERPRegionCode: "nyc",
	}
	if got := pingPath(pr); got != "derp" {
		t.Fatalf("pingPath(derp) = %q, want derp", got)
	}
}

func TestPingPathDirect(t *testing.T) {
	pr := &ipnstate.PingResult{Endpoint: "100.64.0.2:41641"}
	if got := pingPath(pr); got != "direct" {
		t.Fatalf("pingPath(direct) = %q, want direct", got)
	}
}
