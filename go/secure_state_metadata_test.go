package tailscale

import (
	"bytes"
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"tailscale.com/ipn"
)

type runtimeMetadataTestStore struct {
	state map[ipn.StateKey][]byte
}

func (s *runtimeMetadataTestStore) ReadState(key ipn.StateKey) ([]byte, error) {
	value, ok := s.state[key]
	if !ok {
		return nil, ipn.ErrStateNotExist
	}
	// Deliberately return the store-owned slice to prove loadRuntimeConfig
	// does not wipe or otherwise mutate it.
	return value, nil
}

func (s *runtimeMetadataTestStore) WriteState(key ipn.StateKey, value []byte) error {
	if s.state == nil {
		s.state = make(map[ipn.StateKey][]byte)
	}
	if value == nil {
		delete(s.state, key)
		return nil
	}
	s.state[key] = bytes.Clone(value)
	return nil
}

func TestRuntimeConfigMetadataRoundTrip(t *testing.T) {
	store := new(runtimeMetadataTestStore)
	want := runtimeConfig{
		hostname:   "node-a",
		controlURL: "https://control.example/",
	}
	if err := saveRuntimeConfig(store, want); err != nil {
		t.Fatalf("saveRuntimeConfig: %v", err)
	}

	const canonical = `{"version":1,"hostname":"node-a","controlURL":"https://control.example/","ephemeral":false}`
	stored := store.state[persistentRuntimeConfigStateKey]
	if string(stored) != canonical {
		t.Fatalf("stored metadata = %q, want %q", stored, canonical)
	}
	beforeLoad := bytes.Clone(stored)

	got, err := loadRuntimeConfig(store)
	if err != nil {
		t.Fatalf("loadRuntimeConfig: %v", err)
	}
	if got != want {
		t.Fatalf("loadRuntimeConfig = %+v, want %+v", got, want)
	}
	if !bytes.Equal(store.state[persistentRuntimeConfigStateKey], beforeLoad) {
		t.Fatal("loadRuntimeConfig mutated store-owned memory")
	}

	emptyWant := runtimeConfig{}
	if err := saveRuntimeConfig(store, emptyWant); err != nil {
		t.Fatalf("save empty runtime config: %v", err)
	}
	if got, err := loadRuntimeConfig(store); err != nil || got != emptyWant {
		t.Fatalf("empty runtime config round trip = (%+v, %v), want (%+v, nil)", got, err, emptyWant)
	}
}

func TestRuntimeConfigMetadataAbsenceAndEphemeralRejection(t *testing.T) {
	store := new(runtimeMetadataTestStore)
	if _, err := loadRuntimeConfig(store); !errors.Is(err, ipn.ErrStateNotExist) {
		t.Fatalf("load absent metadata error = %v, want ipn.ErrStateNotExist", err)
	}
	if err := saveRuntimeConfig(store, runtimeConfig{ephemeral: true}); !errors.Is(err, errRuntimeConfigMetadataInvalid) {
		t.Fatalf("save ephemeral metadata error = %v, want invalid metadata", err)
	}
	if _, ok := store.state[persistentRuntimeConfigStateKey]; ok {
		t.Fatal("ephemeral runtime wrote persistent metadata")
	}
}

func TestClearRuntimeConfigDeletesEvenAnEmptyStoredValue(t *testing.T) {
	store := &runtimeMetadataTestStore{state: map[ipn.StateKey][]byte{
		persistentRuntimeConfigStateKey: {},
	}}
	if err := clearRuntimeConfig(store); err != nil {
		t.Fatalf("clearRuntimeConfig: %v", err)
	}
	if _, ok := store.state[persistentRuntimeConfigStateKey]; ok {
		t.Fatal("clearRuntimeConfig retained an empty metadata value")
	}
	if err := clearRuntimeConfig(nil); !errors.Is(err, errRuntimeConfigMetadataInvalid) {
		t.Fatalf("clearRuntimeConfig(nil) = %v, want invalid metadata", err)
	}
}

func TestRuntimeConfigMetadataStrictRejection(t *testing.T) {
	valid := `{"version":1,"hostname":"node","controlURL":"https://control.example/","ephemeral":false}`
	tests := []struct {
		name    string
		payload []byte
		wantErr error
	}{
		{"empty", nil, errRuntimeConfigMetadataInvalid},
		{"not object", []byte(`[]`), errRuntimeConfigMetadataInvalid},
		{"malformed", []byte(`{"version":`), errRuntimeConfigMetadataInvalid},
		{"trailing value", []byte(valid + ` {}`), errRuntimeConfigMetadataInvalid},
		{"unknown field", []byte(`{"version":1,"hostname":"node","controlURL":"https://control.example/","ephemeral":false,"future":0}`), errRuntimeConfigMetadataInvalid},
		{"duplicate field", []byte(`{"version":1,"version":1,"hostname":"node","controlURL":"https://control.example/","ephemeral":false}`), errRuntimeConfigMetadataInvalid},
		{"missing field", []byte(`{"version":1,"hostname":"node","controlURL":"https://control.example/"}`), errRuntimeConfigMetadataInvalid},
		{"future version", []byte(`{"version":2,"hostname":"node","controlURL":"https://control.example/","ephemeral":false}`), errRuntimeConfigMetadataVersion},
		{"fractional version", []byte(`{"version":1.0,"hostname":"node","controlURL":"https://control.example/","ephemeral":false}`), errRuntimeConfigMetadataInvalid},
		{"hostname type", []byte(`{"version":1,"hostname":false,"controlURL":"https://control.example/","ephemeral":false}`), errRuntimeConfigMetadataInvalid},
		{"control URL null", []byte(`{"version":1,"hostname":"node","controlURL":null,"ephemeral":false}`), errRuntimeConfigMetadataInvalid},
		{"ephemeral type", []byte(`{"version":1,"hostname":"node","controlURL":"https://control.example/","ephemeral":"false"}`), errRuntimeConfigMetadataInvalid},
		{"ephemeral true", []byte(`{"version":1,"hostname":"node","controlURL":"https://control.example/","ephemeral":true}`), errRuntimeConfigMetadataInvalid},
		{"invalid UTF-8", append([]byte(valid), 0xff), errRuntimeConfigMetadataInvalid},
		{"oversized", bytes.Repeat([]byte("x"), maxRuntimeConfigMetadataBytes+1), errRuntimeConfigMetadataInvalid},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			store := &runtimeMetadataTestStore{state: map[ipn.StateKey][]byte{
				persistentRuntimeConfigStateKey: bytes.Clone(test.payload),
			}}
			if _, err := loadRuntimeConfig(store); !errors.Is(err, test.wantErr) {
				t.Fatalf("loadRuntimeConfig error = %v, want %v", err, test.wantErr)
			}
		})
	}
}

func TestRuntimeConfigMetadataErrorsDoNotExposeContent(t *testing.T) {
	const marker = "/private/identity/secret-marker"
	store := &runtimeMetadataTestStore{state: map[ipn.StateKey][]byte{
		persistentRuntimeConfigStateKey: []byte(`{"version":2,"hostname":"` + marker + `","controlURL":"https://control.example/","ephemeral":false}`),
	}}
	_, err := loadRuntimeConfig(store)
	if !errors.Is(err, errRuntimeConfigMetadataVersion) {
		t.Fatalf("loadRuntimeConfig error = %v, want unsupported version", err)
	}
	if strings.Contains(err.Error(), marker) {
		t.Fatalf("metadata error exposed persisted content: %v", err)
	}
}

func TestEncryptedStateStoreLogicalEmptyIgnoresOnlyRuntimeMetadata(t *testing.T) {
	var key [encryptedStateKeySize]byte
	for i := range key {
		key[i] = byte(i + 1)
	}
	path := filepath.Join(t.TempDir(), "tailscale", encryptedStateFileName)
	store, err := createEncryptedStateStore(path, key)
	if err != nil {
		t.Fatalf("createEncryptedStateStore: %v", err)
	}
	t.Cleanup(func() {
		if err := store.Close(); err != nil {
			t.Errorf("close encrypted StateStore: %v", err)
		}
	})

	if empty, err := store.logicalEmpty(); err != nil || !empty {
		t.Fatalf("fresh logicalEmpty = (%v, %v), want (true, nil)", empty, err)
	}
	if err := saveRuntimeConfig(store, runtimeConfig{hostname: "node"}); err != nil {
		t.Fatalf("saveRuntimeConfig: %v", err)
	}
	if empty, err := store.logicalEmpty(); err != nil || !empty {
		t.Fatalf("metadata-only logicalEmpty = (%v, %v), want (true, nil)", empty, err)
	}

	if err := store.WriteState(ipn.MachineKeyStateKey, []byte("upstream-state")); err != nil {
		t.Fatalf("write upstream state: %v", err)
	}
	if empty, err := store.logicalEmpty(); err != nil || empty {
		t.Fatalf("upstream-state logicalEmpty = (%v, %v), want (false, nil)", empty, err)
	}
	if err := store.WriteState(ipn.MachineKeyStateKey, nil); err != nil {
		t.Fatalf("delete upstream state: %v", err)
	}
	if empty, err := store.logicalEmpty(); err != nil || !empty {
		t.Fatalf("metadata after delete logicalEmpty = (%v, %v), want (true, nil)", empty, err)
	}

	nearbyKey := ipn.StateKey(string(persistentRuntimeConfigStateKey) + "-future")
	if err := store.WriteState(nearbyKey, []byte{}); err != nil {
		t.Fatalf("write nearby key: %v", err)
	}
	if empty, err := store.logicalEmpty(); err != nil || empty {
		t.Fatalf("nearby-key logicalEmpty = (%v, %v), want (false, nil)", empty, err)
	}

	if err := store.Close(); err != nil {
		t.Fatalf("close encrypted StateStore: %v", err)
	}
	if _, err := store.logicalEmpty(); !errors.Is(err, errEncryptedStateClosed) {
		t.Fatalf("closed logicalEmpty error = %v, want closed", err)
	}
}

func TestRuntimeConfigMetadataSaveSizeAndEncoding(t *testing.T) {
	tests := []runtimeConfig{
		{hostname: string([]byte{0xff})},
		{controlURL: string([]byte{0xff})},
		{hostname: strings.Repeat("h", maxRuntimeConfigMetadataBytes)},
		{controlURL: strings.Repeat("u", maxRuntimeConfigMetadataBytes)},
	}
	for i, config := range tests {
		store := new(runtimeMetadataTestStore)
		if err := saveRuntimeConfig(store, config); !errors.Is(err, errRuntimeConfigMetadataInvalid) {
			t.Errorf("case %d save error = %v, want invalid metadata", i, err)
		}
	}
}
