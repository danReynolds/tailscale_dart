//go:build !windows && !darwin && !linux && !android

package tailscale

import "errors"

func newReactorPoller() (reactorPoller, error) {
	return nil, errors.New("shared fd reactor is not supported on this POSIX platform")
}

func setReactorNonblock(fd int) error {
	return errors.New("shared fd reactor is not supported on this POSIX platform")
}
