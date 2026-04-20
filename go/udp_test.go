package tailscale

import (
	"bytes"
	"io"
	"net"
	"testing"
)

func TestUdpFrameRoundTripIPv4(t *testing.T) {
	var buf bytes.Buffer
	payload := []byte("hello tailnet")
	if err := writeUdpFrame(&buf, net.IPv4(100, 64, 0, 5), 7000, payload); err != nil {
		t.Fatalf("writeUdpFrame: %v", err)
	}

	ip, port, got, err := readUdpFrame(&buf)
	if err != nil {
		t.Fatalf("readUdpFrame: %v", err)
	}
	if !ip.Equal(net.IPv4(100, 64, 0, 5)) {
		t.Errorf("ip: got %v, want 100.64.0.5", ip)
	}
	if port != 7000 {
		t.Errorf("port: got %d, want 7000", port)
	}
	if !bytes.Equal(got, payload) {
		t.Errorf("payload: got %q, want %q", got, payload)
	}
}

func TestUdpFrameRoundTripIPv6(t *testing.T) {
	var buf bytes.Buffer
	ip6 := net.ParseIP("fd7a:115c:a1e0::5")
	payload := []byte{0x00, 0xff, 0xde, 0xad, 0xbe, 0xef}
	if err := writeUdpFrame(&buf, ip6, 41234, payload); err != nil {
		t.Fatalf("writeUdpFrame: %v", err)
	}

	ip, port, got, err := readUdpFrame(&buf)
	if err != nil {
		t.Fatalf("readUdpFrame: %v", err)
	}
	if !ip.Equal(ip6) {
		t.Errorf("ip: got %v, want %v", ip, ip6)
	}
	if port != 41234 {
		t.Errorf("port: got %d, want 41234", port)
	}
	if !bytes.Equal(got, payload) {
		t.Errorf("payload: got %v, want %v", got, payload)
	}
}

func TestUdpFrameRoundTripEmptyPayload(t *testing.T) {
	var buf bytes.Buffer
	if err := writeUdpFrame(&buf, net.IPv4(1, 2, 3, 4), 53, nil); err != nil {
		t.Fatalf("writeUdpFrame: %v", err)
	}
	ip, port, got, err := readUdpFrame(&buf)
	if err != nil {
		t.Fatalf("readUdpFrame: %v", err)
	}
	if !ip.Equal(net.IPv4(1, 2, 3, 4)) || port != 53 || len(got) != 0 {
		t.Errorf("unexpected: ip=%v port=%d payload=%v", ip, port, got)
	}
}

func TestUdpFrameStreamingMultipleFrames(t *testing.T) {
	var buf bytes.Buffer
	for i, p := range [][]byte{
		[]byte("one"),
		[]byte("two"),
		[]byte("three"),
	} {
		if err := writeUdpFrame(&buf, net.IPv4(10, 0, 0, byte(i)), 1000+i, p); err != nil {
			t.Fatalf("writeUdpFrame[%d]: %v", i, err)
		}
	}
	for i, want := range []string{"one", "two", "three"} {
		_, _, got, err := readUdpFrame(&buf)
		if err != nil {
			t.Fatalf("readUdpFrame[%d]: %v", i, err)
		}
		if string(got) != want {
			t.Errorf("payload[%d]: got %q, want %q", i, got, want)
		}
	}
	if _, _, _, err := readUdpFrame(&buf); err != io.EOF {
		t.Errorf("expected EOF after draining, got %v", err)
	}
}

func TestUdpFramePartialIsDetectable(t *testing.T) {
	var buf bytes.Buffer
	if err := writeUdpFrame(&buf, net.IPv4(1, 2, 3, 4), 99, []byte("incomplete")); err != nil {
		t.Fatalf("writeUdpFrame: %v", err)
	}
	// Truncate mid-payload.
	truncated := buf.Bytes()[:len(buf.Bytes())-3]
	_, _, _, err := readUdpFrame(bytes.NewReader(truncated))
	if err != io.ErrUnexpectedEOF {
		t.Errorf("expected ErrUnexpectedEOF on truncated frame, got %v", err)
	}
}

func TestUdpFrameInvalidAddrFamily(t *testing.T) {
	_, _, _, err := readUdpFrame(bytes.NewReader([]byte{7}))
	if err == nil {
		t.Error("expected error on invalid addr family byte, got nil")
	}
}
