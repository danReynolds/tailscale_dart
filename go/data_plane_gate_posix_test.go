//go:build !windows

package tailscale

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

func TestDataPlaneOffloadsRejectSupersededRuntimeBeforeReplacementDataPlane(t *testing.T) {
	superseded := newNodeRuntime(nodeEpoch.Load(), nextDirectRuntimeToken(), runtimeConfig{})
	t.Cleanup(superseded.cancel)
	withLiveServer(t, &tsnet.Server{})
	replacement := currentRuntime()
	if replacement == nil || replacement.token == superseded.token {
		t.Fatal("test requires distinct superseded and replacement runtime tokens")
	}

	offloads := []struct {
		name string
		call func(token uint64) error
	}{
		{
			name: "TcpDialFd",
			call: func(token uint64) error {
				_, err := TcpDialFd(token, "100.64.0.1", 80, time.Second)
				return err
			},
		},
		{
			name: "TcpListenFd",
			call: func(token uint64) error {
				_, err := TcpListenFd(token, 0, "")
				return err
			},
		},
		{
			name: "TlsListenFd",
			call: func(token uint64) error {
				_, err := TlsListenFd(token, 0, "")
				return err
			},
		},
		{
			name: "UdpBindFd",
			call: func(token uint64) error {
				_, err := UdpBindFd(token, "127.0.0.1", 0)
				return err
			},
		},
		{
			name: "HttpBind",
			call: func(token uint64) error {
				_, err := HttpBind(token, 0)
				return err
			},
		},
	}
	for _, tt := range offloads {
		t.Run(tt.name, func(t *testing.T) {
			for _, token := range []uint64{0, superseded.token} {
				err := tt.call(token)
				if !errors.Is(err, ErrRuntimeStale) {
					t.Fatalf("%s token %d error = %v, want ErrRuntimeStale", tt.name, token, err)
				}
				if !strings.Contains(err.Error(), "captured runtime") {
					t.Fatalf("%s token %d reached replacement data plane: %v", tt.name, token, err)
				}
			}
		})
	}
}

// TestListenBindOffloadsJoinStalledBootstrapWithoutBlockingControlPlane is the
// liveness regression for routing listen/bind off the worker FIFO. During the
// first-Up bootstrap window the ADR requires these calls to JOIN the one
// shared bootstrap result — they may not fail fast — so their readiness wait
// can park for up to the bootstrap's 30-second budget. That park must not
// serialize control-plane work behind it. The test stalls a bootstrap exactly
// where a real runtime parks (Running observed, bounded Server.Up unfinished),
// parks all four listen/bind entry points in it, proves a concurrent
// control-plane call still completes, then resolves the bootstrap and proves
// every parked call received the shared stored result.
func TestListenBindOffloadsJoinStalledBootstrapWithoutBlockingControlPlane(t *testing.T) {
	withLiveServer(t, &tsnet.Server{})
	runtime := currentRuntime()
	manager := newPublicationManagerWithClient(runtime, nil)
	runtime.publication = manager

	_, start := manager.observeState(ipn.Running)
	if start == nil {
		t.Fatal("first Running did not create the bootstrap start")
	}

	binds := []struct {
		name string
		call func() error
	}{
		{
			name: "TcpListenFd",
			call: func() error {
				_, err := TcpListenFd(runtime.token, 0, "")
				return err
			},
		},
		{
			name: "TlsListenFd",
			call: func() error {
				_, err := TlsListenFd(runtime.token, 0, "")
				return err
			},
		},
		{
			name: "UdpBindFd",
			call: func() error {
				_, err := UdpBindFd(runtime.token, "127.0.0.1", 0)
				return err
			},
		},
		{
			name: "HttpBind",
			call: func() error {
				_, err := HttpBind(runtime.token, 0)
				return err
			},
		},
	}
	results := make([]chan error, len(binds))
	for i, bind := range binds {
		result := make(chan error, 1)
		results[i] = result
		go func(call func() error) { result <- call() }(bind.call)
	}

	// Grace period, then require every call to still be parked in the shared
	// wait. A regression to fail-fast completes immediately (nothing before the
	// readiness wait blocks), while a correctly joined call cannot complete
	// before the bootstrap resolves — so waiting longer only strengthens the
	// check and can never make it flaky.
	time.Sleep(300 * time.Millisecond)
	for i, bind := range binds {
		select {
		case err := <-results[i]:
			t.Fatalf("%s did not join the stalled bootstrap: %v", bind.name, err)
		default:
		}
	}

	// The worker-FIFO face of status()/nodes()-style RPCs must stay live while
	// the four binds are parked.
	controlDone := make(chan nodeStateSnapshot, 1)
	go func() { controlDone <- debugNodeState() }()
	select {
	case snapshot := <-controlDone:
		if snapshot.TcpListeners != 0 || snapshot.UdpBridges != 0 || snapshot.HttpBindings != 0 {
			t.Fatalf("parked binds registered resources early: %+v", snapshot)
		}
	case <-time.After(time.Second):
		t.Fatal("control-plane call blocked behind parked listen/bind offloads")
	}

	failure, claimed := manager.beginBootstrapFailure(errors.New("forced Up failure"))
	if !claimed {
		t.Fatal("bootstrap failure was not claimed")
	}
	manager.finishBootstrapFailure(failure)
	close(start.done)

	for i, bind := range binds {
		select {
		case err := <-results[i]:
			if !errors.Is(err, ErrPublicationBootstrapFailure) {
				t.Fatalf("%s error = %v, want the shared ErrPublicationBootstrapFailure result", bind.name, err)
			}
		case <-time.After(time.Second):
			t.Fatalf("%s was not released by the resolved bootstrap", bind.name)
		}
	}
}

func TestDataPlaneEntrypointsRejectBeforePublicationBootstrap(t *testing.T) {
	withLiveServer(t, &tsnet.Server{})
	runtime := currentRuntime()
	runtime.publication = newPublicationManagerWithClient(runtime, nil)

	tests := []struct {
		name string
		call func() error
	}{
		{
			name: "TCP dial",
			call: func() error {
				_, err := TcpDialFd(runtime.token, "100.64.0.1", 80, time.Second)
				return err
			},
		},
		{
			name: "TCP listen",
			call: func() error {
				_, err := TcpListenFd(runtime.token, 0, "")
				return err
			},
		},
		{
			name: "TLS listen",
			call: func() error {
				_, err := TlsListenFd(runtime.token, 0, "")
				return err
			},
		},
		{
			name: "UDP bind",
			call: func() error {
				_, err := UdpBindFd(runtime.token, "127.0.0.1", 0)
				return err
			},
		},
		{
			name: "HTTP bind",
			call: func() error {
				_, err := HttpBind(runtime.token, 0)
				return err
			},
		},
		{
			name: "HTTP start",
			call: func() error {
				_, err := HttpStart(runtime.token, "GET", "http://100.64.0.1/", "", 0, false, 0)
				return err
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.call()
			if !errors.Is(err, ErrDataPlaneNotReady) {
				t.Fatalf("error = %v, want ErrDataPlaneNotReady", err)
			}
		})
	}

	jsonCalls := []struct {
		name string
		call func() string
	}{
		{
			name: "DiagPing",
			call: func() string { return DiagPing(runtime.token, "100.64.0.1", 1000, "disco") },
		},
		{
			name: "ServeForward",
			call: func() string {
				return ServeForward(runtime.token, `{"tailnetPort":443,"localPort":3000,"localAddress":"127.0.0.1","path":"/","https":true,"funnel":false}`)
			},
		},
		{
			name: "ServeClear",
			call: func() string {
				return ServeClear(`{"tailnetPort":443,"path":"/","funnel":false}`)
			},
		},
	}
	for _, tt := range jsonCalls {
		t.Run(tt.name, func(t *testing.T) {
			var result map[string]any
			out := tt.call()
			if err := json.Unmarshal([]byte(out), &result); err != nil {
				t.Fatalf("%s returned invalid JSON %q: %v", tt.name, out, err)
			}
			if result["code"] != "dataPlaneNotReady" {
				t.Fatalf("%s before publication bootstrap = %v, want dataPlaneNotReady", tt.name, result)
			}
		})
	}
}
