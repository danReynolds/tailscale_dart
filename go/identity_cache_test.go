package tailscale

import (
	"net/netip"
	"testing"

	"tailscale.com/tailcfg"
	"tailscale.com/types/netmap"
)

func testNetmap() *netmap.NetworkMap {
	self := &tailcfg.Node{
		ID:           1,
		StableID:     "nSELF",
		ComputedName: "self",
		User:         100,
		Addresses:    []netip.Prefix{netip.MustParsePrefix("100.64.0.1/32")},
	}
	peer := &tailcfg.Node{
		ID:           2,
		StableID:     "nPEER",
		ComputedName: "peer-1",
		User:         200,
		Addresses: []netip.Prefix{
			netip.MustParsePrefix("100.64.0.2/32"),
			netip.MustParsePrefix("fd7a:115c:a1e0::2/128"),
		},
		Tags: []string{"tag:server"},
	}
	return &netmap.NetworkMap{
		SelfNode: self.View(),
		Peers:    []tailcfg.NodeView{peer.View()},
		UserProfiles: map[tailcfg.UserID]tailcfg.UserProfileView{
			100: (&tailcfg.UserProfile{ID: 100, LoginName: "self@example.com"}).View(),
			200: (&tailcfg.UserProfile{ID: 200, LoginName: "peer@example.com"}).View(),
		},
	}
}

func TestBuildIdentityIndexMapsEveryAddress(t *testing.T) {
	idx := buildIdentityIndex(testNetmap())

	// The peer is reachable under both of its addresses, and both resolve to
	// the same shared identity object.
	v4 := netip.MustParseAddr("100.64.0.2")
	v6 := netip.MustParseAddr("fd7a:115c:a1e0::2")
	peer := idx[v4]
	if peer == nil {
		t.Fatal("peer v4 address not indexed")
	}
	if idx[v6] != peer {
		t.Error("peer v6 address should share the same identity pointer as v4")
	}
	if peer.NodeID != "nPEER" || peer.HostName != "peer-1" {
		t.Errorf("peer identity = %+v, want nPEER/peer-1", peer)
	}
	if peer.UserLoginName != "peer@example.com" {
		t.Errorf("peer login = %q, want peer@example.com", peer.UserLoginName)
	}
	if len(peer.Tags) != 1 || peer.Tags[0] != "tag:server" {
		t.Errorf("peer tags = %v, want [tag:server]", peer.Tags)
	}

	// Self is indexed too, with its own login.
	self := idx[netip.MustParseAddr("100.64.0.1")]
	if self == nil || self.NodeID != "nSELF" {
		t.Fatalf("self not indexed correctly: %+v", self)
	}
	if self.UserLoginName != "self@example.com" {
		t.Errorf("self login = %q, want self@example.com", self.UserLoginName)
	}
}

func TestBuildIdentityIndexNilNetmap(t *testing.T) {
	if idx := buildIdentityIndex(nil); idx == nil || len(idx) != 0 {
		t.Errorf("buildIdentityIndex(nil) = %v, want empty non-nil map", idx)
	}
}

func TestIdentityIndexLookupSemantics(t *testing.T) {
	var c identityIndex
	addr := netip.MustParseAddr("100.64.0.2")

	// Cold: signals fall-back-to-live (second return false).
	if id, ok := c.lookup(addr); ok || id != nil {
		t.Errorf("cold lookup = (%v, %v), want (nil, false)", id, ok)
	}

	c.replace(buildIdentityIndex(testNetmap()))

	// Warm hit.
	if id, ok := c.lookup(addr); !ok || id == nil || id.NodeID != "nPEER" {
		t.Errorf("warm hit = (%v, %v), want (nPEER, true)", id, ok)
	}
	// Warm miss: authoritative not-found, NOT a fall-back (second return true).
	if id, ok := c.lookup(netip.MustParseAddr("100.127.255.254")); !ok || id != nil {
		t.Errorf("warm miss = (%v, %v), want (nil, true)", id, ok)
	}

	// Invalidate returns to cold/fall-back.
	c.invalidate()
	if id, ok := c.lookup(addr); ok || id != nil {
		t.Errorf("post-invalidate lookup = (%v, %v), want (nil, false)", id, ok)
	}
}
