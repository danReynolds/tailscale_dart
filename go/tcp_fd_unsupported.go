//go:build windows

package tailscale

import (
	"errors"
	"fmt"
	"net"
	"time"
)

func TcpDialFd(runtimeToken uint64, host string, port int, timeout time.Duration) (*TcpFdConn, error) {
	if _, ok := acquireNodeGateForRuntimeToken(runtimeToken); !ok {
		return nil, fmt.Errorf(
			"%w: TcpDialFd captured runtime %d is no longer current",
			ErrRuntimeStale,
			runtimeToken,
		)
	}
	return nil, errors.New("TcpDialFd is not supported on Windows")
}

func TcpListenFd(tailnetPort int, tailnetHost string) (*TcpFdListener, error) {
	return nil, errors.New("TcpListenFd is not supported on Windows")
}

func TlsListenFd(tailnetPort int, tailnetHost string) (*TcpFdListener, error) {
	return nil, errors.New("TlsListenFd is not supported on Windows")
}

func TcpAcceptFd(listenerID int64) (*TcpFdConn, bool, error) {
	return nil, true, errors.New("TcpAcceptFd is not supported on Windows")
}

func TcpCloseFdListener(listenerID int64) {
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
