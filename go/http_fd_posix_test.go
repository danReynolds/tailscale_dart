//go:build !windows

package tailscale

import (
	"bytes"
	"crypto/tls"
	"encoding/binary"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestTailnetHTTPClientUsesTailscaleTLSVerifier(t *testing.T) {
	baseTLS := &tls.Config{ServerName: "example.test"}
	baseTransport := &http.Transport{TLSClientConfig: baseTLS}
	client := tailnetHTTPClient(&http.Client{Transport: baseTransport})

	transport, ok := client.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("transport type = %T, want *http.Transport", client.Transport)
	}
	if transport == baseTransport {
		t.Fatal("tailnetHTTPClient reused the caller's transport")
	}
	if baseTransport.TLSClientConfig != baseTLS {
		t.Fatal("tailnetHTTPClient replaced the caller's TLS config")
	}
	if transport.TLSClientConfig == nil {
		t.Fatal("TLSClientConfig was not configured")
	}
	if transport.TLSClientConfig == baseTLS {
		t.Fatal("tailnetHTTPClient reused the caller's TLS config")
	}
	if transport.TLSClientConfig.ServerName != baseTLS.ServerName {
		t.Fatalf(
			"ServerName = %q, want %q",
			transport.TLSClientConfig.ServerName,
			baseTLS.ServerName,
		)
	}
	if !transport.TLSClientConfig.InsecureSkipVerify {
		t.Fatal("TLSClientConfig does not use tailscale tlsdial verification")
	}
	if transport.TLSClientConfig.VerifyConnection == nil {
		t.Fatal("TLSClientConfig is missing tailscale tlsdial verification hook")
	}
}

func TestHTTPResponseHeadRejectsOversizedReadEnvelope(t *testing.T) {
	var prefix [4]byte
	binary.BigEndian.PutUint32(prefix[:], uint32(httpMaxHeadBytes+1))

	_, err := readHTTPResponseHead(bytes.NewReader(prefix[:]))
	if err == nil {
		t.Fatal("readHTTPResponseHead accepted an oversized envelope")
	}
	if !strings.Contains(err.Error(), "invalid HTTP response head length") {
		t.Fatalf("error = %q, want invalid length", err)
	}
}

func TestHTTPResponseHeadRejectsOversizedWriteEnvelope(t *testing.T) {
	err := writeHTTPResponseHead(&bytes.Buffer{}, httpResponseHead{
		StatusCode: http.StatusOK,
		Headers: map[string][]string{
			"x-pad": {strings.Repeat("a", httpMaxHeadBytes)},
		},
	})
	if err == nil {
		t.Fatal("writeHTTPResponseHead accepted an oversized envelope")
	}
	if !strings.Contains(err.Error(), "HTTP response head too large") {
		t.Fatalf("error = %q, want oversized head", err)
	}
}

func TestHTTPBindingServerUsesBoundedTimeouts(t *testing.T) {
	server := newHTTPBindingServer(&httpBindingState{})

	if server.ReadHeaderTimeout != 10*time.Second {
		t.Fatalf("ReadHeaderTimeout = %s, want 10s", server.ReadHeaderTimeout)
	}
	if server.IdleTimeout != 120*time.Second {
		t.Fatalf("IdleTimeout = %s, want 120s", server.IdleTimeout)
	}
}
