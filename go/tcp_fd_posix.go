//go:build !windows

package tailscale

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

type TcpFdConn struct {
	FD            int
	LocalAddress  string
	LocalPort     int
	RemoteAddress string
	RemotePort    int
}

type TcpFdListener struct {
	ID           int64
	LocalAddress string
	LocalPort    int
}

var (
	tcpFdListenerID       int64
	tcpFdListenerRegistry = map[int64]net.Listener{}
	tcpFdListenerMu       sync.Mutex
)

// TcpDialFd opens an outbound TCP connection to a tailnet peer and returns a
// POSIX fd connected to that stream.
//
// The returned fd is owned by the caller. Go keeps the other side of a
// socketpair and pipes it to the tsnet connection.
func TcpDialFd(host string, port int, timeout time.Duration) (*TcpFdConn, error) {
	if host == "" {
		return nil, errors.New("host is required")
	}
	if port < 1 || port > 65535 {
		return nil, fmt.Errorf("invalid port %d", port)
	}

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return nil, errors.New("TcpDialFd called before Start")
	}

	ctx := context.Background()
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}

	tailConn, err := s.Dial(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return nil, fmt.Errorf("tailnet dial %s:%d: %w", host, port, err)
	}

	dartFd, goConn, err := newSocketPairConn()
	if err != nil {
		tailConn.Close()
		return nil, err
	}

	configureTCP(tailConn)
	localAddress, localPort := endpointFromAddr(tailConn.LocalAddr())
	remoteAddress, remotePort := endpointFromAddr(tailConn.RemoteAddr())
	go pipe(goConn, tailConn)
	return &TcpFdConn{
		FD:            dartFd,
		LocalAddress:  localAddress,
		LocalPort:     localPort,
		RemoteAddress: remoteAddress,
		RemotePort:    remotePort,
	}, nil
}

func TcpListenFd(tailnetPort int, tailnetHost string) (*TcpFdListener, error) {
	if tailnetPort < 0 || tailnetPort > 65535 {
		return nil, fmt.Errorf("invalid port %d", tailnetPort)
	}

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return nil, errors.New("TcpListenFd called before Start")
	}

	addr := net.JoinHostPort(tailnetHost, strconv.Itoa(tailnetPort))
	ln, err := s.Listen("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("tsnet listen %s: %w", addr, err)
	}

	return registerTcpFdListener(ln, tailnetHost)
}

func TlsListenFd(tailnetPort int, tailnetHost string) (*TcpFdListener, error) {
	if tailnetPort < 0 || tailnetPort > 65535 {
		return nil, fmt.Errorf("invalid port %d", tailnetPort)
	}

	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return nil, errors.New("TlsListenFd called before Start")
	}

	addr := net.JoinHostPort(tailnetHost, strconv.Itoa(tailnetPort))
	ln, err := s.ListenTLS("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("tsnet listen tls %s: %w", addr, err)
	}

	return registerTcpFdListener(ln, tailnetHost)
}

func registerTcpFdListener(ln net.Listener, fallbackAddress string) (*TcpFdListener, error) {
	localAddress, localPort := endpointFromAddr(ln.Addr())
	if localPort == 0 {
		ln.Close()
		return nil, fmt.Errorf("tsnet listen returned unresolved port")
	}
	if localAddress == "" {
		localAddress = fallbackAddress
	}

	id := atomic.AddInt64(&tcpFdListenerID, 1)
	tcpFdListenerMu.Lock()
	tcpFdListenerRegistry[id] = ln
	tcpFdListenerMu.Unlock()

	return &TcpFdListener{
		ID:           id,
		LocalAddress: localAddress,
		LocalPort:    localPort,
	}, nil
}

func TcpAcceptFd(listenerID int64) (*TcpFdConn, bool, error) {
	tcpFdListenerMu.Lock()
	ln := tcpFdListenerRegistry[listenerID]
	tcpFdListenerMu.Unlock()
	if ln == nil {
		return nil, true, nil
	}

	tailConn, err := ln.Accept()
	if err != nil {
		if errors.Is(err, net.ErrClosed) {
			tcpFdListenerMu.Lock()
			if tcpFdListenerRegistry[listenerID] == ln {
				delete(tcpFdListenerRegistry, listenerID)
			}
			tcpFdListenerMu.Unlock()
			return nil, true, nil
		}
		return nil, false, fmt.Errorf("tailnet accept: %w", err)
	}

	dartFd, goConn, err := newSocketPairConn()
	if err != nil {
		tailConn.Close()
		return nil, false, err
	}

	configureTCP(tailConn)
	localAddress, localPort := endpointFromAddr(tailConn.LocalAddr())
	remoteAddress, remotePort := endpointFromAddr(tailConn.RemoteAddr())
	go pipe(goConn, tailConn)
	return &TcpFdConn{
		FD:            dartFd,
		LocalAddress:  localAddress,
		LocalPort:     localPort,
		RemoteAddress: remoteAddress,
		RemotePort:    remotePort,
	}, false, nil
}

func TcpCloseFdListener(listenerID int64) {
	tcpFdListenerMu.Lock()
	ln := tcpFdListenerRegistry[listenerID]
	delete(tcpFdListenerRegistry, listenerID)
	tcpFdListenerMu.Unlock()
	if ln != nil {
		ln.Close()
	}
}

func closeAllTcpFdListeners() {
	tcpFdListenerMu.Lock()
	listeners := make([]net.Listener, 0, len(tcpFdListenerRegistry))
	for id, ln := range tcpFdListenerRegistry {
		listeners = append(listeners, ln)
		delete(tcpFdListenerRegistry, id)
	}
	tcpFdListenerMu.Unlock()

	for _, ln := range listeners {
		ln.Close()
	}
}

func endpointFromAddr(addr net.Addr) (string, int) {
	if addr == nil {
		return "", 0
	}
	host, portText, err := net.SplitHostPort(addr.String())
	if err != nil {
		return "", 0
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 0 || port > 65535 {
		return host, 0
	}
	return host, port
}

func newSocketPairConn() (int, net.Conn, error) {
	dartFd, goFd, err := newSocketPairCloexec(unix.SOCK_STREAM)
	if err != nil {
		return -1, nil, err
	}

	success := false
	defer func() {
		if success {
			return
		}
		_ = unix.Close(dartFd)
		_ = unix.Close(goFd)
	}()

	file := os.NewFile(uintptr(goFd), "tailscale-dart-tcp-go")
	if file == nil {
		return -1, nil, errors.New("socketpair fd could not be wrapped")
	}
	conn, err := net.FileConn(file)
	_ = file.Close()
	if err != nil {
		return -1, nil, fmt.Errorf("wrap socketpair fd: %w", err)
	}

	success = true
	return dartFd, conn, nil
}
