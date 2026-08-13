//go:build tailscale_profile_diag

package main

// #include <stdlib.h>
import "C"

import (
	"time"

	"github.com/dan/tailscale"
)

//export DuneDebugProfileTsnet
func DuneDebugProfileTsnet(payloadJSON *C.char, timeoutMillis C.longlong) *C.char {
	var timeout time.Duration
	if timeoutMillis > 0 {
		timeout = time.Duration(timeoutMillis) * time.Millisecond
	}
	result, err := tailscale.DebugProfileTsnet(C.GoString(payloadJSON), timeout)
	if err != nil {
		return C.CString(tailscale.ErrorJSON(err))
	}
	return C.CString(string(result))
}
