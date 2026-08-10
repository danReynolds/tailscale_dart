package main

import (
	"encoding/json"
	"errors"
	"testing"

	tailscale "github.com/dan/tailscale"
)

func TestLifecycleErrorJSONPreservesLogoutDisposition(t *testing.T) {
	payload := decodeLifecycleErrorForTest(t, lifecycleErrorJSON(
		errors.Join(tailscale.ErrLogoutIndeterminate, errors.New("remote timeout")),
		logoutDisposition(tailscale.LogoutResult{
			Token:       81001,
			Started:     true,
			EmitStopped: true,
			NoState:     false,
		}),
	))

	assertLifecycleFieldForTest(t, payload, "code", "logoutIndeterminate")
	assertLifecycleFieldForTest(t, payload, "token", float64(81001))
	assertLifecycleFieldForTest(t, payload, "started", true)
	assertLifecycleFieldForTest(t, payload, "emitStopped", true)
	assertLifecycleFieldForTest(t, payload, "noState", false)
}

func TestLifecycleErrorJSONPreservesCloseDisposition(t *testing.T) {
	payload := decodeLifecycleErrorForTest(t, lifecycleErrorJSON(
		errors.Join(tailscale.ErrLifecycleBusy, errors.New("cleanup failed")),
		runtimeCloseDisposition(tailscale.RuntimeCloseResult{
			Token:              81002,
			Matched:            true,
			Started:            true,
			EmitStopped:        true,
			Pending:            false,
			CustodyHeld:        true,
			CustodyDisposition: tailscale.CustodyDispositionPreserveCoherentPair,
		}),
	))

	assertLifecycleFieldForTest(t, payload, "code", "lifecycleBusy")
	assertLifecycleFieldForTest(t, payload, "token", float64(81002))
	assertLifecycleFieldForTest(t, payload, "matched", true)
	assertLifecycleFieldForTest(t, payload, "started", true)
	assertLifecycleFieldForTest(t, payload, "emitStopped", true)
	assertLifecycleFieldForTest(t, payload, "pending", false)
	assertLifecycleFieldForTest(t, payload, "custodyHeld", true)
	assertLifecycleFieldForTest(t, payload, "custodyDisposition", "preserveCoherentPair")
}

func TestLifecycleErrorJSONClassifiesCleanupFailure(t *testing.T) {
	payload := decodeLifecycleErrorForTest(t, lifecycleErrorJSON(
		errors.Join(tailscale.ErrRuntimeCleanupFailed, errors.New("store close failed")),
		nil,
	))

	assertLifecycleFieldForTest(t, payload, "code", "runtimeCleanupFailed")
}

func TestLifecycleErrorJSONKeepsIndeterminateLogoutPrecedence(t *testing.T) {
	payload := decodeLifecycleErrorForTest(t, lifecycleErrorJSON(
		errors.Join(
			tailscale.ErrLogoutIndeterminate,
			tailscale.ErrRuntimeCleanupFailed,
		),
		nil,
	))

	assertLifecycleFieldForTest(t, payload, "code", "logoutIndeterminate")
}

func decodeLifecycleErrorForTest(t *testing.T, encoded string) map[string]any {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal([]byte(encoded), &payload); err != nil {
		t.Fatalf("decode lifecycle error %q: %v", encoded, err)
	}
	if _, ok := payload["error"].(string); !ok {
		t.Fatalf("lifecycle error payload = %#v, want string error", payload)
	}
	return payload
}

func assertLifecycleFieldForTest(t *testing.T, payload map[string]any, key string, want any) {
	t.Helper()
	if got := payload[key]; got != want {
		t.Fatalf("lifecycle field %q = %#v, want %#v (payload=%#v)", key, got, want, payload)
	}
}
