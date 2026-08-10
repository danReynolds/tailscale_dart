package tailscale

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strconv"
	"sync"
	"testing"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
)

type memoryPublicationClient struct {
	mu sync.Mutex

	status *ipnstate.Status
	config *ipn.ServeConfig

	getCalls int
	setCalls int
	sets     []*ipn.ServeConfig
	aliasGet bool
	setHook  func(call int, candidate *ipn.ServeConfig) (next *ipn.ServeConfig, err error)
}

// serialReceiptPublicationClient treats Get..Set as one logical mutation and
// records if another Get enters before the prior Set completes. The inner
// client remains independently race-safe, so this specifically tests the
// manager's transaction serialization rather than relying on a data race.
type serialReceiptPublicationClient struct {
	inner *memoryPublicationClient

	mu              sync.Mutex
	transactionOpen bool
	overlapped      bool
}

func (c *serialReceiptPublicationClient) StatusWithoutPeers(ctx context.Context) (*ipnstate.Status, error) {
	return c.inner.StatusWithoutPeers(ctx)
}

func (c *serialReceiptPublicationClient) GetServeConfig(ctx context.Context) (*ipn.ServeConfig, error) {
	c.mu.Lock()
	if c.transactionOpen {
		c.overlapped = true
	}
	c.transactionOpen = true
	c.mu.Unlock()

	config, err := c.inner.GetServeConfig(ctx)
	// Widen the interleaving window. With no manager-level transaction lock,
	// the simultaneous forwards below reliably overlap and lose updates.
	time.Sleep(250 * time.Microsecond)
	return config, err
}

func (c *serialReceiptPublicationClient) SetServeConfig(ctx context.Context, config *ipn.ServeConfig) error {
	err := c.inner.SetServeConfig(ctx, config)
	c.mu.Lock()
	c.transactionOpen = false
	c.mu.Unlock()
	return err
}

func (c *serialReceiptPublicationClient) sawOverlap() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.overlapped
}

func (c *memoryPublicationClient) StatusWithoutPeers(context.Context) (*ipnstate.Status, error) {
	return c.status, nil
}

func (c *memoryPublicationClient) GetServeConfig(context.Context) (*ipn.ServeConfig, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.getCalls++
	if c.config == nil {
		return nil, nil
	}
	if c.aliasGet {
		return c.config, nil
	}
	return c.config.Clone(), nil
}

func (c *memoryPublicationClient) SetServeConfig(_ context.Context, candidate *ipn.ServeConfig) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.setCalls++
	call := c.setCalls
	c.sets = append(c.sets, candidate.Clone())

	var (
		next *ipn.ServeConfig
		err  error
	)
	if c.setHook != nil {
		next, err = c.setHook(call, candidate.Clone())
	} else {
		next = candidate.Clone()
	}
	if next != nil {
		next = next.Clone()
		next.ETag = fmt.Sprintf("etag-%d", call)
		c.config = next
	}
	return err
}

func (c *memoryPublicationClient) snapshot() (*ipn.ServeConfig, int, int, []*ipn.ServeConfig) {
	c.mu.Lock()
	defer c.mu.Unlock()
	var config *ipn.ServeConfig
	if c.config != nil {
		config = c.config.Clone()
	}
	sets := make([]*ipn.ServeConfig, len(c.sets))
	for i, set := range c.sets {
		sets[i] = set.Clone()
	}
	return config, c.getCalls, c.setCalls, sets
}

func newPublicationManagerForTest(t *testing.T, client publicationLocalClient) (*nodeRuntime, *publicationManager) {
	t.Helper()
	runtime := newNodeRuntime(nodeEpoch.Load(), nextDirectRuntimeToken(), runtimeConfig{})
	manager := newPublicationManagerWithClient(runtime, client)
	runtime.publication = manager
	// Generic manager tests exercise mapping semantics without publishing a
	// process-global runtime. Neutralize delivery-loss quarantine and always
	// stop pending timers so successful forwards cannot fire after test return.
	manager.onDeliveryLoss = func(*nodeRuntime, error) {}
	t.Cleanup(func() {
		manager.mu.Lock()
		manager.cancelAllPendingDeliveriesLocked()
		manager.mu.Unlock()
		runtime.cancel()
	})
	return runtime, manager
}

func publicationTestStatus() *ipnstate.Status {
	const funnelPorts tailcfg.NodeCapability = "https://tailscale.com/cap/funnel-ports?ports=443,8443,10000,"
	return &ipnstate.Status{
		Self: &ipnstate.PeerStatus{
			DNSName: "demo.tailnet.ts.net.",
			CapMap: tailcfg.NodeCapMap{
				tailcfg.CapabilityHTTPS: nil,
				tailcfg.NodeAttrFunnel:  nil,
				funnelPorts:             nil,
			},
		},
		CurrentTailnet: &ipnstate.TailnetStatus{MagicDNSSuffix: "tailnet.ts.net"},
	}
}

func publicationForward(path string, localPort int, funnel bool) serveForwardPayload {
	return serveForwardPayload{
		TailnetPort:  443,
		LocalAddress: "127.0.0.1",
		LocalPort:    localPort,
		Path:         path,
		HTTPS:        true,
		Funnel:       funnel,
	}
}

func uint64Pointer(v uint64) *uint64 { return &v }

func exactClear(publication servePublication) serveClearPayload {
	return serveClearPayload{
		TailnetPort:  publication.Port,
		Path:         publication.Path,
		Funnel:       publication.Funnel,
		Generation:   uint64Pointer(publication.Generation),
		MappingToken: uint64Pointer(publication.MappingToken),
	}
}

func publicationHandler(sc *ipn.ServeConfig, path string) *ipn.HTTPHandler {
	if sc == nil {
		return nil
	}
	hp := ipn.HostPort(net.JoinHostPort("demo.tailnet.ts.net", strconv.Itoa(443)))
	if sc.Web[hp] == nil {
		return nil
	}
	return sc.Web[hp].Handlers[path]
}

func publicationFunnelEnabled(sc *ipn.ServeConfig) bool {
	if sc == nil {
		return false
	}
	hp := ipn.HostPort(net.JoinHostPort("demo.tailnet.ts.net", strconv.Itoa(443)))
	return sc.AllowFunnel[hp]
}

func TestPublicationDeliveryAcknowledgementOwnsExactMapping(t *testing.T) {
	client := &memoryPublicationClient{
		status: publicationTestStatus(),
		config: new(ipn.ServeConfig),
	}
	_, manager := newPublicationManagerForTest(t, client)
	losses := 0
	manager.onDeliveryLoss = func(*nodeRuntime, error) { losses++ }

	publication, err := manager.forward(context.Background(), publicationForward("/ack", 3000, false))
	if err != nil {
		t.Fatalf("forward: %v", err)
	}
	manager.mu.Lock()
	pending := manager.pendingDelivery[publication.MappingToken]
	manager.mu.Unlock()
	if pending == nil {
		t.Fatal("successful forward did not retain pending delivery ownership")
	}
	if err := manager.acknowledgePublication(publication.Generation, publication.MappingToken); err != nil {
		t.Fatalf("acknowledge: %v", err)
	}
	manager.expirePendingDelivery(pending)
	if losses != 0 {
		t.Fatalf("acknowledged publication fired %d delivery-loss callbacks", losses)
	}
	if manager.count() != 1 {
		t.Fatalf("acknowledgement retired live mapping; count = %d, want 1", manager.count())
	}
}

func TestPublicationDeliveryExpiryRetainsExactNativeOwnership(t *testing.T) {
	client := &memoryPublicationClient{
		status: publicationTestStatus(),
		config: new(ipn.ServeConfig),
	}
	runtime, manager := newPublicationManagerForTest(t, client)
	type loss struct {
		runtime *nodeRuntime
		err     error
	}
	lost := make(chan loss, 1)
	manager.onDeliveryLoss = func(runtime *nodeRuntime, err error) {
		lost <- loss{runtime: runtime, err: err}
	}

	publication, err := manager.forward(context.Background(), publicationForward("/lost", 3000, false))
	if err != nil {
		t.Fatalf("forward: %v", err)
	}
	manager.mu.Lock()
	pending := manager.pendingDelivery[publication.MappingToken]
	manager.mu.Unlock()
	manager.expirePendingDelivery(pending)

	got := <-lost
	if got.runtime != runtime || !errors.Is(got.err, ErrPublicationCommitIndeterminate) {
		t.Fatalf("delivery loss = (%p, %v), want exact runtime %p and commit-indeterminate", got.runtime, got.err, runtime)
	}
	if manager.count() != 1 {
		t.Fatalf("expiry discarded native mapping ownership; count = %d, want 1", manager.count())
	}
}

func TestPublicationReplacementCancelsObsoleteDeliveryTimer(t *testing.T) {
	client := &memoryPublicationClient{
		status: publicationTestStatus(),
		config: new(ipn.ServeConfig),
	}
	_, manager := newPublicationManagerForTest(t, client)
	losses := 0
	manager.onDeliveryLoss = func(*nodeRuntime, error) { losses++ }

	prior, err := manager.forward(context.Background(), publicationForward("/replace", 3000, false))
	if err != nil {
		t.Fatal(err)
	}
	manager.mu.Lock()
	priorPending := manager.pendingDelivery[prior.MappingToken]
	manager.mu.Unlock()
	replacement, err := manager.forward(context.Background(), publicationForward("/replace", 3001, false))
	if err != nil {
		t.Fatal(err)
	}
	manager.expirePendingDelivery(priorPending)
	if losses != 0 {
		t.Fatalf("replaced mapping fired %d delivery-loss callbacks", losses)
	}
	if err := manager.acknowledgePublication(prior.Generation, prior.MappingToken); err != nil {
		t.Fatalf("obsolete acknowledgement must be an idempotent success: %v", err)
	}
	if err := manager.acknowledgePublication(replacement.Generation, replacement.MappingToken); err != nil {
		t.Fatalf("replacement acknowledgement: %v", err)
	}
}

func TestPublicationClearCancelsPendingDeliveryTimer(t *testing.T) {
	client := &memoryPublicationClient{
		status: publicationTestStatus(),
		config: new(ipn.ServeConfig),
	}
	_, manager := newPublicationManagerForTest(t, client)
	losses := 0
	manager.onDeliveryLoss = func(*nodeRuntime, error) { losses++ }

	publication, err := manager.forward(context.Background(), publicationForward("/clear-pending", 3000, false))
	if err != nil {
		t.Fatal(err)
	}
	manager.mu.Lock()
	pending := manager.pendingDelivery[publication.MappingToken]
	manager.mu.Unlock()
	if err := manager.clear(context.Background(), exactClear(publication)); err != nil {
		t.Fatalf("clear: %v", err)
	}
	manager.expirePendingDelivery(pending)
	if losses != 0 {
		t.Fatalf("cleared mapping fired %d delivery-loss callbacks", losses)
	}
}

func TestServeForwardCapturedRuntimeCannotPublishIntoReplacement(t *testing.T) {
	client := &memoryPublicationClient{
		status: publicationTestStatus(),
		config: new(ipn.ServeConfig),
	}
	staleToken := nextDirectRuntimeToken()
	runtime, manager := newPublicationManagerForTest(t, client)
	manager.bootstrap.mu.Lock()
	manager.bootstrap.phase = publicationBootstrapReady
	manager.bootstrap.mu.Unlock()

	runtimes.mu.Lock()
	if runtimes.current != nil || runtimes.candidate != nil || runtimes.draining != nil {
		runtimes.mu.Unlock()
		t.Fatal("test requires an idle runtime controller")
	}
	runtimes.current = runtime
	runtimes.mu.Unlock()
	t.Cleanup(func() {
		runtimes.mu.Lock()
		if runtimes.current == runtime {
			runtimes.current = nil
		}
		runtimes.mu.Unlock()
	})

	payload, err := json.Marshal(publicationForward("/queued-a", 3000, false))
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal([]byte(ServeForward(staleToken, string(payload))), &result); err != nil {
		t.Fatal(err)
	}
	if result["code"] != "staleRuntime" {
		t.Fatalf("stale queued forward result = %+v, want staleRuntime", result)
	}
	config, gets, sets, _ := client.snapshot()
	if gets != 0 || sets != 0 || manager.count() != 0 || publicationHandler(config, "/queued-a") != nil {
		t.Fatalf("stale runtime A touched B: gets=%d sets=%d count=%d config=%+v", gets, sets, manager.count(), config)
	}
}

func TestPublicationManagerForwardDeepCopiesAndReturnsOwnership(t *testing.T) {
	base := &ipn.ServeConfig{ETag: "base-etag"}
	client := &memoryPublicationClient{
		status:   publicationTestStatus(),
		config:   base,
		aliasGet: true,
	}
	runtime, manager := newPublicationManagerForTest(t, client)

	publication, err := manager.forward(context.Background(), publicationForward("/api", 3000, false))
	if err != nil {
		t.Fatalf("forward: %v", err)
	}
	if publication.Generation != runtime.generation || publication.Generation == 0 {
		t.Fatalf("generation = %d, runtime = %d; want equal and non-zero", publication.Generation, runtime.generation)
	}
	if publication.MappingToken == 0 {
		t.Fatal("mapping token must be non-zero")
	}
	if manager.count() != 1 {
		t.Fatalf("manager count = %d, want 1", manager.count())
	}
	if base.Web != nil || base.TCP != nil || base.AllowFunnel != nil {
		t.Fatalf("GetServeConfig result was mutated in place: %+v", base)
	}
	config, gets, sets, submitted := client.snapshot()
	if gets != 1 || sets != 1 || len(submitted) != 1 {
		t.Fatalf("calls = get %d set %d submitted %d, want 1/1/1", gets, sets, len(submitted))
	}
	if submitted[0].ETag != "base-etag" {
		t.Fatalf("submitted ETag = %q, want base-etag", submitted[0].ETag)
	}
	if handler := publicationHandler(config, "/api"); handler == nil || handler.Proxy != "http://127.0.0.1:3000" {
		t.Fatalf("committed handler = %+v", handler)
	}
}

func TestPublicationManagerRetriesOneTypedConflictAndPreservesExternalMount(t *testing.T) {
	conflict := errors.New("typed precondition conflict")
	external := new(ipn.ServeConfig)
	if _, err := applyServeForward(external, publicationTestStatus(), publicationForward("/external", 4100, false)); err != nil {
		t.Fatal(err)
	}
	external.ETag = "external-etag"
	client := &memoryPublicationClient{
		status: publicationTestStatus(),
		config: &ipn.ServeConfig{ETag: "initial-etag"},
		setHook: func(call int, candidate *ipn.ServeConfig) (*ipn.ServeConfig, error) {
			if call == 1 {
				return external, conflict
			}
			return candidate, nil
		},
	}
	_, manager := newPublicationManagerForTest(t, client)
	manager.isPreconditionsFailed = func(err error) bool { return errors.Is(err, conflict) }

	if _, err := manager.forward(context.Background(), publicationForward("/owned", 3000, false)); err != nil {
		t.Fatalf("forward: %v", err)
	}
	config, gets, sets, _ := client.snapshot()
	if gets != 2 || sets != 2 {
		t.Fatalf("calls = get %d set %d, want 2/2", gets, sets)
	}
	if publicationHandler(config, "/external") == nil || publicationHandler(config, "/owned") == nil {
		t.Fatalf("retry clobbered external or owned mount: %+v", config)
	}
}

func TestPublicationManagerSerializesConcurrentDistinctPathForwards(t *testing.T) {
	const operations = 64
	inner := &memoryPublicationClient{
		status: publicationTestStatus(),
		config: &ipn.ServeConfig{ETag: "initial"},
	}
	client := &serialReceiptPublicationClient{inner: inner}
	_, manager := newPublicationManagerForTest(t, client)

	start := make(chan struct{})
	errs := make(chan error, operations)
	tokens := make(chan uint64, operations)
	var wait sync.WaitGroup
	for i := 0; i < operations; i++ {
		i := i
		wait.Add(1)
		go func() {
			defer wait.Done()
			<-start
			publication, err := manager.forward(
				context.Background(),
				publicationForward(fmt.Sprintf("/concurrent-%d", i), 3000+i, false),
			)
			if err != nil {
				errs <- err
				return
			}
			tokens <- publication.MappingToken
		}()
	}
	close(start)
	wait.Wait()
	close(errs)
	close(tokens)
	for err := range errs {
		t.Errorf("concurrent forward: %v", err)
	}
	if t.Failed() {
		return
	}

	seenTokens := make(map[uint64]struct{}, operations)
	for token := range tokens {
		if token == 0 {
			t.Fatal("concurrent forward returned zero mapping token")
		}
		if _, duplicate := seenTokens[token]; duplicate {
			t.Fatalf("concurrent forwards reused mapping token %d", token)
		}
		seenTokens[token] = struct{}{}
	}
	if len(seenTokens) != operations {
		t.Fatalf("successful publications = %d, want %d", len(seenTokens), operations)
	}
	if client.sawOverlap() {
		t.Fatal("ServeConfig Get..Set transactions overlapped")
	}

	config, gets, sets, _ := inner.snapshot()
	if gets != operations || sets != operations {
		t.Fatalf("LocalAPI calls = get %d set %d, want %d/%d", gets, sets, operations, operations)
	}
	if manager.count() != operations {
		t.Fatalf("manager mappings = %d, want %d", manager.count(), operations)
	}
	for i := 0; i < operations; i++ {
		path := fmt.Sprintf("/concurrent-%d", i)
		handler := publicationHandler(config, path)
		wantProxy := fmt.Sprintf("http://127.0.0.1:%d", 3000+i)
		if handler == nil || handler.Proxy != wantProxy {
			t.Errorf("handler %s = %+v, want proxy %s", path, handler, wantProxy)
		}
	}
}

func TestPublicationManagerStopsAfterThreeTypedConflicts(t *testing.T) {
	conflict := errors.New("typed precondition conflict")
	client := &memoryPublicationClient{
		status: publicationTestStatus(),
		config: &ipn.ServeConfig{ETag: "initial"},
		setHook: func(call int, _ *ipn.ServeConfig) (*ipn.ServeConfig, error) {
			return &ipn.ServeConfig{ETag: fmt.Sprintf("external-%d", call)}, conflict
		},
	}
	_, manager := newPublicationManagerForTest(t, client)
	manager.isPreconditionsFailed = func(err error) bool { return errors.Is(err, conflict) }

	_, err := manager.forward(context.Background(), publicationForward("/owned", 3000, false))
	if !errors.Is(err, ErrServeConfigConflict) {
		t.Fatalf("error = %v, want ErrServeConfigConflict", err)
	}
	_, gets, sets, _ := client.snapshot()
	if gets != maxServeConfigMutationAttempts || sets != maxServeConfigMutationAttempts {
		t.Fatalf("calls = get %d set %d, want exactly %d/%d", gets, sets, maxServeConfigMutationAttempts, maxServeConfigMutationAttempts)
	}
	if manager.count() != 0 {
		t.Fatalf("conflicted forward retained %d mappings", manager.count())
	}
}

func TestPublicationManagerDoesNotRetryKnownNotAppliedSet(t *testing.T) {
	denied := errors.New("typed access denied")
	client := &memoryPublicationClient{
		status: publicationTestStatus(),
		config: &ipn.ServeConfig{ETag: "initial"},
		setHook: func(_ int, _ *ipn.ServeConfig) (*ipn.ServeConfig, error) {
			return &ipn.ServeConfig{ETag: "unchanged"}, denied
		},
	}
	_, manager := newPublicationManagerForTest(t, client)
	manager.isKnownNotApplied = func(err error) bool { return errors.Is(err, denied) }

	_, err := manager.forward(context.Background(), publicationForward("/owned", 3000, false))
	if !errors.Is(err, ErrPublicationNotApplied) || errors.Is(err, ErrPublicationCommitIndeterminate) {
		t.Fatalf("error = %v, want conclusively not applied", err)
	}
	_, gets, sets, _ := client.snapshot()
	if gets != 1 || sets != 1 {
		t.Fatalf("calls = get %d set %d, want 1/1", gets, sets)
	}
	if manager.count() != 0 {
		t.Fatalf("known-not-applied forward retained %d mappings", manager.count())
	}
}

func TestPublicationManagerIndeterminateForwardIsTeardownOwned(t *testing.T) {
	responseLost := errors.New("response lost after apply")
	client := &memoryPublicationClient{
		status: publicationTestStatus(),
		config: &ipn.ServeConfig{ETag: "initial"},
		setHook: func(call int, candidate *ipn.ServeConfig) (*ipn.ServeConfig, error) {
			if call == 1 {
				return candidate, responseLost // backend applied; response did not arrive
			}
			return candidate, nil
		},
	}
	_, manager := newPublicationManagerForTest(t, client)

	_, err := manager.forward(context.Background(), publicationForward("/uncertain", 3000, true))
	if !errors.Is(err, ErrPublicationCommitIndeterminate) {
		t.Fatalf("error = %v, want ErrPublicationCommitIndeterminate", err)
	}
	if manager.count() != 1 {
		t.Fatalf("indeterminate mapping count = %d, want 1 for teardown", manager.count())
	}
	if closeErr := manager.close(); closeErr != nil {
		t.Fatalf("manager close: %v", closeErr)
	}
	config, _, sets, _ := client.snapshot()
	if sets != 2 {
		t.Fatalf("SetServeConfig calls = %d, want uncertain apply + teardown", sets)
	}
	if publicationHandler(config, "/uncertain") != nil || publicationFunnelEnabled(config) {
		t.Fatalf("teardown left uncertain publication active: %+v", config)
	}
}

func TestPublicationManagerIndeterminateClearRetainsOwnershipForTeardown(t *testing.T) {
	for _, applied := range []bool{true, false} {
		name := "backend applied clear"
		if !applied {
			name = "backend did not apply clear"
		}
		t.Run(name, func(t *testing.T) {
			responseLost := errors.New("clear response lost")
			var beforeClear *ipn.ServeConfig
			client := &memoryPublicationClient{
				status: publicationTestStatus(),
				config: &ipn.ServeConfig{ETag: "initial"},
				setHook: func(call int, candidate *ipn.ServeConfig) (*ipn.ServeConfig, error) {
					switch call {
					case 1:
						beforeClear = candidate.Clone()
						return candidate, nil
					case 2:
						if applied {
							return candidate, responseLost
						}
						return beforeClear, responseLost
					default:
						return candidate, nil
					}
				},
			}
			_, manager := newPublicationManagerForTest(t, client)
			publication, err := manager.forward(context.Background(), publicationForward("/uncertain-clear", 3000, true))
			if err != nil {
				t.Fatalf("forward: %v", err)
			}

			err = manager.clear(context.Background(), exactClear(publication))
			if !errors.Is(err, ErrPublicationCommitIndeterminate) {
				t.Fatalf("clear error = %v, want ErrPublicationCommitIndeterminate", err)
			}
			if manager.count() != 1 {
				t.Fatalf("indeterminate clear retained %d mappings, want 1", manager.count())
			}
			config, _, setsBeforeClose, _ := client.snapshot()
			if applied {
				if publicationHandler(config, "/uncertain-clear") != nil || publicationFunnelEnabled(config) {
					t.Fatalf("backend-applied clear did not reach config: %+v", config)
				}
			} else if publicationHandler(config, "/uncertain-clear") == nil || !publicationFunnelEnabled(config) {
				t.Fatalf("not-applied clear lost the owned config before teardown: %+v", config)
			}

			if closeErr := manager.close(); closeErr != nil {
				t.Fatalf("manager close: %v", closeErr)
			}
			config, _, setsAfterClose, _ := client.snapshot()
			if publicationHandler(config, "/uncertain-clear") != nil || publicationFunnelEnabled(config) {
				t.Fatalf("teardown left an indeterminate clear variant active: %+v", config)
			}
			if manager.count() != 0 {
				t.Fatalf("teardown retained %d mappings", manager.count())
			}
			if applied && setsAfterClose != setsBeforeClose {
				t.Fatalf("already-applied clear caused an unnecessary teardown Set: %d -> %d", setsBeforeClose, setsAfterClose)
			}
			if !applied && setsAfterClose != setsBeforeClose+1 {
				t.Fatalf("not-applied clear teardown Set calls = %d -> %d, want one cleanup", setsBeforeClose, setsAfterClose)
			}
		})
	}
}

func TestPublicationManagerExactCloseIsTokenAndGenerationSafe(t *testing.T) {
	client := &memoryPublicationClient{status: publicationTestStatus(), config: &ipn.ServeConfig{ETag: "initial"}}
	runtime, manager := newPublicationManagerForTest(t, client)

	oldPublication, err := manager.forward(context.Background(), publicationForward("/same", 3000, false))
	if err != nil {
		t.Fatal(err)
	}
	currentPublication, err := manager.forward(context.Background(), publicationForward("/same", 4000, false))
	if err != nil {
		t.Fatal(err)
	}
	if oldPublication.MappingToken == currentPublication.MappingToken {
		t.Fatal("replacement reused its mapping token")
	}
	_, getsBefore, setsBefore, _ := client.snapshot()
	if err := manager.clear(context.Background(), exactClear(oldPublication)); err != nil {
		t.Fatalf("stale token close: %v", err)
	}
	_, getsAfter, setsAfter, _ := client.snapshot()
	if getsAfter != getsBefore || setsAfter != setsBefore {
		t.Fatalf("stale token touched LocalAPI: get %d->%d set %d->%d", getsBefore, getsAfter, setsBefore, setsAfter)
	}

	wrongGeneration := exactClear(currentPublication)
	*wrongGeneration.Generation = runtime.generation + 1
	if err := manager.clear(context.Background(), wrongGeneration); err != nil {
		t.Fatalf("old-generation close: %v", err)
	}
	_, getsAfterGeneration, setsAfterGeneration, _ := client.snapshot()
	if getsAfterGeneration != getsAfter || setsAfterGeneration != setsAfter {
		t.Fatal("wrong-generation close touched LocalAPI")
	}

	config, _, _, _ := client.snapshot()
	if handler := publicationHandler(config, "/same"); handler == nil || handler.Proxy != "http://127.0.0.1:4000" {
		t.Fatalf("stale close removed successor: %+v", handler)
	}
	if err := manager.clear(context.Background(), exactClear(currentPublication)); err != nil {
		t.Fatalf("current exact close: %v", err)
	}
	config, _, _, _ = client.snapshot()
	if publicationHandler(config, "/same") != nil || manager.count() != 0 {
		t.Fatalf("current exact close did not remove mapping: %+v count=%d", config, manager.count())
	}
}

func TestPublicationManagerExplicitClearInvalidatesCurrentToken(t *testing.T) {
	client := &memoryPublicationClient{status: publicationTestStatus(), config: &ipn.ServeConfig{ETag: "initial"}}
	_, manager := newPublicationManagerForTest(t, client)
	publication, err := manager.forward(context.Background(), publicationForward("/clear", 3000, true))
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.clear(context.Background(), serveClearPayload{
		TailnetPort: publication.Port,
		Path:        publication.Path,
		Funnel:      true,
	}); err != nil {
		t.Fatalf("explicit clear: %v", err)
	}
	if manager.count() != 0 {
		t.Fatalf("explicit clear retained %d mappings", manager.count())
	}
	_, gets, sets, _ := client.snapshot()
	if err := manager.clear(context.Background(), exactClear(publication)); err != nil {
		t.Fatalf("old handle after explicit clear: %v", err)
	}
	_, getsAfter, setsAfter, _ := client.snapshot()
	if getsAfter != gets || setsAfter != sets {
		t.Fatal("invalidated handle touched LocalAPI")
	}
}

func TestPublicationCoordinateClearTransfersVisibilityToSurvivingMapping(t *testing.T) {
	client := &memoryPublicationClient{status: publicationTestStatus(), config: &ipn.ServeConfig{ETag: "initial"}}
	_, manager := newPublicationManagerForTest(t, client)
	survivor, err := manager.forward(context.Background(), publicationForward("/survivor", 3000, false))
	if err != nil {
		t.Fatal(err)
	}
	cleared, err := manager.forward(context.Background(), publicationForward("/cleared", 4000, true))
	if err != nil {
		t.Fatal(err)
	}

	// This is intentionally a coordinate Serve clear, not the Funnel handle's
	// exact close. It removes /cleared while leaving the port's Funnel bit and
	// /survivor handler in place.
	if err := manager.clear(context.Background(), serveClearPayload{
		TailnetPort: cleared.Port,
		Path:        cleared.Path,
		Funnel:      false,
	}); err != nil {
		t.Fatalf("coordinate clear: %v", err)
	}
	config, _, _, _ := client.snapshot()
	if publicationHandler(config, "/cleared") != nil || publicationHandler(config, "/survivor") == nil || !publicationFunnelEnabled(config) {
		t.Fatalf("coordinate clear changed the wrong port state: %+v", config)
	}
	portKey := publicationPortKey{host: "demo.tailnet.ts.net", port: 443}
	visibility := manager.visibility[portKey]
	if visibility.token != survivor.MappingToken || len(visibility.evidence) == 0 || visibility.evidence[0].key.path != "/survivor" {
		t.Fatalf("visibility owner after coordinate clear = %+v, want surviving token %d", visibility, survivor.MappingToken)
	}

	if err := manager.close(); err != nil {
		t.Fatalf("manager close: %v", err)
	}
	config, _, _, _ = client.snapshot()
	if publicationHandler(config, "/survivor") != nil || publicationFunnelEnabled(config) {
		t.Fatalf("teardown leaked transferred Funnel visibility: %+v", config)
	}
}

func TestPublicationVisibilityOwnershipIsPortScoped(t *testing.T) {
	t.Run("closing Serve A preserves later Funnel B", func(t *testing.T) {
		client := &memoryPublicationClient{status: publicationTestStatus(), config: &ipn.ServeConfig{ETag: "initial"}}
		_, manager := newPublicationManagerForTest(t, client)
		serveA, err := manager.forward(context.Background(), publicationForward("/a", 3000, false))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := manager.forward(context.Background(), publicationForward("/b", 4000, true)); err != nil {
			t.Fatal(err)
		}
		if err := manager.clear(context.Background(), exactClear(serveA)); err != nil {
			t.Fatal(err)
		}
		config, _, _, _ := client.snapshot()
		if publicationHandler(config, "/a") != nil || publicationHandler(config, "/b") == nil || !publicationFunnelEnabled(config) {
			t.Fatalf("closing Serve A disturbed later Funnel B: %+v", config)
		}
	})

	t.Run("closing old Funnel A preserves later private Serve B", func(t *testing.T) {
		client := &memoryPublicationClient{status: publicationTestStatus(), config: &ipn.ServeConfig{ETag: "initial"}}
		_, manager := newPublicationManagerForTest(t, client)
		funnelA, err := manager.forward(context.Background(), publicationForward("/a", 3000, true))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := manager.forward(context.Background(), publicationForward("/b", 4000, false)); err != nil {
			t.Fatal(err)
		}
		if err := manager.clear(context.Background(), exactClear(funnelA)); err != nil {
			t.Fatal(err)
		}
		config, _, _, _ := client.snapshot()
		if publicationHandler(config, "/a") != nil || publicationHandler(config, "/b") == nil || publicationFunnelEnabled(config) {
			t.Fatalf("closing old Funnel A disturbed later Serve B: %+v", config)
		}
	})
}

func TestPublicationExactClosePreservesUnattributedExternalChanges(t *testing.T) {
	t.Run("external visibility flip", func(t *testing.T) {
		client := &memoryPublicationClient{status: publicationTestStatus(), config: &ipn.ServeConfig{ETag: "initial"}}
		_, manager := newPublicationManagerForTest(t, client)
		publication, err := manager.forward(context.Background(), publicationForward("/owned", 3000, false))
		if err != nil {
			t.Fatal(err)
		}
		client.mu.Lock()
		client.config.SetFunnel("demo.tailnet.ts.net", 443, true)
		client.config.ETag = "external-visibility"
		client.mu.Unlock()

		if err := manager.clear(context.Background(), exactClear(publication)); err != nil {
			t.Fatal(err)
		}
		config, _, _, _ := client.snapshot()
		if publicationHandler(config, "/owned") != nil || !publicationFunnelEnabled(config) {
			t.Fatalf("exact close overwrote external visibility: %+v", config)
		}
	})

	t.Run("external handler replacement", func(t *testing.T) {
		client := &memoryPublicationClient{status: publicationTestStatus(), config: &ipn.ServeConfig{ETag: "initial"}}
		_, manager := newPublicationManagerForTest(t, client)
		publication, err := manager.forward(context.Background(), publicationForward("/owned", 3000, true))
		if err != nil {
			t.Fatal(err)
		}
		client.mu.Lock()
		hp := ipn.HostPort(net.JoinHostPort("demo.tailnet.ts.net", "443"))
		client.config.Web[hp].Handlers["/owned"] = &ipn.HTTPHandler{Proxy: "http://127.0.0.1:9999"}
		client.config.ETag = "external-handler"
		client.mu.Unlock()

		if err := manager.clear(context.Background(), exactClear(publication)); err != nil {
			t.Fatal(err)
		}
		config, _, _, _ := client.snapshot()
		if handler := publicationHandler(config, "/owned"); handler == nil || handler.Proxy != "http://127.0.0.1:9999" {
			t.Fatalf("exact close deleted external handler: %+v", handler)
		}
		if !publicationFunnelEnabled(config) {
			t.Fatal("exact close changed visibility owned by the external replacement")
		}
	})
}

func TestPublicationTeardownPreservesUnattributedExternalReplacements(t *testing.T) {
	t.Run("handler and visibility replacement", func(t *testing.T) {
		client := &memoryPublicationClient{status: publicationTestStatus(), config: &ipn.ServeConfig{ETag: "initial"}}
		_, manager := newPublicationManagerForTest(t, client)
		if _, err := manager.forward(context.Background(), publicationForward("/owned", 3000, true)); err != nil {
			t.Fatal(err)
		}
		client.mu.Lock()
		hp := ipn.HostPort(net.JoinHostPort("demo.tailnet.ts.net", "443"))
		client.config.Web[hp].Handlers["/owned"] = &ipn.HTTPHandler{Proxy: "http://127.0.0.1:9999"}
		client.config.SetFunnel("demo.tailnet.ts.net", 443, true)
		client.config.ETag = "external-handler-and-visibility"
		client.mu.Unlock()
		_, _, setsBefore, _ := client.snapshot()

		if err := manager.close(); err != nil {
			t.Fatalf("manager close: %v", err)
		}
		config, _, setsAfter, _ := client.snapshot()
		if handler := publicationHandler(config, "/owned"); handler == nil || handler.Proxy != "http://127.0.0.1:9999" {
			t.Fatalf("teardown deleted external handler replacement: %+v", handler)
		}
		if !publicationFunnelEnabled(config) {
			t.Fatal("teardown disabled visibility belonging to external handler replacement")
		}
		if setsAfter != setsBefore {
			t.Fatalf("teardown submitted an unrelated replacement: set %d -> %d", setsBefore, setsAfter)
		}
	})

	t.Run("visibility-only replacement", func(t *testing.T) {
		client := &memoryPublicationClient{status: publicationTestStatus(), config: &ipn.ServeConfig{ETag: "initial"}}
		_, manager := newPublicationManagerForTest(t, client)
		if _, err := manager.forward(context.Background(), publicationForward("/owned", 3000, false)); err != nil {
			t.Fatal(err)
		}
		client.mu.Lock()
		client.config.SetFunnel("demo.tailnet.ts.net", 443, true)
		client.config.ETag = "external-visibility"
		client.mu.Unlock()

		if err := manager.close(); err != nil {
			t.Fatalf("manager close: %v", err)
		}
		config, _, _, _ := client.snapshot()
		if publicationHandler(config, "/owned") != nil {
			t.Fatalf("teardown retained package-owned handler: %+v", config)
		}
		if !publicationFunnelEnabled(config) {
			t.Fatal("teardown clobbered an external visibility-only replacement")
		}
	})
}
