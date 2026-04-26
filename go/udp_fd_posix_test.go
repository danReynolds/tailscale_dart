//go:build !windows

package tailscale

import (
	"bytes"
	"net"
	"testing"

	"golang.org/x/sys/unix"
)

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

func mustResolveUDPAddr(t *testing.T, address string) *net.UDPAddr {
	t.Helper()
	addr, err := net.ResolveUDPAddr("udp", address)
	if err != nil {
		t.Fatal(err)
	}
	return addr
}
