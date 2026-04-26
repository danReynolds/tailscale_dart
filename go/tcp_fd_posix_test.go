//go:build !windows

package tailscale

import (
	"io"
	"net"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestNewSocketPairConn_PipesBytesBothWays(t *testing.T) {
	dartFd, goConn, err := newSocketPairConn()
	if err != nil {
		t.Fatalf("newSocketPairConn: %v", err)
	}
	defer unix.Close(dartFd)
	defer goConn.Close()

	if _, err := goConn.Write([]byte("from-go")); err != nil {
		t.Fatalf("go write: %v", err)
	}
	got := make([]byte, len("from-go"))
	if _, err := unix.Read(dartFd, got); err != nil {
		t.Fatalf("fd read: %v", err)
	}
	if string(got) != "from-go" {
		t.Fatalf("fd read got %q, want %q", got, "from-go")
	}

	if _, err := unix.Write(dartFd, []byte("from-dart")); err != nil {
		t.Fatalf("fd write: %v", err)
	}
	if err := goConn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	got = make([]byte, len("from-dart"))
	if _, err := io.ReadFull(goConn, got); err != nil {
		t.Fatalf("go read: %v", err)
	}
	if string(got) != "from-dart" {
		t.Fatalf("go read got %q, want %q", got, "from-dart")
	}
}

func TestCloseAllTcpFdListenersClosesAndClearsRegistry(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}

	tcpFdListenerMu.Lock()
	tcpFdListenerRegistry[999] = ln
	tcpFdListenerMu.Unlock()

	closeAllTcpFdListeners()
	closeAllTcpFdListeners()

	tcpFdListenerMu.Lock()
	got := len(tcpFdListenerRegistry)
	tcpFdListenerMu.Unlock()
	if got != 0 {
		t.Fatalf("listener registry length = %d, want 0", got)
	}

	if _, err := ln.Accept(); err == nil {
		t.Fatal("listener was still open after closeAllTcpFdListeners")
	}
}
