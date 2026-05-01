//go:build !windows

package tailscale

import (
	"crypto/tls"
	"net/http"
	"testing"
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
