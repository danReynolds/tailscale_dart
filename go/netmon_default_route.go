//go:build android || darwin

package tailscale

import "tailscale.com/net/netmon"

func updateLastKnownDefaultRouteInterface(ifName string) {
	netmon.UpdateLastKnownDefaultRouteInterface(ifName)
}
