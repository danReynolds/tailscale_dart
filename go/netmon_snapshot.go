package tailscale

import (
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"tailscale.com/net/netmon"
)

type hostNetworkSnapshotJSON struct {
	DefaultRouteInterface string                     `json:"defaultRouteInterface"`
	Interfaces            []hostNetworkInterfaceJSON `json:"interfaces"`
}

type hostNetworkInterfaceJSON struct {
	Name      string   `json:"name"`
	Index     int      `json:"index"`
	MTU       int      `json:"mtu"`
	Addresses []string `json:"addresses"`
}

var (
	hostNetworkMu         sync.RWMutex
	hostNetworkInterfaces []netmon.Interface
	hostNetworkGetterOnce sync.Once
)

// ConfigureHostNetworkSnapshot registers a host-provided interface snapshot for
// Android. Go's net.Interfaces uses netlink on Android, which app sandboxes can
// deny; Tailscale exposes netmon.RegisterInterfaceGetter for embedders to feed
// interface state from the host runtime instead.
func ConfigureHostNetworkSnapshot(raw string) error {
	if runtime.GOOS != "android" {
		return nil
	}

	ifaces, defaultRoute, err := parseHostNetworkSnapshot(raw)
	if err != nil {
		return err
	}
	if len(ifaces) == 0 {
		ifaces = androidFallbackInterfaces()
		defaultRoute = ifaces[0].Name
	}
	if defaultRoute == "" {
		defaultRoute = chooseDefaultRouteInterface(ifaces)
	}

	hostNetworkMu.Lock()
	hostNetworkInterfaces = cloneNetmonInterfaces(ifaces)
	hostNetworkMu.Unlock()

	hostNetworkGetterOnce.Do(func() {
		netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
			hostNetworkMu.RLock()
			defer hostNetworkMu.RUnlock()
			return cloneNetmonInterfaces(hostNetworkInterfaces), nil
		})
	})

	netmon.UpdateLastKnownDefaultRouteInterface(defaultRoute)
	return nil
}

func parseHostNetworkSnapshot(raw string) ([]netmon.Interface, string, error) {
	if strings.TrimSpace(raw) == "" {
		raw = "{}"
	}

	var snapshot hostNetworkSnapshotJSON
	if err := json.Unmarshal([]byte(raw), &snapshot); err != nil {
		return nil, "", fmt.Errorf("invalid network interface snapshot: %w", err)
	}

	ifaces := make([]netmon.Interface, 0, len(snapshot.Interfaces))
	for _, src := range snapshot.Interfaces {
		name := strings.TrimSpace(src.Name)
		if name == "" {
			continue
		}

		addrs := make([]net.Addr, 0, len(src.Addresses))
		for _, rawAddr := range src.Addresses {
			addr, err := netip.ParseAddr(strings.TrimSpace(rawAddr))
			if err != nil {
				continue
			}
			addrs = append(addrs, ipNetAddr(addr))
		}
		if len(addrs) == 0 {
			continue
		}

		mtu := src.MTU
		if mtu <= 0 {
			mtu = 1500
		}

		flags := net.FlagUp | net.FlagMulticast
		if interfaceLooksLoopback(name, addrs) {
			flags |= net.FlagLoopback
			mtu = 65536
		} else {
			flags |= net.FlagBroadcast
		}

		ifaces = append(ifaces, netmon.Interface{
			Interface: &net.Interface{
				Index: src.Index,
				MTU:   mtu,
				Name:  name,
				Flags: flags,
			},
			AltAddrs: addrs,
		})
	}

	sort.Slice(ifaces, func(i, j int) bool {
		return ifaces[i].Name < ifaces[j].Name
	})

	return ifaces, strings.TrimSpace(snapshot.DefaultRouteInterface), nil
}

func ipNetAddr(addr netip.Addr) *net.IPNet {
	ip := append(net.IP(nil), addr.AsSlice()...)
	if addr.Is4() {
		return &net.IPNet{
			IP:   ip,
			Mask: net.CIDRMask(32, 32),
		}
	}
	return &net.IPNet{
		IP:   ip,
		Mask: net.CIDRMask(128, 128),
	}
}

func interfaceLooksLoopback(name string, addrs []net.Addr) bool {
	if name == "lo" || strings.HasPrefix(name, "lo") {
		return true
	}
	for _, addr := range addrs {
		ipNet, ok := addr.(*net.IPNet)
		if !ok {
			continue
		}
		if ip, ok := netip.AddrFromSlice(ipNet.IP); ok && ip.IsLoopback() {
			return true
		}
	}
	return false
}

func chooseDefaultRouteInterface(ifaces []netmon.Interface) string {
	for _, iface := range ifaces {
		if iface.Interface == nil || iface.IsLoopback() {
			continue
		}
		for _, addr := range iface.AltAddrs {
			if hostAddrUsable(addr, true) {
				return iface.Name
			}
		}
	}
	for _, iface := range ifaces {
		if iface.Interface == nil || iface.IsLoopback() {
			continue
		}
		for _, addr := range iface.AltAddrs {
			if hostAddrUsable(addr, false) {
				return iface.Name
			}
		}
	}
	return ""
}

func hostAddrUsable(addr net.Addr, requireIPv4 bool) bool {
	ipNet, ok := addr.(*net.IPNet)
	if !ok {
		return false
	}
	ip, ok := netip.AddrFromSlice(ipNet.IP)
	if !ok || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return false
	}
	if requireIPv4 && !ip.Is4() {
		return false
	}
	return true
}

func cloneNetmonInterfaces(in []netmon.Interface) []netmon.Interface {
	out := make([]netmon.Interface, len(in))
	for i, iface := range in {
		out[i] = iface
		if iface.Interface != nil {
			copyIface := *iface.Interface
			out[i].Interface = &copyIface
		}
		if iface.AltAddrs != nil {
			out[i].AltAddrs = append([]net.Addr(nil), iface.AltAddrs...)
		}
	}
	return out
}

func androidFallbackInterfaces() []netmon.Interface {
	addr := androidOutboundAddr()
	if !addr.IsValid() {
		addr = netip.MustParseAddr("192.0.2.1")
	}
	return []netmon.Interface{{
		Interface: &net.Interface{
			Index: 1,
			MTU:   1500,
			Name:  "android0",
			Flags: net.FlagUp | net.FlagBroadcast | net.FlagMulticast,
		},
		AltAddrs: []net.Addr{ipNetAddr(addr)},
	}}
}

func androidOutboundAddr() netip.Addr {
	conn, err := net.DialTimeout("udp", "8.8.8.8:53", 200*time.Millisecond)
	if err != nil {
		return netip.Addr{}
	}
	defer conn.Close()

	udpAddr, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok {
		return netip.Addr{}
	}
	addr, ok := netip.AddrFromSlice(udpAddr.IP)
	if !ok {
		return netip.Addr{}
	}
	return addr
}
