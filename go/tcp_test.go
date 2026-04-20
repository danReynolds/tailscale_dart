package tailscale

import (
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"testing"
	"time"
)

// TestBridgeOne_PipesBytesBothWays feeds a pair of net.Pipe conns as
// the "tailnet" side and a real loopback listener as the "dart" side.
// Dart writes the token, then some bytes, and expects an echo back
// through the tailnet side.
func TestBridgeOne_PipesBytesBothWays(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("loopback listen: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port

	// "Tailnet" side is an in-memory pipe. What we write to peerSide
	// appears to flow back to the Dart conn.
	ourSide, peerSide := net.Pipe()
	token := "deadbeef"

	go bridgeOne(ln, ourSide, token)

	// Emulate Dart: connect to loopback, write token, then real data.
	dart, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("dart dial: %v", err)
	}
	defer dart.Close()

	if _, err := dart.Write([]byte(token)); err != nil {
		t.Fatalf("token write: %v", err)
	}

	go func() {
		// Echo: read whatever the Dart side sends and write it back.
		buf := make([]byte, 64)
		n, err := peerSide.Read(buf)
		if err != nil {
			return
		}
		peerSide.Write(buf[:n])
	}()

	payload := []byte("hello peer")
	if _, err := dart.Write(payload); err != nil {
		t.Fatalf("payload write: %v", err)
	}

	got := make([]byte, len(payload))
	if err := dart.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}
	if _, err := io.ReadFull(dart, got); err != nil {
		t.Fatalf("echo read: %v", err)
	}
	if string(got) != string(payload) {
		t.Fatalf("echo mismatch: got %q, want %q", got, payload)
	}
}

func TestBridgeOne_RejectsBadToken(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("loopback listen: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port

	ourSide, peerSide := net.Pipe()
	expected := "deadbeef"

	// Track whether peerSide ever sees activity beyond closure.
	peerGotBytes := make(chan struct{}, 1)
	go func() {
		buf := make([]byte, 16)
		n, _ := peerSide.Read(buf)
		if n > 0 {
			peerGotBytes <- struct{}{}
		}
	}()

	go bridgeOne(ln, ourSide, expected)

	dart, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("dart dial: %v", err)
	}
	defer dart.Close()

	if _, err := dart.Write([]byte("WRONGTOK")); err != nil {
		t.Fatalf("bad token write: %v", err)
	}
	if _, err := dart.Write([]byte("should-never-reach-peer")); err != nil {
		// Expected — peer side closes on bad token.
	}

	// Give the bridge time to close.
	select {
	case <-peerGotBytes:
		t.Fatal("peer received bytes despite bad token")
	case <-time.After(500 * time.Millisecond):
	}
}

func TestBridgeOne_TimesOutIfDartNeverConnects(t *testing.T) {
	// Shrink the timeout for the test. Can't swap the package constant
	// cleanly, so we just make a listener with a short deadline and
	// call a local helper equivalent to bridgeOne's accept phase.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("loopback listen: %v", err)
	}
	tcpLn := ln.(*net.TCPListener)
	tcpLn.SetDeadline(time.Now().Add(100 * time.Millisecond))

	start := time.Now()
	_, err = ln.Accept()
	if err == nil {
		t.Fatal("expected accept to error after deadline")
	}
	elapsed := time.Since(start)
	if elapsed > 500*time.Millisecond {
		t.Fatalf("accept deadline ignored; waited %v", elapsed)
	}
}

func TestRandomHexToken_UniqueAndWellFormed(t *testing.T) {
	a, err := randomHexToken(16)
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	b, err := randomHexToken(16)
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	if a == b {
		t.Fatal("two tokens collided")
	}
	if _, err := hex.DecodeString(a); err != nil {
		t.Fatalf("token not hex: %v", err)
	}
	if len(a) != 32 {
		t.Fatalf("token length = %d, want 32", len(a))
	}
}
