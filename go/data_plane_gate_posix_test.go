//go:build !windows

package tailscale

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"tailscale.com/tsnet"
)

func TestTcpDialFdRejectsSupersededRuntimeBeforeReplacementDataPlane(t *testing.T) {
	superseded := newNodeRuntime(nodeEpoch.Load(), nextDirectRuntimeToken(), runtimeConfig{})
	t.Cleanup(superseded.cancel)
	withLiveServer(t, &tsnet.Server{})
	replacement := currentRuntime()
	if replacement == nil || replacement.token == superseded.token {
		t.Fatal("test requires distinct superseded and replacement runtime tokens")
	}

	for _, token := range []uint64{0, superseded.token} {
		_, err := TcpDialFd(token, "100.64.0.1", 80, time.Second)
		if !errors.Is(err, ErrRuntimeStale) {
			t.Fatalf("TcpDialFd token %d error = %v, want ErrRuntimeStale", token, err)
		}
		if !strings.Contains(err.Error(), "captured runtime") {
			t.Fatalf("TcpDialFd token %d reached replacement data plane: %v", token, err)
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
				_, err := TcpListenFd(0, "")
				return err
			},
		},
		{
			name: "TLS listen",
			call: func() error {
				_, err := TlsListenFd(0, "")
				return err
			},
		},
		{
			name: "UDP bind",
			call: func() error {
				_, err := UdpBindFd("127.0.0.1", 0)
				return err
			},
		},
		{
			name: "HTTP bind",
			call: func() error {
				_, err := HttpBind(0)
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

	var pingResult map[string]any
	out := DiagPing(runtime.token, "100.64.0.1", 1000, "disco")
	if err := json.Unmarshal([]byte(out), &pingResult); err != nil {
		t.Fatalf("DiagPing returned invalid JSON %q: %v", out, err)
	}
	if pingResult["code"] != "dataPlaneNotReady" {
		t.Fatalf("DiagPing before publication bootstrap = %v, want dataPlaneNotReady", pingResult)
	}
}
