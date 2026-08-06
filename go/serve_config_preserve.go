package tailscale

import (
	"log"
	"sync/atomic"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
)

// serveResetConsumed records whether tsnet's one-shot serve-config reset has
// already fired in this process, so the snapshot/restore below runs at most
// once instead of on every Funnel or TLS bind.
//
// It mirrors tsnet.Server.resetServeStateOnce rather than observing it: that
// sync.Once is unexported, and there is no upstream hook to opt out of the
// reset. Conservative in the only direction that matters — a false negative
// costs one extra GetServeConfig, while missing the reset costs the user their
// Serve mounts.
var serveResetConsumed atomic.Bool

// serveConfigIsEmpty reports whether sc holds no publication of any kind.
//
// Deliberately not a nil check: tsnet's reset writes a non-nil but entirely
// empty *ipn.ServeConfig, so that is exactly the state we must recognise.
// ETag is ignored — it is transport metadata, not content.
func serveConfigIsEmpty(sc *ipn.ServeConfig) bool {
	return sc == nil ||
		(len(sc.TCP) == 0 &&
			len(sc.Web) == 0 &&
			len(sc.Services) == 0 &&
			len(sc.AllowFunnel) == 0 &&
			len(sc.Foreground) == 0)
}

// preserveServeConfigAcrossUp runs fn — a call that reaches tsnet.Server.Up,
// directly or via ListenFunnel/ListenTLS — and puts back any persisted
// ServeConfig that Up destroyed on its way through.
//
// The first time Up observes ipn.Running it runs resetServeStateOnce, which
// issues SetServeConfig(new(ipn.ServeConfig)) with an EMPTY If-Match: an
// unconditional, CAS-exempt wipe of the whole persisted serve config
// (tsnet.go:569 @ v1.100.0, "to prevent messy interactions with stale
// config"). Upstream is entitled to that assumption — a fresh tsnet.Server
// owns its serve state. It does not hold for us: funnel.forward and tls.bind
// reach Up, serve.forward does not, so a user who published with
// serve.forward and then called either of the others silently lost the Serve
// mount. Reachable from a single process, and demonstrated against a live
// tailnet in test/live_tailscale/live_funnel_serve_swap_test.dart, where
// in-tailnet access went 200 -> EOF -> connection refused across the swap.
//
// Reordering our own Up cannot fix this: ListenFunnel (tsnet.go:1500) and
// ListenTLS (tsnet.go:1365) call Up internally, so the reset fires on any
// successful path whether or not we call Up ourselves.
//
// Callers must hold NEITHER funnelMu NOR serveConfigMu. fn blocks on the IPN
// bus, and the restore below takes serveConfigMu; holding either across fn
// would wedge every FFI entry point behind a stalled login (the hazard
// documented at funnel_forward.go:121-126).
func preserveServeConfigAcrossUp(lc *local.Client, fn func() error) error {
	// Only the first Up per process can trigger the reset; after that this is
	// pure overhead on every Funnel/TLS bind.
	if serveResetConsumed.Load() {
		return fn()
	}

	var before *ipn.ServeConfig
	ctx, cancel := boundedCallCtx(0)
	sc, err := lc.GetServeConfig(ctx)
	cancel()
	if err != nil {
		// A failed snapshot must not fail the caller's actual operation: at
		// worst we are back to the pre-fix behavior. Log it, because it means
		// the safety net is off for this call.
		log.Printf("TSNET: could not snapshot serve config before tsnet.Up; "+
			"existing Serve mounts are unprotected for this call: %v", err)
	} else if !serveConfigIsEmpty(sc) {
		before = sc
	}

	if err := fn(); err != nil {
		return err
	}
	serveResetConsumed.Store(true)

	if before == nil {
		// Nothing was published, so the reset had nothing to destroy — which
		// is the case upstream designed it for.
		return nil
	}
	restoreServeConfig(lc, before)
	return nil
}

// restoreServeConfig puts `before` back if the serve config is now empty.
//
// Never fails the caller. By the time this runs the Funnel listener or TLS
// bind has already succeeded, and tearing that down because a restore round
// trip failed would trade one silent loss for a louder one. A failure is
// logged loudly instead, because it means Serve mounts really are gone.
func restoreServeConfig(lc *local.Client, before *ipn.ServeConfig) {
	// Serialize against the Serve path's own get-modify-set. Taken only for
	// the restore, never across fn.
	serveConfigMu.Lock()
	defer serveConfigMu.Unlock()

	ctx, cancel := boundedCallCtx(0)
	defer cancel()

	after, err := lc.GetServeConfig(ctx)
	if err != nil {
		log.Printf("TSNET: serve config restore: read-back failed, "+
			"Serve mounts created before this call may be gone: %v", err)
		return
	}
	if !serveConfigIsEmpty(after) {
		// Either the reset never fired, or a concurrent ServeForward already
		// repopulated the config. Restoring our snapshot over the top would
		// clobber that write — a lost update of exactly the kind serveConfigMu
		// exists to prevent.
		return
	}

	// The snapshot's ETag is stale by definition: the wipe changed it, and
	// SetServeConfig sends ETag as If-Match, so reusing it would 412. CAS
	// against the post-reset state we just read instead.
	restored := *before
	restored.ETag = ""
	if after != nil {
		restored.ETag = after.ETag
	}

	if err := lc.SetServeConfig(ctx, &restored); err != nil {
		log.Printf("TSNET: serve config restore failed; Serve mounts created "+
			"before this call are gone: %v", err)
		return
	}
	log.Printf("TSNET: restored the serve config that tsnet's one-shot reset cleared")
}
