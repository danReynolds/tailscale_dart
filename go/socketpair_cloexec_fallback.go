//go:build !windows && !linux && !android

package tailscale

import (
	"fmt"

	"golang.org/x/sys/unix"
)

func newSocketPairCloexec(sockType int) (int, int, error) {
	fds, err := unix.Socketpair(unix.AF_UNIX, sockType, 0)
	if err != nil {
		return -1, -1, fmt.Errorf("socketpair: %w", err)
	}
	unix.CloseOnExec(fds[0])
	unix.CloseOnExec(fds[1])
	return fds[0], fds[1], nil
}
