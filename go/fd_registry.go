package tailscale

import (
	"sync"

	"tailscale.com/util/mak"
)

// fdRegistry owns one runtime-scoped family of fd-backed resources, keyed by
// caller-allocated monotonic ids. Ids come from process-global counters so a
// stale handle from an earlier generation can never name a later generation's
// resource (an fd-keyed or per-runtime counter would reintroduce that
// displacement class). The zero value is ready, and every method is nil-safe
// so lookups with no current runtime simply miss.
//
// closed is the commit barrier that replaces the old global-registry epoch
// ordering: the teardown sweep marks the registry closed under its lock, so a
// commit racing teardown is refused under the same lock — commit and sweep
// stay totally ordered, now per runtime. The nodeGate epoch check is retained
// at commit as the shared stale-work guard for callers holding old gates.
type fdRegistry[T comparable] struct {
	mu      sync.Mutex
	closed  bool
	entries map[int64]T
}

// commit installs value under id iff the gated lifecycle is still live and
// this registry has not been swept. On false nothing was installed and the
// caller owns cleanup.
func (r *fdRegistry[T]) commit(gate nodeGate, id int64, value T) bool {
	if r == nil {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || !gate.stillCurrent() {
		return false
	}
	mak.Set(&r.entries, id, value)
	return true
}

func (r *fdRegistry[T]) get(id int64) (T, bool) {
	var zero T
	if r == nil {
		return zero, false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	value, ok := r.entries[id]
	return value, ok
}

// take removes and returns the entry under id.
func (r *fdRegistry[T]) take(id int64) (T, bool) {
	var zero T
	if r == nil {
		return zero, false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	value, ok := r.entries[id]
	if ok {
		delete(r.entries, id)
	}
	return value, ok
}

// removeMatching removes id only while it still maps to value, so a
// self-healing cleanup path can never displace a successor entry.
func (r *fdRegistry[T]) removeMatching(id int64, value T) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.entries[id] == value {
		delete(r.entries, id)
	}
}

// drain marks the registry closed and returns every entry for the caller to
// close outside the lock. Later commits are refused and later lookups miss.
func (r *fdRegistry[T]) drain() []T {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closed = true
	values := make([]T, 0, len(r.entries))
	for _, value := range r.entries {
		values = append(values, value)
	}
	clear(r.entries)
	return values
}

func (r *fdRegistry[T]) size() int {
	if r == nil {
		return 0
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.entries)
}
