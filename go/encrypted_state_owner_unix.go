//go:build android || darwin || ios || linux

package tailscale

import (
	"fmt"
	"os"
	"syscall"
)

// verifyCurrentUserOwns fails closed when the supported POSIX targets cannot
// prove that a sensitive package-owned path belongs to this process's user.
func verifyCurrentUserOwns(info os.FileInfo) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("ownership metadata is unavailable")
	}
	if stat.Uid != uint32(os.Geteuid()) {
		return fmt.Errorf("path is not owned by the current user")
	}
	return nil
}
