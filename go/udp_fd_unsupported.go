//go:build windows

package tailscale

import "errors"

type UdpFdBinding struct {
	FD           int
	LocalAddress string
	LocalPort    int
}

func UdpBindFd(host string, port int) (*UdpFdBinding, error) {
	return nil, errors.New("UdpBindFd is not supported on Windows")
}
