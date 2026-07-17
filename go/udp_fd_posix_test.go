//go:build !windows

package tailscale

import (
	"bytes"
	"encoding/binary"
	"net"
	"testing"

	"golang.org/x/sys/unix"
)

// TestDecodeUdpEnvelope_RejectsHostname guards that the outbound datagram
// address is parsed as an IP literal only — a hostname must be rejected, not
// sent through a blocking DNS lookup that would stall the outbound pump.
func TestDecodeUdpEnvelope_RejectsHostname(t *testing.T) {
	host := []byte("example.com")
	env := make([]byte, udpEnvelopeHeaderBytes+len(host))
	env[0] = udpEnvelopeVersion
	env[1] = byte(len(host))
	binary.BigEndian.PutUint16(env[2:4], 53)
	copy(env[udpEnvelopeHeaderBytes:], host)
	if _, _, err := decodeUdpEnvelope(env); err == nil {
		t.Fatal("decode accepted a hostname address; must require an IP literal")
	}
}

func TestUdpEnvelope_RoundTrip(t *testing.T) {
	addr := mustResolveUDPAddr(t, "100.64.0.2:7001")
	payload := []byte("hello udp")

	envelope, err := encodeUdpEnvelope(addr, payload)
	if err != nil {
		t.Fatalf("encodeUdpEnvelope: %v", err)
	}
	gotAddr, gotPayload, err := decodeUdpEnvelope(envelope)
	if err != nil {
		t.Fatalf("decodeUdpEnvelope: %v", err)
	}

	if gotAddr.String() != addr.String() {
		t.Fatalf("addr = %v, want %v", gotAddr, addr)
	}
	if !bytes.Equal(gotPayload, payload) {
		t.Fatalf("payload = %q, want %q", gotPayload, payload)
	}
}

func TestUdpEnvelope_AllowsEmptyPayload(t *testing.T) {
	addr := mustResolveUDPAddr(t, "100.64.0.2:7001")

	envelope, err := encodeUdpEnvelope(addr, nil)
	if err != nil {
		t.Fatalf("encodeUdpEnvelope: %v", err)
	}
	gotAddr, gotPayload, err := decodeUdpEnvelope(envelope)
	if err != nil {
		t.Fatalf("decodeUdpEnvelope: %v", err)
	}

	if gotAddr.String() != addr.String() {
		t.Fatalf("addr = %v, want %v", gotAddr, addr)
	}
	if len(gotPayload) != 0 {
		t.Fatalf("payload length = %d, want 0", len(gotPayload))
	}
}

func TestUdpEnvelope_RejectsMalformed(t *testing.T) {
	if _, _, err := decodeUdpEnvelope([]byte{1, 20, 0, 80}); err == nil {
		t.Fatal("decode succeeded for truncated address")
	}

	tooLarge := make([]byte, udpMaxPayloadBytes+1)
	if _, err := encodeUdpEnvelope(mustResolveUDPAddr(t, "100.64.0.2:1"), tooLarge); err == nil {
		t.Fatal("encode succeeded for oversize payload")
	}
}

func TestNewDatagramSocketPair_PreservesDatagramBoundaries(t *testing.T) {
	left, right, err := newDatagramSocketPair()
	if err != nil {
		t.Fatalf("newDatagramSocketPair: %v", err)
	}
	defer unix.Close(left)
	defer unix.Close(right)

	if err := writeDatagramFd(left, []byte("one")); err != nil {
		t.Fatalf("write one: %v", err)
	}
	if err := writeDatagramFd(left, []byte("two")); err != nil {
		t.Fatalf("write two: %v", err)
	}

	buf := make([]byte, 16)
	n, err := unix.Read(right, buf)
	if err != nil {
		t.Fatalf("read one: %v", err)
	}
	if string(buf[:n]) != "one" {
		t.Fatalf("first datagram = %q, want one", buf[:n])
	}
	n, err = unix.Read(right, buf)
	if err != nil {
		t.Fatalf("read two: %v", err)
	}
	if string(buf[:n]) != "two" {
		t.Fatalf("second datagram = %q, want two", buf[:n])
	}
}

// TestNewDatagramSocketPair_CarriesMaxEnvelope guards the buffer-sizing bug
// where the datagram socketpair kept the OS default send buffer. On macOS/iOS
// that default (net.local.dgram.maxdgram = 2048) is far below the advertised
// 60 KiB payload, so a full-size envelope failed with EMSGSIZE and tore the
// binding down. A 3-byte round trip (the sibling test) cannot see this; a
// max-size datagram can. This also fails on Linux if the tuning regresses far
// enough, so it is a platform-agnostic guard for the advertised limit.
func TestNewDatagramSocketPair_CarriesMaxEnvelope(t *testing.T) {
	left, right, err := newDatagramSocketPair()
	if err != nil {
		t.Fatalf("newDatagramSocketPair: %v", err)
	}
	defer unix.Close(left)
	defer unix.Close(right)

	// A worst-case envelope: max payload plus a full-length address header.
	payload := bytes.Repeat([]byte{0x5a}, udpMaxPayloadBytes)
	envelope, err := encodeUdpEnvelope(mustResolveUDPAddr(t, "100.64.0.2:7001"), payload)
	if err != nil {
		t.Fatalf("encodeUdpEnvelope: %v", err)
	}
	if err := writeDatagramFd(left, envelope); err != nil {
		t.Fatalf("write max-size datagram (%d bytes): %v", len(envelope), err)
	}

	buf := make([]byte, udpMaxEnvelopeBytes)
	n, err := unix.Read(right, buf)
	if err != nil {
		t.Fatalf("read max-size datagram: %v", err)
	}
	if n != len(envelope) {
		t.Fatalf("read %d bytes, want %d (datagram truncated)", n, len(envelope))
	}
	if !bytes.Equal(buf[:n], envelope) {
		t.Fatal("max-size datagram corrupted in transit")
	}
}

func mustResolveUDPAddr(t *testing.T, address string) *net.UDPAddr {
	t.Helper()
	addr, err := net.ResolveUDPAddr("udp", address)
	if err != nil {
		t.Fatal(err)
	}
	return addr
}
