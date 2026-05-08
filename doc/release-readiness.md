# Release readiness

This checklist is the release gate for publishing `package:tailscale`.
It complements the test-tier details in [`test/README.md`](../test/README.md)
and the forward-looking API priorities in [`api-roadmap.md`](api-roadmap.md).

## Release contract

Before publishing a version, the repository should have:

- A `pubspec.yaml` version that matches the top `CHANGELOG.md` entry.
- README, `doc/api-status.md`, `doc/api-roadmap.md`, and the static site
  describing the same supported API surface.
- Platform metadata that only lists platforms validated for this release.
- Package contents checked with `dart pub publish --dry-run`.
- Generated API docs validated with `dart doc --output site/api --validate-links`.
  The command must exit successfully; dartdoc may still warn about package-page
  file links in the generated API index.
- CI-equivalent tests, Go tests, Headscale E2E, and local whitespace checks run.
- Release-confidence smoke validation for the platforms claimed in
  `pubspec.yaml`.

## Required commands

Run Dart/native-asset commands serially. Multiple `dart test` or `dart doc`
invocations can race the native-assets build output on macOS.

```bash
dart pub get
dart analyze lib/ test/ hook/
dart test
(cd go && go test -count=1 ./...)
test/e2e/run_e2e.sh
git diff --check
dart doc --output site/api --validate-links
dart pub publish --dry-run
```

For a broader local sweep:

```bash
tool/test_local_full.sh
tool/smoke/run_matrix.sh --targets macos,ios,android --strict
```

Run live hosted-control-plane suites when the release changes TLS, Serve,
Funnel, exit-node behavior, prefs, auth, or control-plane assumptions:

```bash
TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... \
  dart test test/live_tailscale/live_routing_controls_test.dart
TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... \
  dart test test/live_tailscale/live_tls_listener_test.dart
TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... \
  dart test test/live_tailscale/live_serve_forward_test.dart
TAILSCALE_API_KEY=... TAILSCALE_TAILNET_ID=... \
  dart test test/live_tailscale/live_funnel_forward_test.dart
```

## Package contents

`dart pub publish --dry-run` should report zero warnings. The package should
include the public library, build hook, Go source needed by the native build,
examples, tests, README, changelog, license, and user-facing docs.

The package should not include generated docs or repo-only operations material:

- `doc/api/`
- `site/`
- `benchmark/`
- `packages/`
- `tool/`
- `.github/`
- architecture RFCs and PR-only readiness notes

## Platform evidence

Claim only these platforms for the current release:

| Platform | Release evidence |
| --- | --- |
| macOS | Local native-asset build, kqueue fd backend, root tests, Flutter smoke/demo validation. |
| iOS | Flutter smoke/demo validation on a real device or release-target equivalent. |
| Android | Flutter smoke/demo validation on a real device or release-target equivalent. |
| Linux | Linux CI, epoll fd backend, Go tests, root Dart tests, and Headscale E2E. |

Do not add Windows to `pubspec.yaml` until a Windows-specific data-plane design
is implemented and validated.

## Known non-blockers

These are allowed in a pre-1.0 release when documented clearly:

- Taildrop and profiles are exported as planned/stub namespaces.
- Tailscale Services stays unsupported until the `tailscale.com` pin includes
  the upstream `ListenService` surface this package wants to wrap.
- Advanced Serve/Funnel config remains demand-driven beyond
  `forward` / `clear`.
- The package is POSIX-first; Windows remains a separate backend decision.

## Cut procedure

1. Start from a clean branch based on `origin/main`.
2. Confirm version, changelog, README status copy, API status, and site copy.
3. Run the required commands above and record any intentional skipped live
   suites in the release PR.
4. Inspect `dart pub publish --dry-run` package contents for generated files,
   secrets, local-only artifacts, and stale docs.
5. Merge the release PR after CI is green.
6. Tag the released commit and run `dart pub publish` from that exact commit.
