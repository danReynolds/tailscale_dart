//go:build !windows

package tailscale

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"strconv"
	"sync"

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
	LocalAddress string
	LocalPort    int
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

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return nil, errors.New("UdpBindFd called before Start")
	}

	addr := net.JoinHostPort(host, strconv.Itoa(port))
	pc, err := s.ListenPacket("udp", addr)
	if err != nil {
		return nil, fmt.Errorf("tsnet listen packet %s: %w", addr, err)
	}

	dartFd, goFd, err := newDatagramSocketPair()
	if err != nil {
		pc.Close()
		return nil, err
	}

	localAddress, localPort := endpointFromAddr(pc.LocalAddr())
	if localAddress == "" {
		localAddress = host
	}
	go runUdpFdBridge(goFd, pc)
	return &UdpFdBinding{
		FD:           dartFd,
		LocalAddress: localAddress,
		LocalPort:    localPort,
	}, nil
}

func newDatagramSocketPair() (int, int, error) {
	dartFd, goFd, err := newSocketPairCloexec(unix.SOCK_DGRAM)
	if err != nil {
		return -1, -1, err
	}
	return dartFd, goFd, nil
}

func runUdpFdBridge(goFd int, pc net.PacketConn) {
	var once sync.Once
	closeAll := func() {
		once.Do(func() {
			_ = pc.Close()
			_ = unix.Shutdown(goFd, unix.SHUT_RDWR)
			_ = unix.Close(goFd)
		})
	}

	go func() {
		defer closeAll()
		buf := make([]byte, udpMaxEnvelopeBytes)
		for {
			n, err := unix.Read(goFd, buf)
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
		defer closeAll()
		buf := make([]byte, udpMaxPayloadBytes)
		for {
			n, addr, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			envelope, err := encodeUdpEnvelope(addr, buf[:n])
			if err != nil {
				logInfo("UDP fd bridge dropped inbound datagram: %v", err)
				continue
			}
			if err := writeDatagramFd(goFd, envelope); err != nil {
				return
			}
		}
	}()
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
	addr, err := net.ResolveUDPAddr("udp", net.JoinHostPort(address, strconv.Itoa(port)))
	if err != nil {
		return nil, nil, err
	}
	return addr, envelope[payloadOffset:], nil
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
