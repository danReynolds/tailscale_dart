package tailscale

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"sync"
	"time"
)

// udpLoopbackDialTimeout bounds how long Go waits to reach the
// Dart-owned loopback TCP listener when setting up a UDP bridge.
const udpLoopbackDialTimeout = 5 * time.Second

// udpBindRegistry tracks active inbound UDP bridges so a fresh
// UdpBind on the same loopback port replaces any stale listener and
// so the engine teardown path can close orphaned PacketConns. Keyed
// by the Dart-owned loopback port (unique per bind on a given node).
var (
	udpBindRegistry   = map[int]net.PacketConn{}
	udpBindRegistryMu sync.Mutex
)

// UdpBind creates a tsnet UDP listener at tailnetHost:tailnetPort and
// a TCP loopback control conn to 127.0.0.1:loopbackPort, then pumps
// framed datagrams between them.
//
// Pass tailnetPort=0 to request an ephemeral port; the actual port
// is returned.
//
// tsnet.Server.ListenPacket requires a specific tailnet IP (not a
// wildcard), so tailnetHost must be a valid address literal.
//
// Frame format (same in both directions):
//
//	1 byte:     addr family marker (4 for IPv4, 16 for IPv6) — also
//	            the IP byte count
//	4/16 bytes: raw IP
//	2 bytes BE: port
//	2 bytes BE: payload length (0..65535)
//	N bytes:    payload
//
// Teardown: closing the loopback bridge conn (either side) unwinds
// the whole bridge — we close the tsnet PacketConn and unregister.
// No separate unbind RPC needed since the bridge conn close is the
// canonical end-of-life signal.
func UdpBind(tailnetHost string, tailnetPort int, loopbackPort int) (int, error) {
	if tailnetHost == "" {
		return 0, errors.New("tailnet host is required (tsnet.ListenPacket needs an IP)")
	}
	if tailnetPort < 0 || tailnetPort > 65535 {
		return 0, fmt.Errorf("invalid tailnet port %d", tailnetPort)
	}
	if loopbackPort < 1 || loopbackPort > 65535 {
		return 0, fmt.Errorf("invalid loopback port %d", loopbackPort)
	}

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return 0, errors.New("UdpBind called before Start")
	}

	host, err := netip.ParseAddr(tailnetHost)
	if err != nil {
		return 0, fmt.Errorf("parse tailnet host %q: %w", tailnetHost, err)
	}
	network := "udp4"
	if host.Is6() {
		network = "udp6"
	}
	addr := net.JoinHostPort(tailnetHost, strconv.Itoa(tailnetPort))

	pc, err := s.ListenPacket(network, addr)
	if err != nil {
		return 0, fmt.Errorf("tsnet listen packet %s: %w", addr, err)
	}
	actualPort := 0
	if u, ok := pc.LocalAddr().(*net.UDPAddr); ok {
		actualPort = u.Port
	}
	if actualPort == 0 {
		pc.Close()
		return 0, errors.New("tsnet packet conn returned unresolved port")
	}

	loopbackAddr := fmt.Sprintf("127.0.0.1:%d", loopbackPort)
	bridge, err := net.DialTimeout("tcp", loopbackAddr, udpLoopbackDialTimeout)
	if err != nil {
		pc.Close()
		return 0, fmt.Errorf("dial loopback bridge %s: %w", loopbackAddr, err)
	}
	configureTCP(bridge)

	udpBindRegistryMu.Lock()
	if prev, ok := udpBindRegistry[loopbackPort]; ok {
		prev.Close()
	}
	udpBindRegistry[loopbackPort] = pc
	udpBindRegistryMu.Unlock()

	go pumpUdpBridge(pc, bridge, loopbackPort)
	return actualPort, nil
}

// pumpUdpBridge runs the uplink and downlink goroutines until either
// direction terminates, then tears both sides down and cleans up the
// registry.
func pumpUdpBridge(pc net.PacketConn, bridge net.Conn, loopbackPort int) {
	done := make(chan struct{}, 2)

	// Downlink: tsnet peer → Dart
	go func() {
		buf := make([]byte, 65535)
		for {
			n, from, err := pc.ReadFrom(buf)
			if err != nil {
				done <- struct{}{}
				return
			}
			udpAddr, ok := from.(*net.UDPAddr)
			if !ok || udpAddr.IP == nil {
				tcpLog("udp bridge: drop: unrecognized from addr %T", from)
				continue
			}
			if err := writeUdpFrame(bridge, udpAddr.IP, udpAddr.Port, buf[:n]); err != nil {
				done <- struct{}{}
				return
			}
		}
	}()

	// Uplink: Dart → tsnet peer
	go func() {
		for {
			ip, port, payload, err := readUdpFrame(bridge)
			if err != nil {
				done <- struct{}{}
				return
			}
			if _, werr := pc.WriteTo(payload, &net.UDPAddr{IP: ip, Port: port}); werr != nil {
				// UDP drops are expected — log at info level but keep
				// the bridge alive. A single bad peer addr shouldn't
				// kill the whole socket.
				tcpLog("udp bridge: WriteTo %s:%d failed: %v", ip, port, werr)
			}
		}
	}()

	<-done

	pc.Close()
	bridge.Close()

	udpBindRegistryMu.Lock()
	if udpBindRegistry[loopbackPort] == pc {
		delete(udpBindRegistry, loopbackPort)
	}
	udpBindRegistryMu.Unlock()

	<-done
}

// writeUdpFrame serializes one datagram frame to w. Assembles the
// full frame in memory first so a single Write keeps header and
// payload on the same TCP segment boundary (avoids interleaving
// across concurrent writers — currently moot since only one
// goroutine writes per bridge, but cheap insurance).
func writeUdpFrame(w io.Writer, ip net.IP, port int, payload []byte) error {
	var ipBytes []byte
	if v4 := ip.To4(); v4 != nil {
		ipBytes = v4
	} else {
		ipBytes = ip.To16()
		if ipBytes == nil {
			return fmt.Errorf("unrepresentable IP %v", ip)
		}
	}
	if len(payload) > 65535 {
		return fmt.Errorf("udp payload too large: %d bytes", len(payload))
	}

	frame := make([]byte, 1+len(ipBytes)+2+2+len(payload))
	frame[0] = byte(len(ipBytes))
	copy(frame[1:], ipBytes)
	binary.BigEndian.PutUint16(frame[1+len(ipBytes):], uint16(port))
	binary.BigEndian.PutUint16(frame[1+len(ipBytes)+2:], uint16(len(payload)))
	copy(frame[1+len(ipBytes)+4:], payload)

	_, err := w.Write(frame)
	return err
}

// readUdpFrame reads one framed datagram from r. Returns EOF (or
// ErrUnexpectedEOF on partial frames) when the peer closes; caller
// uses that signal to tear down the bridge.
func readUdpFrame(r io.Reader) (net.IP, int, []byte, error) {
	var marker [1]byte
	if _, err := io.ReadFull(r, marker[:]); err != nil {
		return nil, 0, nil, err
	}
	ipLen := int(marker[0])
	if ipLen != 4 && ipLen != 16 {
		return nil, 0, nil, fmt.Errorf("invalid addr family byte: %d", ipLen)
	}
	header := make([]byte, ipLen+4)
	if _, err := io.ReadFull(r, header); err != nil {
		return nil, 0, nil, err
	}
	ip := net.IP(header[:ipLen])
	port := int(binary.BigEndian.Uint16(header[ipLen : ipLen+2]))
	payloadLen := int(binary.BigEndian.Uint16(header[ipLen+2 : ipLen+4]))
	payload := make([]byte, payloadLen)
	if payloadLen > 0 {
		if _, err := io.ReadFull(r, payload); err != nil {
			return nil, 0, nil, err
		}
	}
	return ip, port, payload, nil
}
