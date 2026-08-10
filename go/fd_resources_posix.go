//go:build !windows

package tailscale

import "net"

// fdResources groups the runtime-owned fd registries. It lives as one value
// on nodeRuntime so the portable lifecycle code needs no build tags; the
// POSIX-only resource types stay in this file.
type fdResources struct {
	tcpListeners fdRegistry[net.Listener]
	udpBridges   fdRegistry[*udpBridge]
	httpBindings fdRegistry[*httpBindingState]
}

// closeAll drains every family and closes the drained resources, in the same
// tcp, http, udp order the old global sweeps ran from nodeRuntime close.
func (f *fdResources) closeAll() {
	for _, ln := range f.tcpListeners.drain() {
		_ = ln.Close()
	}
	for _, state := range f.httpBindings.drain() {
		state.close()
	}
	for _, bridge := range f.udpBridges.drain() {
		bridge.close()
	}
}

// census reports live entries per family for the node-state snapshot.
func (f *fdResources) census() (tcpListeners, udpBridges, httpBindings int) {
	return f.tcpListeners.size(), f.udpBridges.size(), f.httpBindings.size()
}

func currentTcpListeners() *fdRegistry[net.Listener] {
	if runtime := currentRuntime(); runtime != nil {
		return &runtime.fd.tcpListeners
	}
	return nil
}

func currentUdpBridges() *fdRegistry[*udpBridge] {
	if runtime := currentRuntime(); runtime != nil {
		return &runtime.fd.udpBridges
	}
	return nil
}

func currentHttpBindings() *fdRegistry[*httpBindingState] {
	if runtime := currentRuntime(); runtime != nil {
		return &runtime.fd.httpBindings
	}
	return nil
}
