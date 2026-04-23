package tailscale

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
)

const httpStreamChunkSize = 32 * 1024

type httpOpenRequest struct {
	RequestID            int                 `json:"requestId"`
	Method               string              `json:"method"`
	URL                  string              `json:"url"`
	Headers              map[string][]string `json:"headers,omitempty"`
	FollowRedirects      bool                `json:"followRedirects"`
	MaxRedirects         int                 `json:"maxRedirects"`
	PersistentConnection bool                `json:"persistentConnection"`
}

type httpBodyChunkRequest struct {
	RequestID int    `json:"requestId"`
	BodyB64   string `json:"bodyB64"`
}

type httpRequestControl struct {
	RequestID int `json:"requestId"`
}

type httpInFlightRequest struct {
	cancel      context.CancelFunc
	requestBody *io.PipeWriter
	done        chan struct{}
	doneOnce    sync.Once
}

var (
	httpRequestsMu sync.Mutex
	httpRequests   = map[int]*httpInFlightRequest{}
)

func HTTPStartRequest(reqJSON string) (map[string]any, error) {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return nil, errors.New("http request requires a running tsnet server")
	}

	var reqPayload httpOpenRequest
	if err := json.Unmarshal([]byte(reqJSON), &reqPayload); err != nil {
		return nil, err
	}
	if reqPayload.RequestID <= 0 {
		return nil, errors.New("http request id must be positive")
	}
	if reqPayload.Method == "" {
		reqPayload.Method = http.MethodGet
	}

	ctx, cancel := context.WithCancel(context.Background())
	bodyReader, bodyWriter := io.Pipe()
	req, err := http.NewRequestWithContext(
		ctx,
		reqPayload.Method,
		reqPayload.URL,
		bodyReader,
	)
	if err != nil {
		cancel()
		bodyWriter.Close()
		bodyReader.Close()
		return nil, err
	}
	req.Close = !reqPayload.PersistentConnection
	for key, values := range reqPayload.Headers {
		req.Header[key] = append([]string(nil), values...)
	}

	baseClient := s.HTTPClient()
	client := *baseClient
	switch {
	case !reqPayload.FollowRedirects:
		client.CheckRedirect = func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		}
	case reqPayload.MaxRedirects > 0:
		client.CheckRedirect = func(_ *http.Request, via []*http.Request) error {
			if len(via) >= reqPayload.MaxRedirects {
				return fmt.Errorf("stopped after %d redirects", reqPayload.MaxRedirects)
			}
			return nil
		}
	}

	request := &httpInFlightRequest{
		cancel:      cancel,
		requestBody: bodyWriter,
		done:        make(chan struct{}),
	}

	httpRequestsMu.Lock()
	if _, exists := httpRequests[reqPayload.RequestID]; exists {
		httpRequestsMu.Unlock()
		cancel()
		bodyWriter.Close()
		bodyReader.Close()
		return nil, fmt.Errorf("duplicate http request id %d", reqPayload.RequestID)
	}
	httpRequests[reqPayload.RequestID] = request
	httpRequestsMu.Unlock()

	go runHTTPRequest(reqPayload.RequestID, &client, req, request)
	return map[string]any{"requestId": reqPayload.RequestID}, nil
}

func HTTPWriteBodyChunk(reqJSON string) error {
	request, body, _, err := lookupBodyChunk(reqJSON)
	if err != nil {
		return err
	}
	if len(body) == 0 {
		return nil
	}
	select {
	case <-request.done:
		return errors.New("http request is already complete")
	default:
	}
	_, err = request.requestBody.Write(body)
	return err
}

func HTTPCloseRequestBody(reqJSON string) error {
	request, err := lookupRequestControl(reqJSON)
	if err != nil {
		return err
	}
	return request.requestBody.Close()
}

func HTTPCancelRequest(reqJSON string) error {
	request, err := lookupRequestControl(reqJSON)
	if err != nil {
		return err
	}
	request.cancel()
	_ = request.requestBody.CloseWithError(context.Canceled)
	return nil
}

func lookupBodyChunk(reqJSON string) (*httpInFlightRequest, []byte, int, error) {
	var reqPayload httpBodyChunkRequest
	if err := json.Unmarshal([]byte(reqJSON), &reqPayload); err != nil {
		return nil, nil, 0, err
	}
	request, err := lookupRequest(reqPayload.RequestID)
	if err != nil {
		return nil, nil, 0, err
	}
	body, err := base64.RawURLEncoding.DecodeString(reqPayload.BodyB64)
	if err != nil {
		return nil, nil, 0, err
	}
	return request, body, reqPayload.RequestID, nil
}

func lookupRequestControl(reqJSON string) (*httpInFlightRequest, error) {
	var reqPayload httpRequestControl
	if err := json.Unmarshal([]byte(reqJSON), &reqPayload); err != nil {
		return nil, err
	}
	return lookupRequest(reqPayload.RequestID)
}

func lookupRequest(requestID int) (*httpInFlightRequest, error) {
	httpRequestsMu.Lock()
	request := httpRequests[requestID]
	httpRequestsMu.Unlock()
	if request == nil {
		return nil, fmt.Errorf("unknown http request id %d", requestID)
	}
	return request, nil
}

func runHTTPRequest(
	requestID int,
	client *http.Client,
	req *http.Request,
	request *httpInFlightRequest,
) {
	defer finishHTTPRequest(requestID, request)

	resp, err := client.Do(req)
	if err != nil {
		postHTTPEvent(map[string]any{
			"type":      "http_response_error",
			"requestId": requestID,
			"error":     err.Error(),
		})
		return
	}
	defer resp.Body.Close()

	postHTTPEvent(map[string]any{
		"type":            "http_response_head",
		"requestId":       requestID,
		"statusCode":      resp.StatusCode,
		"headers":         resp.Header,
		"contentLength":   normalizeContentLength(resp.ContentLength),
		"isRedirect":      resp.StatusCode >= 300 && resp.StatusCode < 400,
		"finalUrl":        resp.Request.URL.String(),
		"reasonPhrase":    responseReasonPhrase(resp),
		"connectionClose": shouldCloseConnection(resp.Header),
	})

	buffer := make([]byte, httpStreamChunkSize)
	for {
		n, readErr := resp.Body.Read(buffer)
		if n > 0 {
			chunk := append([]byte(nil), buffer[:n]...)
			postHTTPEvent(map[string]any{
				"type":      "http_response_body",
				"requestId": requestID,
				"bodyB64":   base64.RawURLEncoding.EncodeToString(chunk),
			})
		}
		if readErr == nil {
			continue
		}
		if errors.Is(readErr, io.EOF) {
			postHTTPEvent(map[string]any{
				"type":      "http_response_done",
				"requestId": requestID,
			})
			return
		}
		postHTTPEvent(map[string]any{
			"type":      "http_response_error",
			"requestId": requestID,
			"error":     readErr.Error(),
		})
		return
	}
}

func finishHTTPRequest(requestID int, request *httpInFlightRequest) {
	request.doneOnce.Do(func() {
		close(request.done)
		request.cancel()
		_ = request.requestBody.Close()
		httpRequestsMu.Lock()
		delete(httpRequests, requestID)
		httpRequestsMu.Unlock()
	})
}

func postHTTPEvent(msg map[string]any) {
	// Prevent stale or already-canceled requests from spamming the Dart side.
	requestID, _ := msg["requestId"].(int)
	if requestID > 0 {
		httpRequestsMu.Lock()
		_, active := httpRequests[requestID]
		httpRequestsMu.Unlock()
		if !active {
			return
		}
	}
	postMessage(msg)
}

func normalizeContentLength(contentLength int64) any {
	if contentLength < 0 {
		return nil
	}
	return contentLength
}

func responseReasonPhrase(resp *http.Response) string {
	if resp.Status == "" {
		return ""
	}
	if trimmed := strings.TrimSpace(resp.Status); trimmed != "" {
		parts := strings.SplitN(trimmed, " ", 2)
		if len(parts) == 2 {
			return parts[1]
		}
	}
	return ""
}

func shouldCloseConnection(headers http.Header) bool {
	for _, value := range headers.Values("Connection") {
		if strings.EqualFold(strings.TrimSpace(value), "close") {
			return true
		}
	}
	return false
}

func cancelAllHTTPRequests() {
	httpRequestsMu.Lock()
	requests := make([]*httpInFlightRequest, 0, len(httpRequests))
	for _, request := range httpRequests {
		requests = append(requests, request)
	}
	httpRequests = map[int]*httpInFlightRequest{}
	httpRequestsMu.Unlock()

	for _, request := range requests {
		request.cancel()
		_ = request.requestBody.CloseWithError(context.Canceled)
		request.doneOnce.Do(func() {
			close(request.done)
		})
	}
}
