//go:build !windows && (linux || android)

package tailscale

import (
	"fmt"

	"golang.org/x/sys/unix"
)

func newSocketPairCloexec(sockType int) (int, int, error) {
	fds, err := unix.Socketpair(unix.AF_UNIX, sockType|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, -1, fmt.Errorf("socketpair: %w", err)
	}
	return fds[0], fds[1], nil
}
