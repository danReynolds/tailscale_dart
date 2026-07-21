//go:build windows

package tailscale

import "errors"

type UdpFdBinding struct {
	FD           int
	BindingID    int64
	LocalAddress string
	LocalPort    int
}

func UdpBindFd(host string, port int) (*UdpFdBinding, error) {
	return nil, errors.New("UdpBindFd is not supported on Windows")
}

func UdpCloseBinding(id int64) {}
