package tailscale

import (
	"database/sql"
	"fmt"
	"os"
	"sync"

	_ "modernc.org/sqlite"
	"tailscale.com/ipn"
)

// SQLiteStore is an ipn.StateStore that persists state to a SQLite database.
type SQLiteStore struct {
	db *sql.DB
	mu sync.RWMutex
}

// NewSQLiteStore creates a new SQLiteStore backed by the given database file.
func NewSQLiteStore(path string) (*SQLiteStore, error) {
	// Pre-create the database file with owner-only permissions. This file holds
	// the ipn state map — the WireGuard node private key and machine key.
	// SQLite's default file mode is 0644 (world-readable) and it preserves the
	// permissions of an existing file, so creating it 0600 up front (and
	// chmod-ing below to cover a pre-existing 0644 file) keeps the secret
	// material owner-only rather than relying solely on the 0700 parent dir.
	if f, err := os.OpenFile(path, os.O_CREATE, 0o600); err != nil {
		return nil, fmt.Errorf("failed to pre-create state db: %w", err)
	} else {
		f.Close()
	}

	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("failed to open sqlite database: %w", err)
	}

	// Enable WAL mode for better concurrent read/write performance.
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, fmt.Errorf("failed to enable WAL mode: %w", err)
	}

	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS tailscale_state (
		key TEXT PRIMARY KEY,
		value BLOB
	)`); err != nil {
		db.Close()
		return nil, fmt.Errorf("failed to create state table: %w", err)
	}

	// Tighten the main file (covers a pre-existing 0644 db) and the WAL-mode
	// sidecars, which also hold recently-written state pages. Best-effort: the
	// sidecars are created lazily so they may not exist yet, and some platforms
	// don't support chmod; the 0700 state directory remains the primary guard.
	restrictFilePerms(path)
	restrictFilePerms(path + "-wal")
	restrictFilePerms(path + "-shm")

	return &SQLiteStore{db: db}, nil
}

// restrictFilePerms best-effort restricts path to owner-only (0600), ignoring
// errors for files that don't exist yet or platforms without chmod support.
func restrictFilePerms(path string) {
	_ = os.Chmod(path, 0o600)
}

// ReadState implements ipn.StateStore.
func (s *SQLiteStore) ReadState(id ipn.StateKey) ([]byte, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var value []byte
	err := s.db.QueryRow("SELECT value FROM tailscale_state WHERE key = ?", string(id)).Scan(&value)
	if err == sql.ErrNoRows {
		return nil, ipn.ErrStateNotExist
	}
	if err != nil {
		return nil, fmt.Errorf("failed to read state for key %q: %w", id, err)
	}
	return value, nil
}

// WriteState implements ipn.StateStore.
func (s *SQLiteStore) WriteState(id ipn.StateKey, bs []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	_, err := s.db.Exec("INSERT OR REPLACE INTO tailscale_state (key, value) VALUES (?, ?)", string(id), bs)
	if err != nil {
		return fmt.Errorf("failed to write state for key %q: %w", id, err)
	}
	return nil
}

// Close closes the database connection.
func (s *SQLiteStore) Close() error {
	return s.db.Close()
}
