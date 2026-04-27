#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DART="${DART:-dart}"
GO="${GO:-go}"
HEADSCALE_PORT="${HEADSCALE_PORT:-18080}"

cd "$ROOT"

echo "== Dart dependencies =="
"$DART" pub get

echo "== Dart analyze =="
"$DART" analyze lib/ test/ hook/

echo "== Dart tests =="
"$DART" test

echo "== Go tests =="
(cd go && "$GO" test -count=1 ./...)

echo "== Headscale E2E =="
HEADSCALE_PORT="$HEADSCALE_PORT" DART="$DART" test/e2e/run_e2e.sh

echo "== PR gate passed =="
