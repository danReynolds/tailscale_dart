# Documentation map

Use the document's status before treating it as current behavior. Target-design
documents intentionally lead implementation; current-state documents describe
the checked-in code until their workstream lands.

## Start here

| Document | Status | Purpose |
| --- | --- | --- |
| [Rearchitecture plan](rearchitecture-plan.md) | In progress; R2-R5 and R7 code present, R6/R8/R10 evidence remains | North Star, decisions, live PR disposition, implementation order, and release gates. |
| [Runtime ownership and lifecycle ADR](adr-runtime-ownership-and-lifecycle.md) | R2-R5 and R7 code present; macOS crash receipt passed; remaining R6/R8/R10 work pending | `nodeRuntime`, generation gates, auth/logout semantics, publication bootstrap, and fail-safe teardown. |
| [Encrypted node state ADR](adr-encrypted-node-state.md) | Implemented through R4d; macOS production-Keybay receipt passed; remaining R6 evidence pending | Direct Keybay custody binding, encrypted file format, state lease, failure/reset matrix, and no-migration rollout. |
| [Current architecture and API feedback](current-architecture-and-api-feedback.md) | Current implementation | Existing Go/Dart/fd ownership and public API shape. |
| [Concurrency model](concurrency.md) | Current implementation | Existing epoch, registries, lock order, and teardown commit protocol. |
| [API status](api-status.md) | Current public surface | Namespace-by-namespace callable API and platform qualifications. |
| [API roadmap](api-roadmap.md) | Forward-looking API work | Feature priorities after the launch-critical rearchitecture. |

## Source-of-truth order

When documents disagree:

1. Checked-in source and executable tests describe current behavior.
2. `api-status.md`, `current-architecture-and-api-feedback.md`, and
   `concurrency.md` should describe that current behavior.
3. Accepted ADRs define both implemented invariants and decisions for later
   work; use each ADR's status section to distinguish them.
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

Persistent nodes now store the complete logical StateStore map in one
authenticated encrypted Go envelope. One random 32-byte DEK is held by Keybay,
and storage/custody inconsistencies fail closed. Pre-launch SQLite and plaintext
FileStore layouts are recognized but not migrated; callers must explicitly run
`forgetLocalIdentity()` to discard them. Ephemeral nodes use an in-memory
StateStore and temporary scratch directory and never access Keybay.

Documentation must not say that the entire package or tsnet subtree is
encrypted: on non-Kubernetes paths, upstream ACME/TLS private-key sidecars, a
credential-bearing log config, and sensitive logs can bypass StateStore. The
whole state root still needs owner-only permissions and backup exclusion.
`tls.bind` still depends on a mobile-disabled certificate endpoint and requires
an alternate path before mobile qualification. R5 has removed the direct
`ListenFunnel` implementation in favor of shared ServeConfig/`AllowFunnel`, but
HTTPS Serve and Funnel remain unqualified on mobile until real-device and
sidecar receipts pass.
