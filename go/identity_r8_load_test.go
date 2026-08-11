//go:build !windows

package tailscale

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/sys/unix"
	"tailscale.com/tsnet"
)

const r8LookupsPerWorker = 2_000

type r8LoadReceipt struct {
	count int64
	wall  time.Duration
	cpu   time.Duration
}

func (r r8LoadReceipt) throughput() float64 {
	return float64(r.count) / r.wall.Seconds()
}

func (r r8LoadReceipt) cpuPerLookup() time.Duration {
	if r.count == 0 {
		return 0
	}
	return r.cpu / time.Duration(r.count)
}

func processCPUTime() (time.Duration, error) {
	var usage unix.Rusage
	if err := unix.Getrusage(unix.RUSAGE_SELF, &usage); err != nil {
		return 0, err
	}
	return time.Duration(unix.TimevalToNsec(usage.Utime) + unix.TimevalToNsec(usage.Stime)), nil
}

func measureR8IdentityLoad(tb testing.TB, peer identityGatePeer, workers int) r8LoadReceipt {
	tb.Helper()
	cpuBefore, err := processCPUTime()
	if err != nil {
		tb.Fatalf("read process CPU before load: %v", err)
	}
	started := time.Now()
	var completed atomic.Int64
	var firstErr error
	var errOnce sync.Once
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range r8LookupsPerWorker {
				id := lookupNodeIdentity(peer.ip)
				if id == nil || id.NodeID != peer.nodeID {
					errOnce.Do(func() {
						firstErr = fmt.Errorf("identity = %#v, want node ID %q", id, peer.nodeID)
					})
					return
				}
				completed.Add(1)
			}
		}()
	}
	wg.Wait()
	wall := time.Since(started)
	cpuAfter, err := processCPUTime()
	if err != nil {
		tb.Fatalf("read process CPU after load: %v", err)
	}
	if firstErr != nil {
		tb.Fatal(firstErr)
	}
	return r8LoadReceipt{count: completed.Load(), wall: wall, cpu: cpuAfter - cpuBefore}
}

func logR8IdentityLoad(t *testing.T, path string, workers int, receipt r8LoadReceipt) {
	t.Helper()
	t.Logf(
		"  %-6s/%-2d %9.0f lookups/s, %8s CPU/lookup, CPU=%s wall=%s n=%d",
		path,
		workers,
		receipt.throughput(),
		receipt.cpuPerLookup().Round(time.Nanosecond),
		receipt.cpu.Round(time.Millisecond),
		receipt.wall.Round(time.Millisecond),
		receipt.count,
	)
}

func runR8TCPAcceptProof(peer identityGatePeer, target string, listenerID int64) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := peer.server.Dial(ctx, "tcp", target)
	if err != nil {
		return fmt.Errorf("peer dial: %w", err)
	}
	defer conn.Close()
	accepted, closed, err := TcpAcceptFd(listenerID)
	if err != nil {
		return err
	}
	if closed || accepted == nil {
		return errors.New("TCP listener closed during accept proof")
	}
	defer unix.Close(accepted.FD)
	if accepted.Identity == nil || accepted.Identity.NodeID != peer.nodeID {
		return fmt.Errorf("TCP identity = %#v, want node ID %q", accepted.Identity, peer.nodeID)
	}
	return nil
}

func runR8HTTPAcceptProof(peer identityGatePeer, target string, bindingID int64) error {
	transport := &http.Transport{
		DialContext:       peer.server.Dial,
		ForceAttemptHTTP2: false,
		DisableKeepAlives: true,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	response := make(chan error, 1)
	go func() {
		resp, err := client.Get(target)
		if err == nil {
			_, err = io.Copy(io.Discard, resp.Body)
			closeErr := resp.Body.Close()
			if err == nil {
				err = closeErr
			}
			if err == nil && resp.StatusCode != http.StatusNoContent {
				err = fmt.Errorf("HTTP status = %d, want 204", resp.StatusCode)
			}
		}
		response <- err
	}()

	request, closed, err := HttpAccept(bindingID)
	if err != nil {
		return err
	}
	if closed || request == nil {
		return errors.New("HTTP binding closed during accept proof")
	}
	if request.Identity == nil || request.Identity.NodeID != peer.nodeID {
		return fmt.Errorf("HTTP identity = %#v, want node ID %q", request.Identity, peer.nodeID)
	}
	_ = unix.Close(request.RequestBodyFD)
	responseFile := os.NewFile(uintptr(request.ResponseBodyFD), "r8-http-response")
	if responseFile == nil {
		_ = unix.Close(request.ResponseBodyFD)
		return errors.New("wrap HTTP response fd")
	}
	writeErr := writeHTTPResponseHead(responseFile, httpResponseHead{
		StatusCode:    http.StatusNoContent,
		ContentLength: 0,
	})
	closeErr := responseFile.Close()
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	select {
	case err := <-response:
		return err
	case <-time.After(10 * time.Second):
		return errors.New("HTTP client timed out after response")
	}
}

type r8ChurnPeer struct {
	server *tsnet.Server
	dir    string
}

func startR8ChurnPeer(url, key string) (r8ChurnPeer, error) {
	dir, err := os.MkdirTemp("", "tailscale-dart-r8-churn-")
	if err != nil {
		return r8ChurnPeer{}, err
	}
	peer := &tsnet.Server{
		Hostname:   "dune-r8-churn",
		AuthKey:    key,
		ControlURL: url,
		Dir:        dir,
		Ephemeral:  true,
	}
	if err := peer.Start(); err != nil {
		_ = os.RemoveAll(dir)
		return r8ChurnPeer{}, err
	}
	lc, err := peer.LocalClient()
	if err != nil {
		_ = peer.Close()
		_ = os.RemoveAll(dir)
		return r8ChurnPeer{}, err
	}
	lc.OmitAuth = true
	deadline := time.Now().Add(30 * time.Second)
	for {
		status, statusErr := lc.Status(context.Background())
		if statusErr == nil && status != nil && status.Self != nil &&
			len(status.Self.TailscaleIPs) > 0 && status.Self.ID != "" {
			return r8ChurnPeer{server: peer, dir: dir}, nil
		}
		if time.Now().After(deadline) {
			_ = peer.Close()
			_ = os.RemoveAll(dir)
			return r8ChurnPeer{}, fmt.Errorf("churn peer did not join: %w", statusErr)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func (p r8ChurnPeer) close() error {
	if p.server == nil {
		return nil
	}
	return errors.Join(p.server.Close(), os.RemoveAll(p.dir))
}

func measureR8NetmapChurn(
	t *testing.T,
	peer identityGatePeer,
	churnDone <-chan r8ChurnResult,
) (r8LoadReceipt, r8ChurnResult) {
	t.Helper()
	cpuBefore, err := processCPUTime()
	if err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	var count atomic.Int64
	var firstErr atomic.Pointer[error]
	stop := make(chan struct{})
	var result r8ChurnResult
	go func() {
		result = <-churnDone
		// Leave one watcher debounce window after the join receipt so the new
		// netmap can replace the cache while lookups are still active.
		time.Sleep(250 * time.Millisecond)
		close(stop)
	}()
	var wg sync.WaitGroup
	for range 32 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				id := lookupNodeIdentity(peer.ip)
				if id == nil || id.NodeID != peer.nodeID {
					err := fmt.Errorf("churn identity = %#v, want node ID %q", id, peer.nodeID)
					firstErr.CompareAndSwap(nil, &err)
					return
				}
				if count.Add(1)%1_000 == 0 {
					runtime.Gosched()
				}
			}
		}()
	}
	wg.Wait()
	if err := firstErr.Load(); err != nil {
		t.Fatal(*err)
	}
	cpuAfter, err := processCPUTime()
	if err != nil {
		t.Fatal(err)
	}
	return r8LoadReceipt{count: count.Load(), wall: time.Since(started), cpu: cpuAfter - cpuBefore}, result
}

type r8ChurnResult struct {
	peer r8ChurnPeer
	err  error
}

// TestR8IdentityLoadReceipt measures sustained CPU/throughput for the exact
// accept-time identity lookup at 1/8/32 callers, proves both TCP and HTTP
// accept adapters attach the independently reported peer, and keeps lookups
// active while a real Headscale peer join replaces the watcher's netmap cache.
func TestR8IdentityLoadReceipt(t *testing.T) {
	selfIP := startTestNode(t)
	StartWatch()
	peer := startIdentityGatePeer(t)
	addr, identity := waitForIdentityGatePeer(t, peer)
	runtime := currentRuntime()
	if runtime == nil {
		t.Fatal("package runtime is unavailable")
	}
	deadline := time.Now().Add(30 * time.Second)
	for {
		if err := runtime.gate().awaitDataPlaneReadyForCall(); err == nil {
			break
		} else if time.Now().After(deadline) {
			t.Fatalf("await package data plane: %v", err)
		}
		time.Sleep(100 * time.Millisecond)
	}

	t.Log("R8 sustained identity load — path/concurrency")
	for _, workers := range []int{1, 8, 32} {
		runtime.identity.replace(map[netip.Addr]*nodeIdentity{addr: identity})
		logR8IdentityLoad(t, "cached", workers, measureR8IdentityLoad(t, peer, workers))
		runtime.identity.invalidate()
		logR8IdentityLoad(t, "direct", workers, measureR8IdentityLoad(t, peer, workers))
	}

	tcpListener, err := TcpListenFd(runtime.token, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	defer TcpCloseFdListener(tcpListener.ID)
	httpBinding, err := HttpBind(runtime.token, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer HttpCloseBinding(httpBinding.ID)
	tcpTarget := net.JoinHostPort(selfIP, fmt.Sprint(tcpListener.LocalPort))
	httpTarget := fmt.Sprintf("http://%s/", net.JoinHostPort(selfIP, fmt.Sprint(httpBinding.TailnetPort)))
	for _, path := range []string{"cached", "direct"} {
		if path == "cached" {
			runtime.identity.replace(map[netip.Addr]*nodeIdentity{addr: identity})
		} else {
			runtime.identity.invalidate()
		}
		if err := runR8TCPAcceptProof(peer, tcpTarget, tcpListener.ID); err != nil {
			t.Fatalf("%s TCP accept proof: %v", path, err)
		}
		if err := runR8HTTPAcceptProof(peer, httpTarget, httpBinding.ID); err != nil {
			t.Fatalf("%s HTTP accept proof: %v", path, err)
		}
	}
	t.Log("R8 end-to-end TCP/HTTP accept identity: cached and direct paths passed")

	runtime.identity.replace(map[netip.Addr]*nodeIdentity{addr: identity})
	churnDone := make(chan r8ChurnResult, 1)
	go func() {
		p, err := startR8ChurnPeer(os.Getenv("HEADSCALE_URL"), os.Getenv("HEADSCALE_AUTH_KEY"))
		churnDone <- r8ChurnResult{peer: p, err: err}
	}()
	churnReceipt, churn := measureR8NetmapChurn(t, peer, churnDone)
	logR8IdentityLoad(t, "churn", 32, churnReceipt)
	if churn.err != nil {
		t.Fatalf("control-plane churn: %v", churn.err)
	}
	if err := churn.peer.close(); err != nil {
		t.Fatalf("close churn peer: %v", err)
	}
	runtime.identity.invalidate()
}
