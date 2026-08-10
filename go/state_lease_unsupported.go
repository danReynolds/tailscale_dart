//go:build !android && !darwin && !ios && !linux

package tailscale

import "fmt"

// acquireStateLease fails closed where the package has not verified advisory
// lock and ownership semantics for persistent state.
func acquireStateLease(string, ...stateLeaseOption) (*stateLease, error) {
	return nil, fmt.Errorf("persistent state leases are unsupported on this platform")
}
