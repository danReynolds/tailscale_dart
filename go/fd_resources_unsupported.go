//go:build windows

package tailscale

// fdResources is empty on platforms without the POSIX fd data plane.
type fdResources struct{}

func (f *fdResources) closeAll() {}

func (f *fdResources) census() (tcpListeners, udpBridges, httpBindings int) {
	return 0, 0, 0
}
