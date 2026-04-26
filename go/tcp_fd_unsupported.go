//go:build windows

package tailscale

import (
	"errors"
	"net"
	"time"
)

func TcpDialFd(host string, port int, timeout time.Duration) (*TcpFdConn, error) {
	return nil, errors.New("TcpDialFd is not supported on Windows")
}

func TcpListenFd(tailnetPort int, tailnetHost string) (*TcpFdListener, error) {
	return nil, errors.New("TcpListenFd is not supported on Windows")
}

func TcpAcceptFd(listenerID int64) (*TcpFdConn, bool, error) {
	return nil, true, errors.New("TcpAcceptFd is not supported on Windows")
}

func TcpCloseFdListener(listenerID int64) {
}

func closeAllTcpFdListeners() {
}

func newSocketPairConn() (int, net.Conn, error) {
	return -1, nil, errors.New("socketpair is not supported on Windows")
}

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
