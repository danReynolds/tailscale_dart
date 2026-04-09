package main

// #include <stdlib.h>
import "C"

import (
	"encoding/json"
	"fmt"
	"sync/atomic"
	"unsafe"

	"github.com/dan/tailscale"
)

//export DuneStart
func DuneStart(hostname *C.char, authKey *C.char, controlURL *C.char, stateDir *C.char) *C.char {
	name := C.GoString(hostname)
	key := C.GoString(authKey)
	ctl := C.GoString(controlURL)
	dir := C.GoString(stateDir)

	port, err := tailscale.Start(name, key, ctl, dir)
	if err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	return C.CString(fmt.Sprintf(`{"port": %d}`, port))
}

//export DuneGetPeers
func DuneGetPeers() *C.char {
	return C.CString(tailscale.GetPeers())
}

//export DuneGetLocalIP
func DuneGetLocalIP() *C.char {
	return C.CString(tailscale.GetLocalIP())
}

//export DuneHasState
func DuneHasState(stateDir *C.char) C.int {
	dir := C.GoString(stateDir)
	if tailscale.HasState(dir) {
		return 1
	}
	return 0
}

//export DuneLogout
func DuneLogout(stateDir *C.char) {
	dir := C.GoString(stateDir)
	tailscale.Logout(dir)
}

//export DuneStop
func DuneStop() {
	tailscale.Stop()
}

//export DuneListen
func DuneListen(port C.int) {
	tailscale.DuneListen(int(port))
}

//export DuneStatus
func DuneStatus() *C.char {
	return C.CString(tailscale.DuneStatus())
}

//export DuneFree
func DuneFree(ptr *C.char) {
	C.free(unsafe.Pointer(ptr))
}

//export DuneSetLogLevel
func DuneSetLogLevel(level C.int) {
	atomic.StoreInt32(&tailscale.LogLevel, int32(level))
}

func main() {}
