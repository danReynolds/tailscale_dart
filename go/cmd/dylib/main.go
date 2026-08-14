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
	"fmt"
	"time"
	"unsafe"

	"github.com/dan/tailscale"
)

//export DuneStart
func DuneStart(requestToken C.ulonglong, hostname *C.char, authKey *C.char, controlURL *C.char, ephemeral C.int, hostNetworkSnapshot *C.char, bootstrapBudgetMillis C.longlong) *C.char {
	name := C.GoString(hostname)
	key := C.GoString(authKey)
	ctl := C.GoString(controlURL)
	network := C.GoString(hostNetworkSnapshot)
	budgetMillis := int64(bootstrapBudgetMillis)
	if budgetMillis < 0 {
		budgetMillis = 0
	}
	const maxDurationMillis = int64(^uint64(0)>>1) / int64(time.Millisecond)
	if budgetMillis > maxDurationMillis {
		budgetMillis = maxDurationMillis
	}

	alreadyActive, runtimeToken, err := tailscale.StartRuntimeWithBootstrapBudget(
		uint64(requestToken),
		name,
		key,
		ctl,
		ephemeral != 0,
		network,
		time.Duration(budgetMillis)*time.Millisecond,
	)
	if err != nil {
		return lifecycleError(err)
	}
	b, _ := json.Marshal(map[string]any{
		"ok":            true,
		"alreadyActive": alreadyActive,
		"runtimeToken":  runtimeToken,
	})
	return C.CString(string(b))
}

//export DuneMarkUpSettled
func DuneMarkUpSettled(runtimeToken C.ulonglong) {
	tailscale.MarkRuntimeUpSettled(uint64(runtimeToken))
}

//export DuneConfigure
func DuneConfigure(stateRoot *C.char, keybayNamespace *C.char, logLevel C.int, noLogsNoSupport C.int) *C.char {
	resolved, err := tailscale.Configure(
		C.GoString(stateRoot),
		C.GoString(keybayNamespace),
		int32(logLevel),
		int32(noLogsNoSupport),
	)
	if err != nil {
		return lifecycleError(err)
	}
	b, _ := json.Marshal(map[string]any{"stateDir": resolved})
	return C.CString(string(b))
}

//export DuneSetEphemeralScratchParent
func DuneSetEphemeralScratchParent(parent *C.char) {
	tailscale.SetEphemeralScratchParent(C.GoString(parent))
}

//export DuneBeginPersistentPreparation
func DuneBeginPersistentPreparation(requestToken C.ulonglong) *C.char {
	if err := tailscale.BeginPersistentPreparation(uint64(requestToken)); err != nil {
		return lifecycleError(err)
	}
	return C.CString(`{"ok":true}`)
}

//export DuneInspectPersistentPreparation
func DuneInspectPersistentPreparation(requestToken C.ulonglong) *C.char {
	layout, err := tailscale.InspectPersistentPreparation(uint64(requestToken))
	if err != nil {
		return lifecycleError(err)
	}
	b, _ := json.Marshal(map[string]any{"layout": layout})
	return C.CString(string(b))
}

//export DuneMarkCustodyActive
func DuneMarkCustodyActive(requestToken C.ulonglong) *C.char {
	if err := tailscale.MarkCustodyActive(uint64(requestToken)); err != nil {
		return lifecycleError(err)
	}
	return C.CString(`{"ok":true}`)
}

//export DuneMarkCustodyWriteAttempted
func DuneMarkCustodyWriteAttempted(requestToken C.ulonglong) *C.char {
	if err := tailscale.MarkCustodyWriteAttempted(uint64(requestToken)); err != nil {
		return lifecycleError(err)
	}
	return C.CString(`{"ok":true}`)
}

//export DuneResolvePersistentCustody
func DuneResolvePersistentCustody(requestToken C.ulonglong, dekPresent C.int) *C.char {
	action, err := tailscale.ResolvePersistentCustody(uint64(requestToken), dekPresent != 0)
	if err != nil {
		return lifecycleError(err)
	}
	b, _ := json.Marshal(map[string]any{"action": action})
	return C.CString(string(b))
}

//export DuneSupplyPreparedDEK
func DuneSupplyPreparedDEK(requestToken C.ulonglong, key *C.uint8_t, keyLength C.longlong) *C.char {
	if keyLength != C.longlong(32) || key == nil {
		err := fmt.Errorf("%w: got %d bytes, want 32", tailscale.ErrInvalidStateKey, int64(keyLength))
		return lifecycleError(err)
	}
	raw := unsafe.Slice((*byte)(unsafe.Pointer(key)), 32)
	if err := tailscale.SupplyPreparedDEK(uint64(requestToken), raw); err != nil {
		return lifecycleError(err)
	}
	return C.CString(`{"ok":true}`)
}

//export DunePreparePersistentState
func DunePreparePersistentState(requestToken C.ulonglong) *C.char {
	empty, err := tailscale.PreparePersistentState(uint64(requestToken))
	if err != nil {
		return lifecycleError(err)
	}
	b, _ := json.Marshal(map[string]any{"empty": empty})
	return C.CString(string(b))
}

//export DuneCompletePersistentCustody
func DuneCompletePersistentCustody(requestToken C.ulonglong) *C.char {
	if err := tailscale.CompletePersistentCustody(uint64(requestToken)); err != nil {
		return lifecycleError(err)
	}
	return C.CString(`{"ok":true}`)
}

//export DuneFinishPreparedPersistentState
func DuneFinishPreparedPersistentState(requestToken C.ulonglong) *C.char {
	if err := tailscale.FinishPreparedPersistentState(uint64(requestToken)); err != nil {
		return lifecycleError(err)
	}
	return C.CString(`{"ok":true}`)
}

//export DuneBeginLocalReset
func DuneBeginLocalReset(requestToken C.ulonglong) *C.char {
	result, err := tailscale.BeginLocalReset(uint64(requestToken))
	if err != nil {
		return lifecycleErrorWithFields(err, map[string]any{
			"token":   result.Token,
			"stopped": result.Stopped,
		})
	}
	b, _ := json.Marshal(result)
	return C.CString(string(b))
}

//export DuneFinishLocalReset
func DuneFinishLocalReset(requestToken C.ulonglong, custodyDeletionSucceeded C.int) *C.char {
	if err := tailscale.FinishLocalReset(uint64(requestToken), custodyDeletionSucceeded != 0); err != nil {
		return lifecycleError(err)
	}
	return C.CString(`{"ok":true}`)
}

//export DuneFinishCustody
func DuneFinishCustody(requestToken C.ulonglong, cleanupSucceeded C.int) *C.char {
	if err := tailscale.FinishCustody(uint64(requestToken), cleanupSucceeded != 0); err != nil {
		return lifecycleError(err)
	}
	return C.CString(`{"ok":true}`)
}

//export DuneHttpStart
func DuneHttpStart(runtimeToken C.ulonglong, method *C.char, url *C.char, headersJSON *C.char, contentLength C.longlong, followRedirects C.int, maxRedirects C.int) *C.char {
	req, err := tailscale.HttpStart(
		uint64(runtimeToken),
		C.GoString(method),
		C.GoString(url),
		C.GoString(headersJSON),
		int64(contentLength),
		followRedirects != 0,
		int(maxRedirects),
	)
	if err != nil {
		return C.CString(tailscale.ErrorJSON(err))
	}
	result, _ := json.Marshal(map[string]any{
		"requestBodyFd":  req.RequestBodyFD,
		"responseBodyFd": req.ResponseBodyFD,
	})
	return C.CString(string(result))
}

//export DuneHttpBind
func DuneHttpBind(runtimeToken C.ulonglong, tailnetPort C.int) *C.char {
	binding, err := tailscale.HttpBind(uint64(runtimeToken), int(tailnetPort))
	if err != nil {
		return C.CString(tailscale.ErrorJSON(err))
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
	payload := map[string]any{
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
	}
	if req.Identity != nil {
		payload["identity"] = req.Identity
	}
	result, _ := json.Marshal(payload)
	return C.CString(string(result))
}

//export DuneHttpCloseBinding
func DuneHttpCloseBinding(bindingID C.longlong) {
	tailscale.HttpCloseBinding(int64(bindingID))
}

//export DuneTcpDialFd
func DuneTcpDialFd(runtimeToken C.ulonglong, host *C.char, port C.int, timeoutMillis C.longlong) *C.char {
	h := C.GoString(host)
	var timeout time.Duration
	if timeoutMillis > 0 {
		timeout = time.Duration(timeoutMillis) * time.Millisecond
	}

	conn, err := tailscale.TcpDialFd(uint64(runtimeToken), h, int(port), timeout)
	if err != nil {
		return C.CString(tailscale.ErrorJSON(err))
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
func DuneTcpListenFd(runtimeToken C.ulonglong, tailnetPort C.int, tailnetHost *C.char) *C.char {
	host := C.GoString(tailnetHost)
	listener, err := tailscale.TcpListenFd(uint64(runtimeToken), int(tailnetPort), host)
	if err != nil {
		return C.CString(tailscale.ErrorJSON(err))
	}
	result, _ := json.Marshal(map[string]any{
		"listenerId":   listener.ID,
		"localAddress": listener.LocalAddress,
		"localPort":    listener.LocalPort,
	})
	return C.CString(string(result))
}

//export DuneTlsListenFd
func DuneTlsListenFd(runtimeToken C.ulonglong, tailnetPort C.int, tailnetHost *C.char) *C.char {
	host := C.GoString(tailnetHost)
	listener, err := tailscale.TlsListenFd(uint64(runtimeToken), int(tailnetPort), host)
	if err != nil {
		return C.CString(tailscale.ErrorJSON(err))
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
	payload := map[string]any{
		"fd":            conn.FD,
		"localAddress":  conn.LocalAddress,
		"localPort":     conn.LocalPort,
		"remoteAddress": conn.RemoteAddress,
		"remotePort":    conn.RemotePort,
	}
	if conn.Identity != nil {
		payload["identity"] = conn.Identity
	}
	result, _ := json.Marshal(payload)
	return C.CString(string(result))
}

//export DuneTcpCloseFdListener
func DuneTcpCloseFdListener(listenerID C.longlong) {
	tailscale.TcpCloseFdListener(int64(listenerID))
}

//export DuneUdpBindFd
func DuneUdpBindFd(runtimeToken C.ulonglong, host *C.char, port C.int) *C.char {
	h := C.GoString(host)
	binding, err := tailscale.UdpBindFd(uint64(runtimeToken), h, int(port))
	if err != nil {
		return C.CString(tailscale.ErrorJSON(err))
	}
	result, _ := json.Marshal(map[string]any{
		"fd":           binding.FD,
		"bindingId":    binding.BindingID,
		"localAddress": binding.LocalAddress,
		"localPort":    binding.LocalPort,
	})
	return C.CString(string(result))
}

//export DuneUdpCloseBinding
func DuneUdpCloseBinding(bindingID C.longlong) {
	tailscale.UdpCloseBinding(int64(bindingID))
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
func DuneDiagPing(runtimeToken C.ulonglong, ip *C.char, timeoutMillis C.int, pingType *C.char) *C.char {
	return C.CString(tailscale.DiagPing(
		uint64(runtimeToken),
		C.GoString(ip),
		int(timeoutMillis),
		C.GoString(pingType),
	))
}

//export DuneDiagMetrics
func DuneDiagMetrics() *C.char {
	return C.CString(tailscale.DiagMetrics())
}

//export DuneDebugNodeState
func DuneDebugNodeState() *C.char {
	return C.CString(tailscale.DebugNodeState())
}

//export DuneDiagDERPMap
func DuneDiagDERPMap() *C.char {
	return C.CString(tailscale.DiagDERPMap())
}

//export DuneDiagCheckUpdate
func DuneDiagCheckUpdate() *C.char {
	return C.CString(tailscale.DiagCheckUpdate())
}

//export DuneLogout
func DuneLogout(requestToken C.ulonglong, hostNetworkSnapshot *C.char) *C.char {
	result, err := tailscale.LogoutWithToken(uint64(requestToken), C.GoString(hostNetworkSnapshot))
	if err != nil {
		return lifecycleErrorWithFields(err, logoutDisposition(result))
	}
	b, _ := json.Marshal(result)
	return C.CString(string(b))
}

//export DuneAbandon
func DuneAbandon(requestToken C.ulonglong) *C.char {
	result, err := tailscale.AbandonRuntime(uint64(requestToken))
	if err != nil {
		return lifecycleErrorWithFields(err, runtimeCloseDisposition(result))
	}
	b, _ := json.Marshal(result)
	return C.CString(string(b))
}

//export DuneAwaitRuntimeQuiescence
func DuneAwaitRuntimeQuiescence(requestToken C.ulonglong) *C.char {
	if err := tailscale.AwaitRuntimeQuiescence(uint64(requestToken)); err != nil {
		return lifecycleError(err)
	}
	return C.CString(`{"ok":true}`)
}

//export DuneRetireAbandonedRuntimeToken
func DuneRetireAbandonedRuntimeToken(requestToken C.ulonglong) *C.char {
	tailscale.RetireAbandonedRuntimeToken(uint64(requestToken))
	return C.CString(`{"ok":true}`)
}

//export DuneAcknowledgeLifecycle
func DuneAcknowledgeLifecycle(requestToken C.ulonglong) {
	tailscale.AcknowledgeLifecycleResult(uint64(requestToken))
}

func lifecycleError(err error) *C.char {
	return lifecycleErrorWithFields(err, nil)
}

func lifecycleErrorWithFields(err error, fields map[string]any) *C.char {
	return C.CString(lifecycleErrorJSON(err, fields))
}

func lifecycleErrorJSON(err error, fields map[string]any) string {
	m := map[string]any{"error": err.Error()}
	for key, value := range fields {
		m[key] = value
	}
	if code := tailscale.LifecycleErrorCode(err); code != "" {
		m["code"] = code
	}
	b, _ := json.Marshal(m)
	return string(b)
}

func logoutDisposition(result tailscale.LogoutResult) map[string]any {
	return map[string]any{
		"token":         result.Token,
		"started":       result.Started,
		"emitStopped":   result.EmitStopped,
		"noState":       result.NoState,
		"cleanupFailed": result.CleanupFailed,
	}
}

func runtimeCloseDisposition(result tailscale.RuntimeCloseResult) map[string]any {
	return map[string]any{
		"token":              result.Token,
		"operation":          result.Operation,
		"matched":            result.Matched,
		"started":            result.Started,
		"emitStopped":        result.EmitStopped,
		"pending":            result.Pending,
		"noState":            result.NoState,
		"cleanupFailed":      result.CleanupFailed,
		"custodyHeld":        result.CustodyHeld,
		"custodyDisposition": result.CustodyDisposition,
	}
}

//export DuneStop
func DuneStop(requestToken C.ulonglong) *C.char {
	result, err := tailscale.CloseRuntime(uint64(requestToken))
	if err != nil {
		return lifecycleErrorWithFields(err, runtimeCloseDisposition(result))
	}
	b, _ := json.Marshal(result)
	return C.CString(string(b))
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

//export DuneServeForward
func DuneServeForward(runtimeToken C.ulonglong, payloadJSON *C.char) *C.char {
	return C.CString(tailscale.ServeForward(uint64(runtimeToken), C.GoString(payloadJSON)))
}

//export DuneAcknowledgePublication
func DuneAcknowledgePublication(runtimeToken, generation, mappingToken C.ulonglong) *C.char {
	if err := tailscale.AcknowledgePublication(uint64(runtimeToken), uint64(generation), uint64(mappingToken)); err != nil {
		return C.CString(tailscale.ErrorJSON(err))
	}
	return C.CString(`{"ok":true}`)
}

//export DuneFailPublicationDelivery
func DuneFailPublicationDelivery(runtimeToken C.ulonglong) *C.char {
	if err := tailscale.FailPublicationDelivery(uint64(runtimeToken)); err != nil {
		return C.CString(tailscale.ErrorJSON(err))
	}
	return C.CString(`{"ok":true}`)
}

//export DuneServeClear
func DuneServeClear(payloadJSON *C.char) *C.char {
	return C.CString(tailscale.ServeClear(C.GoString(payloadJSON)))
}

//export DuneFree
func DuneFree(ptr *C.char) {
	C.free(unsafe.Pointer(ptr))
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
