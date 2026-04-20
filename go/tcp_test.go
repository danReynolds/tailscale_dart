package tailscale

import (
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

// TestRunDialBridge_PipesBytesBothWays feeds a pair of net.Pipe conns
// as the "tailnet" side and a real loopback listener as the "dart"
// side. Dart writes the token, then some bytes, and expects an echo
// back through the tailnet side.
func TestRunDialBridge_PipesBytesBothWays(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("loopback listen: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port

	ourSide, peerSide := net.Pipe()
	token := "deadbeef"

	go runDialBridge(ln, ourSide, token)

	dart, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("dart dial: %v", err)
	}
	defer dart.Close()

	if _, err := dart.Write([]byte(token)); err != nil {
		t.Fatalf("token write: %v", err)
	}

	// Echo on the peer side.
	go func() {
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

// TestRunDialBridge_SurvivesBadTokenAttacker exercises the DoS
// mitigation: a co-resident attacker connects first and sends a
// wrong token; the bridge rejects it and keeps accepting, so the
// legitimate Dart dialer that connects after still gets through.
func TestRunDialBridge_SurvivesBadTokenAttacker(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("loopback listen: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port

	ourSide, peerSide := net.Pipe()
	token := "deadbeefcafebabe"

	go runDialBridge(ln, ourSide, token)

	// Attacker races in first, sends a bad token.
	attacker, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("attacker dial: %v", err)
	}
	if _, err := attacker.Write([]byte("BADTOKEN01234567")); err != nil {
		t.Fatalf("attacker write: %v", err)
	}
	// Attacker reads back — should get EOF (bridge closed their conn).
	attacker.SetReadDeadline(time.Now().Add(2 * time.Second))
	drain := make([]byte, 64)
	_, _ = attacker.Read(drain) // expected to EOF or error; don't fail on it.
	attacker.Close()

	// Legitimate Dart dials after.
	dart, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("dart dial: %v", err)
	}
	defer dart.Close()
	if _, err := dart.Write([]byte(token)); err != nil {
		t.Fatalf("token write: %v", err)
	}

	// Echo on the peer side.
	go func() {
		buf := make([]byte, 64)
		n, err := peerSide.Read(buf)
		if err != nil {
			return
		}
		peerSide.Write(buf[:n])
	}()

	payload := []byte("after-the-attacker")
	if _, err := dart.Write(payload); err != nil {
		t.Fatalf("payload write: %v", err)
	}
	dart.SetReadDeadline(time.Now().Add(2 * time.Second))
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(dart, got); err != nil {
		t.Fatalf("echo read: %v", err)
	}
	if string(got) != string(payload) {
		t.Fatalf("echo mismatch: got %q, want %q", got, payload)
	}
}

// TestRunDialBridge_ClosesListenerAfterAuthenticatedClient confirms the
// loopback listener is closed immediately after the legitimate Dart
// connector authenticates, rather than staying connectable for the life
// of the proxied session.
func TestRunDialBridge_ClosesListenerAfterAuthenticatedClient(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("loopback listen: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port

	ourSide, peerSide := net.Pipe()
	defer peerSide.Close()
	token := "feedfacecafebeef"

	go runDialBridge(ln, ourSide, token)

	dart, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("dart dial: %v", err)
	}
	defer dart.Close()
	if _, err := dart.Write([]byte(token)); err != nil {
		t.Fatalf("token write: %v", err)
	}

	payload := []byte("listener-claimed")
	if _, err := dart.Write(payload); err != nil {
		t.Fatalf("payload write: %v", err)
	}
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(peerSide, got); err != nil {
		t.Fatalf("peer read: %v", err)
	}
	if string(got) != string(payload) {
		t.Fatalf("peer got %q, want %q", got, payload)
	}

	second, err := net.DialTimeout(
		"tcp",
		fmt.Sprintf("127.0.0.1:%d", port),
		200*time.Millisecond,
	)
	if err == nil {
		second.Close()
		t.Fatal("second connector reached an already-claimed loopback bridge")
	}
}

// TestRunDialBridge_RejectsAllBadTokensUntilTimeout confirms the
// bridge tears itself down (closing the tailnet conn) if only
// bad-token clients show up within the accept window.
func TestRunDialBridge_RejectsAllBadTokensUntilTimeout(t *testing.T) {
	// Shrink the window via deadline manipulation. The exported
	// constant is 10s; we don't want to block the test that long, so
	// set a conservative per-step bound using our own deadline-aware
	// logic.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("loopback listen: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port

	ourSide, peerSide := net.Pipe()
	token := "correct-token-abc"

	bridgeDone := make(chan struct{})
	go func() {
		runDialBridge(ln, ourSide, token)
		close(bridgeDone)
	}()

	// Spam bad tokens until the bridge gives up. We don't wait for
	// the full 10s — instead we fire a couple of bad attempts and
	// then assert the tailnet conn eventually closes (peerSide read
	// returns EOF).
	go func() {
		for i := 0; i < 3; i++ {
			attacker, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
			if err != nil {
				return
			}
			attacker.Write([]byte("BAD-TOKEN-ATTEMPT"))
			attacker.Close()
			time.Sleep(50 * time.Millisecond)
		}
	}()

	// Ensure the peer side eventually sees EOF after the bridge
	// teardown. Use a generous deadline because the bridge has its
	// own 10s accept timeout.
	peerSide.SetReadDeadline(time.Now().Add(loopbackAcceptTimeout + 2*time.Second))
	buf := make([]byte, 16)
	_, err = peerSide.Read(buf)
	if err == nil {
		t.Fatal("peer side read succeeded; bridge did not tear down tailnet conn")
	}

	select {
	case <-bridgeDone:
	case <-time.After(loopbackAcceptTimeout + 3*time.Second):
		t.Fatal("bridge goroutine did not exit within the accept window")
	}
}

// TestRunDialBridge_TimesOutWhenNoOneConnects matches the original
// leak-prevention behavior: if neither Dart nor an attacker connects
// at all, the bridge eventually times out and closes the tailnet
// conn.
func TestRunDialBridge_TimesOutWhenNoOneConnects(t *testing.T) {
	// We can't mutate the package constant, so skip if it's too long
	// to wait for in a test (it isn't — 10s is fine).
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("loopback listen: %v", err)
	}

	ourSide, peerSide := net.Pipe()
	done := make(chan struct{})
	go func() {
		runDialBridge(ln, ourSide, "tok")
		close(done)
	}()

	peerSide.SetReadDeadline(time.Now().Add(loopbackAcceptTimeout + 2*time.Second))
	buf := make([]byte, 8)
	if _, err := peerSide.Read(buf); err == nil {
		t.Fatal("peer read succeeded without a dart connection")
	}

	select {
	case <-done:
	case <-time.After(loopbackAcceptTimeout + 3*time.Second):
		t.Fatal("runDialBridge did not return after accept timeout")
	}
}

// TestRandomHexToken_UniqueAndWellFormed confirms the generator
// returns distinct 32-char hex strings.
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

// TestPipe_PropagatesHalfClose confirms that when one side of a pipe
// closes its write half, the other side sees EOF on its reads but can
// still write in the reverse direction.
func TestPipe_PropagatesHalfClose(t *testing.T) {
	// Use real TCP conns on loopback so CloseWrite is available.
	aLn, _ := net.Listen("tcp", "127.0.0.1:0")
	defer aLn.Close()
	bLn, _ := net.Listen("tcp", "127.0.0.1:0")
	defer bLn.Close()

	// a pair: aLocal <-> aPeer piped through the bridge to bLocal <-> bPeer.
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

	// Write from A to B.
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

	// A half-closes its write side. B should see EOF on read but
	// still be able to write back.
	if tc, ok := aLocal.(*net.TCPConn); ok {
		if err := tc.CloseWrite(); err != nil {
			t.Fatalf("closewrite a: %v", err)
		}
	}

	// B reads EOF.
	bLocal.SetReadDeadline(time.Now().Add(time.Second))
	n, err := bLocal.Read(buf)
	if err != io.EOF || n != 0 {
		t.Fatalf("b expected EOF after A's CloseWrite, got n=%d err=%v", n, err)
	}

	// B writes back — should still arrive at A.
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

// TestPipe_LargePayloadRoundTrip pushes 1 MiB through the pipe to
// catch fragmentation / backpressure bugs that a tiny echo test
// wouldn't surface.
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
		payload[i] = byte(i % 251) // non-repeating-ish so off-by-one bugs are visible
	}

	writeDone := make(chan error, 1)
	go func() {
		_, err := aLocal.Write(payload)
		writeDone <- err
		if tc, ok := aLocal.(*net.TCPConn); ok {
			tc.CloseWrite()
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

// TestBindAcceptLoop_ForwardsBytes emulates the Dart side with a real
// loopback listener and the "tailnet" side with another listener; a
// client connects to the tailnet side and bytes flow through the
// bridge to an accepted loopback conn.
func TestBindAcceptLoop_ForwardsBytes(t *testing.T) {
	dartLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("dart listen: %v", err)
	}
	defer dartLn.Close()
	dartPort := dartLn.Addr().(*net.TCPAddr).Port

	tailnetLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("tailnet listen: %v", err)
	}
	tailnetPort := tailnetLn.Addr().(*net.TCPAddr).Port

	go bindAcceptLoop(tailnetLn, dartPort)

	peerConn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", tailnetPort))
	if err != nil {
		t.Fatalf("peer dial: %v", err)
	}
	defer peerConn.Close()

	dartLn.(*net.TCPListener).SetDeadline(time.Now().Add(2 * time.Second))
	dartConn, err := dartLn.Accept()
	if err != nil {
		t.Fatalf("dart accept: %v", err)
	}
	defer dartConn.Close()

	go func() {
		buf := make([]byte, 64)
		n, err := dartConn.Read(buf)
		if err != nil {
			return
		}
		dartConn.Write(buf[:n])
	}()

	payload := []byte("bind-ok")
	if _, err := peerConn.Write(payload); err != nil {
		t.Fatalf("peer write: %v", err)
	}
	if err := peerConn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(peerConn, got); err != nil {
		t.Fatalf("peer echo read: %v", err)
	}
	if string(got) != string(payload) {
		t.Fatalf("echo mismatch: got %q, want %q", got, payload)
	}
}

// TestBindAcceptLoop_ConcurrentAcceptsDontSerialize fires multiple
// tailnet connections in parallel and confirms the accept loop
// doesn't serialize them (each gets its own forwarding goroutine).
func TestBindAcceptLoop_ConcurrentAcceptsDontSerialize(t *testing.T) {
	dartLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("dart listen: %v", err)
	}
	defer dartLn.Close()
	dartPort := dartLn.Addr().(*net.TCPAddr).Port

	tailnetLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("tailnet listen: %v", err)
	}
	tailnetPort := tailnetLn.Addr().(*net.TCPAddr).Port

	go bindAcceptLoop(tailnetLn, dartPort)

	// Dart-side: accept N and hold them open until we say so.
	const n = 5
	dartLn.(*net.TCPListener).SetDeadline(time.Now().Add(3 * time.Second))
	dartConns := make(chan net.Conn, n)
	var acceptWg sync.WaitGroup
	for i := 0; i < n; i++ {
		acceptWg.Add(1)
		go func() {
			defer acceptWg.Done()
			c, err := dartLn.Accept()
			if err != nil {
				return
			}
			dartConns <- c
		}()
	}

	// Fire N peer connections concurrently.
	var dialWg sync.WaitGroup
	peerConns := make(chan net.Conn, n)
	for i := 0; i < n; i++ {
		dialWg.Add(1)
		go func() {
			defer dialWg.Done()
			c, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", tailnetPort))
			if err != nil {
				return
			}
			peerConns <- c
		}()
	}

	dialWg.Wait()
	acceptWg.Wait()
	close(dartConns)
	close(peerConns)

	var gotDart, gotPeer int
	for range dartConns {
		gotDart++
	}
	for range peerConns {
		gotPeer++
	}

	if gotDart != n {
		t.Fatalf("dart side accepted %d of %d", gotDart, n)
	}
	if gotPeer != n {
		t.Fatalf("peer side dialed %d of %d", gotPeer, n)
	}
}

// TestBindAcceptLoop_TearsDownWhenDartIsGone verifies that closing
// the Dart loopback listener causes the bridge to stop accepting
// after the next tailnet connection attempt.
func TestBindAcceptLoop_TearsDownWhenDartIsGone(t *testing.T) {
	dartLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("dart listen: %v", err)
	}
	dartPort := dartLn.Addr().(*net.TCPAddr).Port
	dartLn.Close()

	tailnetLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("tailnet listen: %v", err)
	}
	tailnetPort := tailnetLn.Addr().(*net.TCPAddr).Port

	done := make(chan struct{})
	go func() {
		bindAcceptLoop(tailnetLn, dartPort)
		close(done)
	}()

	peerConn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", tailnetPort))
	if err != nil {
		t.Fatalf("peer dial: %v", err)
	}
	peerConn.Close()

	select {
	case <-done:
	case <-time.After(bindLoopbackDialTimeout + 2*time.Second):
		t.Fatal("bridge did not tear down when loopback was unreachable")
	}
}

// TestTcpUnbind_IsIdempotent confirms calling TcpUnbind on an
// unregistered port does nothing, and the normal register+unbind
// path leaves the registry clean.
func TestTcpUnbind_IsIdempotent(t *testing.T) {
	TcpUnbind(65535)
	TcpUnbind(65535)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	tcpBindRegistryMu.Lock()
	tcpBindRegistry[port] = ln
	tcpBindRegistryMu.Unlock()

	TcpUnbind(port)
	tcpBindRegistryMu.Lock()
	_, stillPresent := tcpBindRegistry[port]
	tcpBindRegistryMu.Unlock()
	if stillPresent {
		t.Fatal("TcpUnbind did not remove registry entry")
	}

	TcpUnbind(port) // double-unbind is safe
}

// TestConfigureTCP_IsNoOpOnNonTCP makes sure we don't panic on
// net.Pipe conns (used heavily in bridge tests).
func TestConfigureTCP_IsNoOpOnNonTCP(t *testing.T) {
	a, b := net.Pipe()
	configureTCP(a)
	configureTCP(b)
	a.Close()
	b.Close()
}
