#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DART="${DART:-dart}"
FLUTTER="${FLUTTER:-flutter}"

cd "$ROOT"

tool/test_pr_gate.sh

echo "== demo_core tests =="
(cd packages/demo_core && "$DART" test)

echo "== demo_flutter tests =="
(cd packages/demo_flutter && "$FLUTTER" test)

echo "== demo_smoke_flutter tests =="
(cd packages/demo_smoke_flutter && "$FLUTTER" test)

echo "== whitespace check =="
git diff --check

echo "== Local full suite passed =="
