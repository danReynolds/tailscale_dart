//go:build !android && !darwin && !ios && !linux

package tailscale

import (
	"fmt"
	"os"
)

// Persistent encrypted state is supported only where ownership can be
// verified. The package's current platform contract is Android, Darwin, and
// Linux; retaining this fail-closed stub prevents an accidental silent port.
func verifyCurrentUserOwns(os.FileInfo) error {
	return fmt.Errorf("encrypted StateStore ownership verification is unsupported on this platform")
}
