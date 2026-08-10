//go:build !android && !darwin && !ios && !linux

package tailscale

import (
	"fmt"
	"os"
)

type stateResetFilesystem struct{}

type stateResetFSOption func()

func openStateResetFilesystem(string, os.FileInfo, ...stateResetFSOption) (*stateResetFilesystem, error) {
	return nil, fmt.Errorf("secure local-state reset is unsupported on this platform")
}

func (r *stateResetFilesystem) ensureDurableMarker() error {
	return fmt.Errorf("secure local-state reset is unsupported on this platform")
}

func (r *stateResetFilesystem) completeAfterCustodyDeletion() error {
	return fmt.Errorf("secure local-state reset is unsupported on this platform")
}

func (r *stateResetFilesystem) Close() error { return nil }
