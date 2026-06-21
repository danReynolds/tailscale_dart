package tailscale

import (
	"net/netip"
	"sync"

	"tailscale.com/tailcfg"
	"tailscale.com/types/netmap"
)

// identityIndex is an in-memory address -> identity map mirrored from the
// netmap. It turns accept-time identity resolution into a lock + map read
// instead of a multi-millisecond LocalAPI WhoIs round-trip. It is rebuilt
// wholesale from each netmap the state watcher delivers and read on the accept
// hot path.
//
// It deliberately mirrors only the node's own addresses (the same source
// tailscaled indexes for WhoIs-by-address), which is exactly what an accepted
// connection presents: the RemoteAddr of an inbound tailnet connection is the
// peer's own tailnet IP, never a subnet-routed or 4via6 source. So by address
// type the index covers everything an accept can present; the cases WhoIs
// resolves that this skips can't appear as an accept RemoteAddr. The one
// transient gap is temporal, not structural: a peer admitted just before its
// netmap reaches the watcher — see lookup.
type identityIndex struct {
	mu        sync.RWMutex
	populated bool
	byAddr    map[netip.Addr]*nodeIdentity
}

// identityCache is the process-wide accept-path identity index. There is one
// embedded engine per process, so one cache suffices.
var identityCache identityIndex

// replace swaps in a freshly built index and marks the cache warm. Called from
// the state watcher on every netmap tick.
func (c *identityIndex) replace(byAddr map[netip.Addr]*nodeIdentity) {
	c.mu.Lock()
	c.byAddr = byAddr
	c.populated = true
	c.mu.Unlock()
}

// invalidate marks the cache cold so subsequent lookups fall back to the
// authoritative LocalAPI WhoIs. Called when the watcher stops (node down /
// watch torn down), because a frozen index can drift from the live netmap.
func (c *identityIndex) invalidate() {
	c.mu.Lock()
	c.byAddr = nil
	c.populated = false
	c.mu.Unlock()
}

// lookup returns (identity, true) when the cache is warm. The boolean is false
// only when the cache is cold (never populated or invalidated), signaling the
// caller to fall back to a live lookup. A warm cache that lacks the address
// returns (nil, true) and is treated as authoritative — no live fallback —
// which keeps the accept path O(1) and non-DoS-able. The window this trades
// away: a peer admitted just before its netmap reaches the watcher resolves to
// nil until the next tick (self-healing); callers needing a hard guarantee
// use whois().
func (c *identityIndex) lookup(addr netip.Addr) (*nodeIdentity, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if !c.populated {
		return nil, false
	}
	return c.byAddr[addr], true
}

// buildIdentityIndex flattens a netmap into an address -> identity map: self
// and every peer, indexed by each of their tailnet addresses, with login names
// resolved from the netmap's UserProfiles. Pure and allocation-bounded so it
// can be unit-tested without a live backend. Each address maps to one shared
// *nodeIdentity, so a multi-homed node costs one identity regardless of how
// many addresses it advertises.
func buildIdentityIndex(nm *netmap.NetworkMap) map[netip.Addr]*nodeIdentity {
	if nm == nil {
		return map[netip.Addr]*nodeIdentity{}
	}
	out := make(map[netip.Addr]*nodeIdentity, len(nm.Peers)+1)
	index := func(n tailcfg.NodeView) {
		if !n.Valid() {
			return
		}
		id := nodeIdentityFromView(n, loginNameForUser(nm, n.User()))
		if id == nil {
			return
		}
		addrs := n.Addresses()
		for i := range addrs.Len() {
			out[addrs.At(i).Addr()] = id
		}
	}
	index(nm.SelfNode)
	for _, peer := range nm.Peers {
		index(peer)
	}
	return out
}

// loginNameForUser resolves a node's owning user to a login name via the
// netmap's UserProfiles. Returns "" for tagged nodes (no user) or when the
// profile is absent, matching the WhoIs path's empty-login behavior.
func loginNameForUser(nm *netmap.NetworkMap, uid tailcfg.UserID) string {
	if up, ok := nm.UserProfiles[uid]; ok && up.Valid() {
		return up.LoginName()
	}
	return ""
}
