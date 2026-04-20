package main

// #include <stdlib.h>
import "C"

import (
	"encoding/json"
	"fmt"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/dan/tailscale"
)

//export DuneStart
func DuneStart(hostname *C.char, authKey *C.char, controlURL *C.char, stateDir *C.char) *C.char {
	name := C.GoString(hostname)
	key := C.GoString(authKey)
	ctl := C.GoString(controlURL)
	dir := C.GoString(stateDir)

	port, proxyAuthToken, err := tailscale.Start(name, key, ctl, dir)
	if err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	result, _ := json.Marshal(map[string]any{
		"proxyPort":      port,
		"proxyAuthToken": proxyAuthToken,
	})
	return C.CString(string(result))
}

//export DuneListen
func DuneListen(localPort C.int, tailnetPort C.int) *C.char {
	port, err := tailscale.Listen(int(localPort), int(tailnetPort))
	if err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	return C.CString(fmt.Sprintf(`{"listenPort": %d}`, port))
}

//export DuneTcpDial
func DuneTcpDial(host *C.char, port C.int, timeoutMillis C.longlong) *C.char {
	h := C.GoString(host)
	var timeout time.Duration
	if timeoutMillis > 0 {
		timeout = time.Duration(timeoutMillis) * time.Millisecond
	}

	loopbackPort, token, err := tailscale.TcpDial(h, int(port), timeout)
	if err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	result, _ := json.Marshal(map[string]any{
		"loopbackPort": loopbackPort,
		"token":        token,
	})
	return C.CString(string(result))
}

//export DuneTcpBind
func DuneTcpBind(tailnetPort C.int, tailnetHost *C.char, loopbackPort C.int) *C.char {
	host := C.GoString(tailnetHost)
	actualPort, err := tailscale.TcpBind(int(tailnetPort), host, int(loopbackPort))
	if err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	result, _ := json.Marshal(map[string]any{
		"tailnetPort": actualPort,
	})
	return C.CString(string(result))
}

//export DuneTcpUnbind
func DuneTcpUnbind(loopbackPort C.int) {
	tailscale.TcpUnbind(int(loopbackPort))
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
func DuneLogout(stateDir *C.char) *C.char {
	dir := C.GoString(stateDir)
	if err := tailscale.Logout(dir); err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	return C.CString(`{"ok":true}`)
}

//export DuneStop
func DuneStop() {
	tailscale.Stop()
}

//export DuneStatus
func DuneStatus() *C.char {
	return C.CString(tailscale.DuneStatus())
}

//export DunePeers
func DunePeers() *C.char {
	return C.CString(tailscale.DunePeers())
}

//export DuneFree
func DuneFree(ptr *C.char) {
	C.free(unsafe.Pointer(ptr))
}

//export DuneSetLogLevel
func DuneSetLogLevel(level C.int) {
	atomic.StoreInt32(&tailscale.LogLevel, int32(level))
}

//export DuneInitDartAPI
func DuneInitDartAPI(data unsafe.Pointer) C.int {
	if tailscale.InitializeDartAPI(data) {
		return 0
	}
	return -1
}

//export DuneSetDartPort
func DuneSetDartPort(port C.int64_t) {
	tailscale.SetDartPort(int64(port))
}

//export DuneStartWatch
func DuneStartWatch() {
	tailscale.StartWatch()
}

//export DuneStopWatch
func DuneStopWatch() {
	tailscale.StopWatch()
}

func main() {}
