package tailscale

import (
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

// TestPipe_PropagatesHalfClose confirms that when one side of a pipe closes
// its write half, the other side sees EOF on its reads but can still write in
// the reverse direction.
func TestPipe_PropagatesHalfClose(t *testing.T) {
	aLn, _ := net.Listen("tcp", "127.0.0.1:0")
	defer aLn.Close()
	bLn, _ := net.Listen("tcp", "127.0.0.1:0")
	defer bLn.Close()

	var aLocal, aPeer, bLocal, bPeer net.Conn
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		c, err := aLn.Accept()
		if err != nil {
			return
		}
		aPeer = c
	}()
	go func() {
		defer wg.Done()
		c, err := bLn.Accept()
		if err != nil {
			return
		}
		bPeer = c
	}()

	var err error
	aLocal, err = net.Dial("tcp", aLn.Addr().String())
	if err != nil {
		t.Fatalf("dial a: %v", err)
	}
	defer aLocal.Close()
	bLocal, err = net.Dial("tcp", bLn.Addr().String())
	if err != nil {
		t.Fatalf("dial b: %v", err)
	}
	defer bLocal.Close()
	wg.Wait()

	go pipe(aPeer, bPeer)

	if _, err := aLocal.Write([]byte("ping")); err != nil {
		t.Fatalf("a->b write: %v", err)
	}

	bLocal.SetReadDeadline(time.Now().Add(time.Second))
	buf := make([]byte, 4)
	if _, err := io.ReadFull(bLocal, buf); err != nil {
		t.Fatalf("b read: %v", err)
	}
	if string(buf) != "ping" {
		t.Fatalf("b got %q, want %q", buf, "ping")
	}

	if tc, ok := aLocal.(*net.TCPConn); ok {
		if err := tc.CloseWrite(); err != nil {
			t.Fatalf("closewrite a: %v", err)
		}
	}

	bLocal.SetReadDeadline(time.Now().Add(time.Second))
	n, err := bLocal.Read(buf)
	if err != io.EOF || n != 0 {
		t.Fatalf("b expected EOF after A's CloseWrite, got n=%d err=%v", n, err)
	}

	if _, err := bLocal.Write([]byte("pong")); err != nil {
		t.Fatalf("b->a write: %v", err)
	}
	aLocal.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := io.ReadFull(aLocal, buf); err != nil {
		t.Fatalf("a read: %v", err)
	}
	if string(buf) != "pong" {
		t.Fatalf("a got %q, want %q", buf, "pong")
	}
}

// TestPipe_LargePayloadRoundTrip pushes 1 MiB through the pipe to catch
// fragmentation or backpressure bugs that a tiny echo test would not surface.
func TestPipe_LargePayloadRoundTrip(t *testing.T) {
	aLn, _ := net.Listen("tcp", "127.0.0.1:0")
	defer aLn.Close()
	bLn, _ := net.Listen("tcp", "127.0.0.1:0")
	defer bLn.Close()

	var aPeer, bPeer net.Conn
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		c, _ := aLn.Accept()
		aPeer = c
	}()
	go func() {
		defer wg.Done()
		c, _ := bLn.Accept()
		bPeer = c
	}()

	aLocal, err := net.Dial("tcp", aLn.Addr().String())
	if err != nil {
		t.Fatalf("dial a: %v", err)
	}
	defer aLocal.Close()
	bLocal, err := net.Dial("tcp", bLn.Addr().String())
	if err != nil {
		t.Fatalf("dial b: %v", err)
	}
	defer bLocal.Close()
	wg.Wait()

	go pipe(aPeer, bPeer)

	const payloadSize = 1 << 20 // 1 MiB
	payload := make([]byte, payloadSize)
	for i := range payload {
		payload[i] = byte(i % 251)
	}

	writeDone := make(chan error, 1)
	go func() {
		_, err := aLocal.Write(payload)
		writeDone <- err
		if tc, ok := aLocal.(*net.TCPConn); ok {
			_ = tc.CloseWrite()
		}
	}()

	bLocal.SetReadDeadline(time.Now().Add(10 * time.Second))
	got := make([]byte, payloadSize)
	if _, err := io.ReadFull(bLocal, got); err != nil {
		t.Fatalf("b read: %v", err)
	}
	if err := <-writeDone; err != nil {
		t.Fatalf("a write: %v", err)
	}
	for i := range payload {
		if payload[i] != got[i] {
			t.Fatalf("byte %d: got 0x%02x, want 0x%02x", i, got[i], payload[i])
		}
	}
}

// TestConfigureTCP_IsNoOpOnNonTCP makes sure we don't panic on net.Pipe conns.
func TestConfigureTCP_IsNoOpOnNonTCP(t *testing.T) {
	a, b := net.Pipe()
	configureTCP(a)
	configureTCP(b)
	a.Close()
	b.Close()
}
