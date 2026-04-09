package tailscale

import (
	"os"
	"path/filepath"
	"sync"
	"testing"

	"tailscale.com/ipn"
)

func tempDBPath(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	return filepath.Join(dir, "state.db")
}

func TestNewSQLiteStore(t *testing.T) {
	path := tempDBPath(t)
	store, err := NewSQLiteStore(path)
	if err != nil {
		t.Fatalf("NewSQLiteStore(%q) failed: %v", path, err)
	}
	defer store.Close()

	// File should exist
	if _, err := os.Stat(path); err != nil {
		t.Errorf("database file not created: %v", err)
	}
}

func TestNewSQLiteStore_InvalidPath(t *testing.T) {
	_, err := NewSQLiteStore("/nonexistent/dir/state.db")
	if err == nil {
		t.Error("expected error for invalid path, got nil")
	}
}

func TestSQLiteStore_WriteAndRead(t *testing.T) {
	store, err := NewSQLiteStore(tempDBPath(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	key := ipn.StateKey("test-key")
	value := []byte("test-value-data")

	if err := store.WriteState(key, value); err != nil {
		t.Fatalf("WriteState failed: %v", err)
	}

	got, err := store.ReadState(key)
	if err != nil {
		t.Fatalf("ReadState failed: %v", err)
	}

	if string(got) != string(value) {
		t.Errorf("ReadState = %q, want %q", got, value)
	}
}

func TestSQLiteStore_ReadNotExist(t *testing.T) {
	store, err := NewSQLiteStore(tempDBPath(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	_, err = store.ReadState("no-such-key")
	if err != ipn.ErrStateNotExist {
		t.Errorf("ReadState for missing key: got %v, want ErrStateNotExist", err)
	}
}

func TestSQLiteStore_Overwrite(t *testing.T) {
	store, err := NewSQLiteStore(tempDBPath(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	key := ipn.StateKey("overwrite-key")

	if err := store.WriteState(key, []byte("v1")); err != nil {
		t.Fatal(err)
	}
	if err := store.WriteState(key, []byte("v2")); err != nil {
		t.Fatal(err)
	}

	got, err := store.ReadState(key)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "v2" {
		t.Errorf("after overwrite: got %q, want %q", got, "v2")
	}
}

func TestSQLiteStore_BinaryData(t *testing.T) {
	store, err := NewSQLiteStore(tempDBPath(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	key := ipn.StateKey("binary-key")
	value := []byte{0x00, 0x01, 0xFF, 0xFE, 0x80}

	if err := store.WriteState(key, value); err != nil {
		t.Fatal(err)
	}

	got, err := store.ReadState(key)
	if err != nil {
		t.Fatal(err)
	}

	if len(got) != len(value) {
		t.Fatalf("binary data length: got %d, want %d", len(got), len(value))
	}
	for i := range value {
		if got[i] != value[i] {
			t.Errorf("byte %d: got 0x%02X, want 0x%02X", i, got[i], value[i])
		}
	}
}

func TestSQLiteStore_MultipleKeys(t *testing.T) {
	store, err := NewSQLiteStore(tempDBPath(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	keys := map[ipn.StateKey][]byte{
		"key-a": []byte("value-a"),
		"key-b": []byte("value-b"),
		"key-c": []byte("value-c"),
	}

	for k, v := range keys {
		if err := store.WriteState(k, v); err != nil {
			t.Fatalf("WriteState(%q) failed: %v", k, err)
		}
	}

	for k, want := range keys {
		got, err := store.ReadState(k)
		if err != nil {
			t.Fatalf("ReadState(%q) failed: %v", k, err)
		}
		if string(got) != string(want) {
			t.Errorf("ReadState(%q) = %q, want %q", k, got, want)
		}
	}
}

func TestSQLiteStore_ConcurrentReadWrite(t *testing.T) {
	store, err := NewSQLiteStore(tempDBPath(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	key := ipn.StateKey("concurrent-key")
	if err := store.WriteState(key, []byte("initial")); err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	errs := make(chan error, 20)

	// 10 concurrent writers
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			val := []byte(string(rune('a' + i)))
			if err := store.WriteState(key, val); err != nil {
				errs <- err
			}
		}(i)
	}

	// 10 concurrent readers
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := store.ReadState(key)
			if err != nil {
				errs <- err
			}
		}()
	}

	wg.Wait()
	close(errs)

	for err := range errs {
		t.Errorf("concurrent operation failed: %v", err)
	}
}

func TestSQLiteStore_Persistence(t *testing.T) {
	path := tempDBPath(t)
	key := ipn.StateKey("persist-key")
	value := []byte("persist-value")

	// Write and close
	store1, err := NewSQLiteStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := store1.WriteState(key, value); err != nil {
		t.Fatal(err)
	}
	store1.Close()

	// Reopen and read
	store2, err := NewSQLiteStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store2.Close()

	got, err := store2.ReadState(key)
	if err != nil {
		t.Fatalf("ReadState after reopen: %v", err)
	}
	if string(got) != string(value) {
		t.Errorf("after reopen: got %q, want %q", got, value)
	}
}
