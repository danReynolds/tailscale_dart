# Documentation map

Use the document's status before treating it as current behavior. Target-design
documents intentionally lead implementation; current-state documents describe
the checked-in code until their workstream lands.

## Start here

| Document | Status | Purpose |
| --- | --- | --- |
| [Rearchitecture plan](rearchitecture-plan.md) | Accepted target | North Star, decisions, live PR disposition, implementation order, and release gates. |
| [Runtime ownership and lifecycle ADR](adr-runtime-ownership-and-lifecycle.md) | Accepted target | `nodeRuntime`, generation gates, auth/logout semantics, publication bootstrap, and fail-safe teardown. |
| [Encrypted node state ADR](adr-encrypted-node-state.md) | Accepted target | Direct Keybay custody binding, encrypted file format, state lease, failure/reset matrix, and no-migration rollout. |
| [Current architecture and API feedback](current-architecture-and-api-feedback.md) | Current implementation | Existing Go/Dart/fd ownership and public API shape. |
| [Concurrency model](concurrency.md) | Current implementation | Existing epoch, registries, lock order, and teardown commit protocol. |
| [API status](api-status.md) | Current public surface | Namespace-by-namespace callable API and platform qualifications. |
| [API roadmap](api-roadmap.md) | Forward-looking API work | Feature priorities after the launch-critical rearchitecture. |

## Source-of-truth order

When documents disagree:

1. Checked-in source and executable tests describe current behavior.
2. `api-status.md`, `current-architecture-and-api-feedback.md`, and
   `concurrency.md` should describe that current behavior.
3. Accepted ADRs define decisions for code not yet merged.
4. `rearchitecture-plan.md` defines sequencing and acceptance gates.
5. Historical RFCs and readiness notes explain earlier decisions but do not
   override a newer accepted ADR.

## Implementation rule

Every rearchitecture PR should:

- name its R-number from the plan;
- link the relevant ADR section;
- state which current behavior it changes and which it deliberately leaves;
- include the focused acceptance tests owned by that workstream;
- update current-state docs only after the code lands;
- avoid broad support or security claims without the platform/test receipt.

## Existing RFCs and engineering notes

| Document | Scope |
| --- | --- |
| [Runtime data-plane backends RFC](rfc-runtime-data-plane-backends.md) | Platform/backend abstraction for the fd data plane. |
| [Shared fd reactor RFC](rfc-shared-fd-reactor.md) | POSIX kqueue/epoll reactor and descriptor ownership. |
| [Runtime transport journal](runtime-transport-journal.md) | Historical implementation evidence and decisions. |
| [Routing controls notes](implementation-notes-routing-controls.md) | Prefs and exit-node implementation details. |
| [Testing](testing.md) | Repository test tiers and commands. |
| [PR readiness](pr-readiness.md) | Historical fd-transport readiness record. |

## Security wording

Until the encrypted-state workstream lands, the current release stores node
StateStore data in SQLite, creates its paths with owner-only modes, and attempts
to tighten existing modes best-effort. It relies on the application sandbox,
permissions, and backup exclusion and does not yet fail closed when chmod
verification is unavailable. The accepted target replaces that database with
authenticated whole-map encryption, an externally custodied key, and
fail-closed permission verification.

Even after that work lands, documentation must not say that the entire tsnet
directory is encrypted: on non-Kubernetes paths, upstream ACME/TLS private-key
sidecars, a credential-bearing log config, and sensitive logs can bypass
StateStore. Current direct `ListenTLS`/`ListenFunnel` are unsupported on mobile;
target ServeConfig Funnel remains unqualified until real-device and sidecar
receipts pass, while `tls.bind` requires an alternate certificate path.
