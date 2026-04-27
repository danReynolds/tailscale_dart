//go:build !android && !darwin

package tailscale

func updateLastKnownDefaultRouteInterface(ifName string) {}
