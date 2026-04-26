//go:build windows

package tailscale

import "fmt"

type HttpFdRequest struct {
	RequestBodyFD  int
	ResponseBodyFD int
}

type HttpBinding struct {
	ID             int64
	TailnetAddress string
	TailnetPort    int
}

type HttpIncomingRequest struct {
	BindingID      int64
	RequestBodyFD  int
	ResponseBodyFD int
	Method         string
	RequestURI     string
	Host           string
	Proto          string
	Headers        map[string][]string
	ContentLength  int64
	RemoteAddress  string
	RemotePort     int
	LocalAddress   string
	LocalPort      int
}

func HttpStart(
	method string,
	rawURL string,
	headersJSON string,
	contentLength int64,
	followRedirects bool,
	maxRedirects int,
) (*HttpFdRequest, error) {
	return nil, fmt.Errorf("HTTP fd transport is not supported on this platform")
}

func HttpBind(tailnetPort int) (*HttpBinding, error) {
	return nil, fmt.Errorf("HTTP fd transport is not supported on this platform")
}

func HttpAccept(bindingID int64) (*HttpIncomingRequest, bool, error) {
	return nil, true, nil
}

func HttpCloseBinding(bindingID int64) {}

func closeAllHttpBindings() {}
