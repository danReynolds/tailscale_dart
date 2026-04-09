package tailscale

import (
	"database/sql"
	"fmt"
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

	return &SQLiteStore{db: db}, nil
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
