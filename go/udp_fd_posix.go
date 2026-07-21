//go:build !windows

package tailscale

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"strconv"
	"sync"
	"sync/atomic"

	"golang.org/x/sys/unix"
)

const (
	udpEnvelopeVersion     = 1
	udpEnvelopeHeaderBytes = 4
	udpMaxPayloadBytes     = 60 * 1024
	udpMaxAddressBytes     = 255
	udpMaxEnvelopeBytes    = udpEnvelopeHeaderBytes + udpMaxAddressBytes + udpMaxPayloadBytes
)

type UdpFdBinding struct {
	FD           int
	BindingID    int64
	LocalAddress string
	LocalPort    int
}

// udpFdBindingRegistry tracks live UDP bridges so they can be torn down
// explicitly. Keyed by a monotonically-assigned binding id (returned in the
// bind response and passed back to UdpCloseBinding) rather than the Dart-side
// fd: an fd is an OS number the kernel reuses, so an fd-keyed registry had a
// whole displacement class — a binding dropped without close could be silently
// overwritten by a later binding whose socketpair reused the number — that
// monotonic ids make unrepresentable. A datagram socketpair peer-close does
// NOT wake a goroutine parked in read on the other end (unlike a stream
// socket), so without an explicit close the bridge goroutines, the tailnet
// PacketConn (and its port), and two OS threads would leak until process exit.
var (
	udpFdBindingMu       sync.Mutex
	udpFdBindingRegistry = map[int64]*udpBridge{}
	udpBindingID         int64 // atomic
)

type udpBridge struct {
	closeOnce sync.Once
	// close tears down the bridge: closes the tsnet PacketConn (waking the
	// inbound goroutine) and the netpoller-integrated Go conn (waking the
	// outbound goroutine — a raw fd close cannot unblock a parked read, but a
	// net.Conn close routes through the poller and does).
	closeFn func()
}

func (b *udpBridge) close() { b.closeOnce.Do(b.closeFn) }

// registerUdpBridge installs [bridge] under [id], reporting whether the gated
// lifecycle is still live. On false the bridge was NOT installed and the
// caller owns cleanup. Ids are monotonic and never reused, so an insert can
// never displace an existing entry.
func registerUdpBridge(gate nodeGate, id int64, bridge *udpBridge) bool {
	udpFdBindingMu.Lock()
	// Commit-point epoch check (see nodeGate): a bind that raced teardown must
	// not land behind closeAllUdpBindings' sweep, where it would hold its
	// tailnet port and two pump goroutines with no owner until process exit.
	if !gate.stillCurrent() {
		udpFdBindingMu.Unlock()
		return false
	}
	udpFdBindingRegistry[id] = bridge
	udpFdBindingMu.Unlock()
	return true
}

func deregisterUdpBridge(id int64, bridge *udpBridge) {
	udpFdBindingMu.Lock()
	if udpFdBindingRegistry[id] == bridge {
		delete(udpFdBindingRegistry, id)
	}
	udpFdBindingMu.Unlock()
}

// UdpCloseBinding tears down the UDP bridge for [id] (from the bind response).
// Idempotent and a no-op for an unknown id.
func UdpCloseBinding(id int64) {
	udpFdBindingMu.Lock()
	bridge := udpFdBindingRegistry[id]
	delete(udpFdBindingRegistry, id)
	udpFdBindingMu.Unlock()
	if bridge != nil {
		bridge.close()
	}
}

func closeAllUdpBindings() {
	udpFdBindingMu.Lock()
	bridges := make([]*udpBridge, 0, len(udpFdBindingRegistry))
	for id, bridge := range udpFdBindingRegistry {
		bridges = append(bridges, bridge)
		delete(udpFdBindingRegistry, id)
	}
	udpFdBindingMu.Unlock()
	for _, bridge := range bridges {
		bridge.close()
	}
}

// UdpBindFd opens a tailnet UDP packet listener and returns a POSIX datagram fd
// for the Dart side.
func UdpBindFd(host string, port int) (*UdpFdBinding, error) {
	if host == "" {
		return nil, errors.New("host is required")
	}
	if net.ParseIP(host) == nil {
		return nil, fmt.Errorf("host %q is not a valid IP address", host)
	}
	if port < 0 || port > 65535 {
		return nil, fmt.Errorf("invalid port %d", port)
	}

	gate, ok := acquireNodeGate()
	if !ok {
		return nil, errors.New("UdpBindFd called before Start")
	}

	addr := net.JoinHostPort(host, strconv.Itoa(port))
	pc, err := gate.s.ListenPacket("udp", addr)
	if err != nil {
		return nil, fmt.Errorf("tsnet listen packet %s: %w", addr, err)
	}

	dartFd, goConn, err := newDatagramSocketPairConn()
	if err != nil {
		pc.Close()
		return nil, err
	}

	localAddress, localPort := endpointFromAddr(pc.LocalAddr())
	if localAddress == "" {
		localAddress = host
	}
	id := atomic.AddInt64(&udpBindingID, 1)
	if err := runUdpFdBridge(gate, id, goConn, pc); err != nil {
		// The bridge closed pc and goConn; the Dart-side fd was never handed
		// out, so close it here too.
		_ = unix.Close(dartFd)
		return nil, err
	}
	return &UdpFdBinding{
		FD:           dartFd,
		BindingID:    id,
		LocalAddress: localAddress,
		LocalPort:    localPort,
	}, nil
}

func newDatagramSocketPair() (int, int, error) {
	dartFd, goFd, err := newSocketPairCloexec(unix.SOCK_DGRAM)
	if err != nil {
		return -1, -1, err
	}
	// Unlike a stream socketpair, SO_SNDBUF/SO_RCVBUF on a datagram socketpair
	// bounds the *maximum single datagram*, not just throughput. The macOS/iOS
	// default (net.local.dgram.maxdgram = 2048) is far below the 60 KiB payload
	// this transport advertises, so without this an envelope larger than ~2 KiB
	// fails with EMSGSIZE and tears the whole binding down. Must stay >=
	// udpMaxEnvelopeBytes; tuneSocketPairBuffers' 256 KiB target clears it with
	// room for a few datagrams in flight. Set before the fd is wrapped; the
	// option lives on the socket and survives the net.FileConn dup.
	tuneSocketPairBuffers(dartFd, goFd)
	return dartFd, goFd, nil
}

// newDatagramSocketPairConn creates the datagram socketpair and wraps the Go
// end in a netpoller-integrated net.Conn. Returns the raw Dart-side fd and the
// Go-side conn.
func newDatagramSocketPairConn() (int, net.Conn, error) {
	dartFd, goFd, err := newDatagramSocketPair()
	if err != nil {
		return -1, nil, err
	}
	// Wrap the Go end in the netpoller so reads/writes don't each pin a blocked
	// OS thread, and — critically — so closing the conn unblocks a parked read
	// (a raw datagram socketpair peer-close does not).
	file := os.NewFile(uintptr(goFd), "tailscale-dart-udp-go")
	if file == nil {
		_ = unix.Close(dartFd)
		_ = unix.Close(goFd)
		return -1, nil, errors.New("udp socketpair fd could not be wrapped")
	}
	goConn, err := net.FileConn(file)
	_ = file.Close()
	if err != nil {
		_ = unix.Close(dartFd)
		return -1, nil, fmt.Errorf("wrap udp socketpair fd: %w", err)
	}
	return dartFd, goConn, nil
}

func runUdpFdBridge(gate nodeGate, id int64, goConn net.Conn, pc net.PacketConn) error {
	bridge := &udpBridge{}
	bridge.closeFn = func() {
		deregisterUdpBridge(id, bridge)
		_ = pc.Close()
		_ = goConn.Close()
	}
	// Register before spawning the pump goroutines: a bind refused at the
	// commit gate must leave nothing running.
	if !registerUdpBridge(gate, id, bridge) {
		_ = pc.Close()
		_ = goConn.Close()
		return errors.New("udp bind raced node teardown")
	}

	go func() {
		defer bridge.close()
		buf := make([]byte, udpMaxEnvelopeBytes)
		for {
			n, err := goConn.Read(buf)
			if err != nil {
				return
			}
			if n == 0 {
				continue
			}
			addr, payload, err := decodeUdpEnvelope(buf[:n])
			if err != nil {
				logInfo("UDP fd bridge dropped malformed outbound envelope: %v", err)
				continue
			}
			if _, err := pc.WriteTo(payload, addr); err != nil {
				return
			}
		}
	}()

	go func() {
		defer bridge.close()
		// Read into a buffer one byte larger than the max payload so an
		// oversized datagram can be detected (n > udpMaxPayloadBytes) and
		// dropped rather than silently truncated to the buffer size and
		// delivered as a valid-looking-but-short datagram.
		buf := make([]byte, udpMaxPayloadBytes+1)
		for {
			n, addr, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			if n > udpMaxPayloadBytes {
				logInfo("UDP fd bridge dropped oversized inbound datagram (%d > %d bytes)", n, udpMaxPayloadBytes)
				continue
			}
			envelope, err := encodeUdpEnvelope(addr, buf[:n])
			if err != nil {
				logInfo("UDP fd bridge dropped inbound datagram: %v", err)
				continue
			}
			if _, err := goConn.Write(envelope); err != nil {
				return
			}
		}
	}()
	return nil
}

func encodeUdpEnvelope(addr net.Addr, payload []byte) ([]byte, error) {
	if len(payload) > udpMaxPayloadBytes {
		return nil, fmt.Errorf("UDP payload exceeds %d bytes", udpMaxPayloadBytes)
	}
	host, portText, err := net.SplitHostPort(addr.String())
	if err != nil {
		return nil, fmt.Errorf("split UDP address %q: %w", addr.String(), err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return nil, fmt.Errorf("invalid UDP port %q", portText)
	}
	address := []byte(host)
	if len(address) == 0 || len(address) > udpMaxAddressBytes {
		return nil, fmt.Errorf("invalid UDP address length %d", len(address))
	}

	envelope := make([]byte, udpEnvelopeHeaderBytes+len(address)+len(payload))
	envelope[0] = udpEnvelopeVersion
	envelope[1] = byte(len(address))
	binary.BigEndian.PutUint16(envelope[2:4], uint16(port))
	copy(envelope[udpEnvelopeHeaderBytes:], address)
	copy(envelope[udpEnvelopeHeaderBytes+len(address):], payload)
	return envelope, nil
}

func decodeUdpEnvelope(envelope []byte) (*net.UDPAddr, []byte, error) {
	if len(envelope) < udpEnvelopeHeaderBytes {
		return nil, nil, errors.New("malformed UDP envelope")
	}
	if envelope[0] != udpEnvelopeVersion {
		return nil, nil, fmt.Errorf("unsupported UDP envelope version %d", envelope[0])
	}
	addressLen := int(envelope[1])
	payloadOffset := udpEnvelopeHeaderBytes + addressLen
	if addressLen == 0 || payloadOffset > len(envelope) {
		return nil, nil, errors.New("malformed UDP envelope address")
	}
	port := int(binary.BigEndian.Uint16(envelope[2:4]))
	if port < 1 || port > 65535 {
		return nil, nil, fmt.Errorf("invalid UDP envelope port %d", port)
	}
	address := string(envelope[udpEnvelopeHeaderBytes:payloadOffset])
	// Parse as an IP literal only. An inbound envelope's address is always a
	// tailnet peer IP, so net.ResolveUDPAddr's hostname path is never needed —
	// and would let a hostname trigger a blocking DNS lookup that stalls the
	// single outbound pump goroutine (head-of-line blocking for every datagram
	// on the binding). netip.ParseAddr never touches the network.
	ip, err := netip.ParseAddr(address)
	if err != nil {
		return nil, nil, fmt.Errorf("invalid UDP envelope address %q: %w", address, err)
	}
	return net.UDPAddrFromAddrPort(netip.AddrPortFrom(ip, uint16(port))), envelope[payloadOffset:], nil
}

func writeDatagramFd(fd int, payload []byte) error {
	n, err := unix.Write(fd, payload)
	if err != nil {
		return err
	}
	if n != len(payload) {
		return fmt.Errorf("short datagram write: wrote %d of %d", n, len(payload))
	}
	return nil
}
