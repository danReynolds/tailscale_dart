//go:build !windows

package tailscale

import "unsafe"

func unsafePointerFromInt64(v int64) unsafe.Pointer {
	return unsafe.Pointer(uintptr(v))
}

func int64FromUnsafePointer(p unsafe.Pointer) int64 {
	return int64(uintptr(p))
}
