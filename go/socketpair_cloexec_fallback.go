//go:build !windows && !linux && !android

package tailscale

import (
	"fmt"

	"golang.org/x/sys/unix"
)

// newSocketPairCloexec is the fallback for platforms (notably Darwin/iOS)
// without atomic SOCK_CLOEXEC on socketpair; the Linux build sets the flag
// atomically in socketpair_cloexec_linux.go. Here CloseOnExec is applied right
// after creation, which leaves a small non-atomic window: a concurrent
// fork+exec on another thread could inherit these fds (each a plaintext
// capability for a tailnet stream). This is a known platform limitation — there
// is no atomic primitive to close it — so embedders that exec child processes
// while the node is active should prefer POSIX_SPAWN_CLOEXEC_DEFAULT.
func newSocketPairCloexec(sockType int) (int, int, error) {
	fds, err := unix.Socketpair(unix.AF_UNIX, sockType, 0)
	if err != nil {
		return -1, -1, fmt.Errorf("socketpair: %w", err)
	}
	unix.CloseOnExec(fds[0])
	unix.CloseOnExec(fds[1])
	return fds[0], fds[1], nil
}
