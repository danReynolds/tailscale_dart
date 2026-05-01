package main

// #include <stdlib.h>
// #include <stdint.h>
//
// typedef struct {
//   int64_t id;
//   int32_t events;
//   int32_t error;
// } DuneReactorEvent;
import "C"

import (
	"encoding/json"
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

	err := tailscale.Start(name, key, ctl, dir)
	if err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	return C.CString(`{"ok":true}`)
}

//export DuneSetNetworkInterfaces
func DuneSetNetworkInterfaces(snapshot *C.char) *C.char {
	if err := tailscale.ConfigureHostNetworkSnapshot(C.GoString(snapshot)); err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	return C.CString(`{"ok":true}`)
}

//export DuneHttpStart
func DuneHttpStart(method *C.char, url *C.char, headersJSON *C.char, contentLength C.longlong, followRedirects C.int, maxRedirects C.int) *C.char {
	req, err := tailscale.HttpStart(
		C.GoString(method),
		C.GoString(url),
		C.GoString(headersJSON),
		int64(contentLength),
		followRedirects != 0,
		int(maxRedirects),
	)
	if err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	result, _ := json.Marshal(map[string]any{
		"requestBodyFd":  req.RequestBodyFD,
		"responseBodyFd": req.ResponseBodyFD,
	})
	return C.CString(string(result))
}

//export DuneHttpBind
func DuneHttpBind(tailnetPort C.int) *C.char {
	binding, err := tailscale.HttpBind(int(tailnetPort))
	if err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	result, _ := json.Marshal(map[string]any{
		"bindingId":      binding.ID,
		"tailnetAddress": binding.TailnetAddress,
		"tailnetPort":    binding.TailnetPort,
	})
	return C.CString(string(result))
}

//export DuneHttpAccept
func DuneHttpAccept(bindingID C.longlong) *C.char {
	req, closed, err := tailscale.HttpAccept(int64(bindingID))
	if err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	if closed {
		return C.CString(`{"closed":true}`)
	}
	result, _ := json.Marshal(map[string]any{
		"bindingId":      req.BindingID,
		"requestBodyFd":  req.RequestBodyFD,
		"responseBodyFd": req.ResponseBodyFD,
		"method":         req.Method,
		"requestUri":     req.RequestURI,
		"host":           req.Host,
		"proto":          req.Proto,
		"headers":        req.Headers,
		"contentLength":  req.ContentLength,
		"remoteAddress":  req.RemoteAddress,
		"remotePort":     req.RemotePort,
		"localAddress":   req.LocalAddress,
		"localPort":      req.LocalPort,
	})
	return C.CString(string(result))
}

//export DuneHttpCloseBinding
func DuneHttpCloseBinding(bindingID C.longlong) {
	tailscale.HttpCloseBinding(int64(bindingID))
}

//export DuneTcpDialFd
func DuneTcpDialFd(host *C.char, port C.int, timeoutMillis C.longlong) *C.char {
	h := C.GoString(host)
	var timeout time.Duration
	if timeoutMillis > 0 {
		timeout = time.Duration(timeoutMillis) * time.Millisecond
	}

	conn, err := tailscale.TcpDialFd(h, int(port), timeout)
	if err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	result, _ := json.Marshal(map[string]any{
		"fd":            conn.FD,
		"localAddress":  conn.LocalAddress,
		"localPort":     conn.LocalPort,
		"remoteAddress": conn.RemoteAddress,
		"remotePort":    conn.RemotePort,
	})
	return C.CString(string(result))
}

//export DuneTcpListenFd
func DuneTcpListenFd(tailnetPort C.int, tailnetHost *C.char) *C.char {
	host := C.GoString(tailnetHost)
	listener, err := tailscale.TcpListenFd(int(tailnetPort), host)
	if err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	result, _ := json.Marshal(map[string]any{
		"listenerId":   listener.ID,
		"localAddress": listener.LocalAddress,
		"localPort":    listener.LocalPort,
	})
	return C.CString(string(result))
}

//export DuneTlsListenFd
func DuneTlsListenFd(tailnetPort C.int, tailnetHost *C.char) *C.char {
	host := C.GoString(tailnetHost)
	listener, err := tailscale.TlsListenFd(int(tailnetPort), host)
	if err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	result, _ := json.Marshal(map[string]any{
		"listenerId":   listener.ID,
		"localAddress": listener.LocalAddress,
		"localPort":    listener.LocalPort,
	})
	return C.CString(string(result))
}

//export DuneTcpAcceptFd
func DuneTcpAcceptFd(listenerID C.longlong) *C.char {
	conn, closed, err := tailscale.TcpAcceptFd(int64(listenerID))
	if err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	if closed {
		return C.CString(`{"closed": true}`)
	}
	result, _ := json.Marshal(map[string]any{
		"fd":            conn.FD,
		"localAddress":  conn.LocalAddress,
		"localPort":     conn.LocalPort,
		"remoteAddress": conn.RemoteAddress,
		"remotePort":    conn.RemotePort,
	})
	return C.CString(string(result))
}

//export DuneTcpCloseFdListener
func DuneTcpCloseFdListener(listenerID C.longlong) {
	tailscale.TcpCloseFdListener(int64(listenerID))
}

//export DuneUdpBindFd
func DuneUdpBindFd(host *C.char, port C.int) *C.char {
	h := C.GoString(host)
	binding, err := tailscale.UdpBindFd(h, int(port))
	if err != nil {
		m := map[string]string{"error": err.Error()}
		b, _ := json.Marshal(m)
		return C.CString(string(b))
	}
	result, _ := json.Marshal(map[string]any{
		"fd":           binding.FD,
		"localAddress": binding.LocalAddress,
		"localPort":    binding.LocalPort,
	})
	return C.CString(string(result))
}

//export DuneReactorCreate
func DuneReactorCreate() C.longlong {
	handle, err := tailscale.ReactorCreate()
	if err != nil {
		return -1
	}
	return C.longlong(handle)
}

//export DuneReactorClose
func DuneReactorClose(handle C.longlong) C.int {
	if err := tailscale.ReactorClose(int64(handle)); err != nil {
		return -1
	}
	return 0
}

//export DuneReactorWake
func DuneReactorWake(handle C.longlong) C.int {
	if err := tailscale.ReactorWake(int64(handle)); err != nil {
		return -1
	}
	return 0
}

//export DuneReactorRegister
func DuneReactorRegister(handle C.longlong, fd C.int, transportID C.longlong, events C.int) C.int {
	if err := tailscale.ReactorRegister(
		int64(handle),
		int(fd),
		int64(transportID),
		int(events),
	); err != nil {
		return -1
	}
	return 0
}

//export DuneReactorUpdate
func DuneReactorUpdate(handle C.longlong, fd C.int, transportID C.longlong, events C.int) C.int {
	if err := tailscale.ReactorUpdate(
		int64(handle),
		int(fd),
		int64(transportID),
		int(events),
	); err != nil {
		return -1
	}
	return 0
}

//export DuneReactorUnregister
func DuneReactorUnregister(handle C.longlong, fd C.int) C.int {
	if err := tailscale.ReactorUnregister(int64(handle), int(fd)); err != nil {
		return -1
	}
	return 0
}

//export DuneReactorWait
func DuneReactorWait(handle C.longlong, events unsafe.Pointer, maxEvents C.int, timeoutMillis C.int) C.int {
	n, err := tailscale.ReactorWait(
		int64(handle),
		events,
		int(maxEvents),
		int(timeoutMillis),
	)
	if err != nil {
		return -1
	}
	return C.int(n)
}

//export DuneWhoIs
func DuneWhoIs(ip *C.char) *C.char {
	return C.CString(tailscale.WhoIs(C.GoString(ip)))
}

//export DuneTlsDomains
func DuneTlsDomains() *C.char {
	return C.CString(tailscale.TlsDomains())
}

//export DuneDiagPing
func DuneDiagPing(ip *C.char, timeoutMillis C.int, pingType *C.char) *C.char {
	return C.CString(tailscale.DiagPing(
		C.GoString(ip),
		int(timeoutMillis),
		C.GoString(pingType),
	))
}

//export DuneDiagMetrics
func DuneDiagMetrics() *C.char {
	return C.CString(tailscale.DiagMetrics())
}

//export DuneDiagDERPMap
func DuneDiagDERPMap() *C.char {
	return C.CString(tailscale.DiagDERPMap())
}

//export DuneDiagCheckUpdate
func DuneDiagCheckUpdate() *C.char {
	return C.CString(tailscale.DiagCheckUpdate())
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

//export DunePrefsGet
func DunePrefsGet() *C.char {
	return C.CString(tailscale.PrefsGet())
}

//export DunePrefsUpdate
func DunePrefsUpdate(updateJSON *C.char) *C.char {
	return C.CString(tailscale.PrefsUpdate(C.GoString(updateJSON)))
}

//export DuneExitNodeSuggest
func DuneExitNodeSuggest() *C.char {
	return C.CString(tailscale.ExitNodeSuggest())
}

//export DuneExitNodeUseAuto
func DuneExitNodeUseAuto() *C.char {
	return C.CString(tailscale.ExitNodeUseAuto())
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
