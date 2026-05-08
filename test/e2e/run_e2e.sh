#!/bin/bash
#
# End-to-end test for tailscale using Headscale (self-hosted Tailscale control server).
#
# Prerequisites:
#   - Docker with compose
#   - Go 1.25+ (the build hook compiles the native library automatically)
#   - Dart SDK on PATH
#
# Usage:
#   cd packages/tailscale
#   test/e2e/run_e2e.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
export HEADSCALE_PORT="${HEADSCALE_PORT:-8080}"

echo "=== Starting Headscale ==="
docker compose -f "$COMPOSE_FILE" up -d --wait

cleanup() {
    echo "=== Tearing down Headscale ==="
    docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true
}
trap cleanup EXIT

# Wait for Headscale API to be ready
echo "=== Waiting for Headscale API ==="
for i in $(seq 1 30); do
    if curl -sf "http://localhost:$HEADSCALE_PORT/health" > /dev/null 2>&1; then
        echo "Headscale is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: Headscale failed to start within 30s"
        docker compose -f "$COMPOSE_FILE" logs
        exit 1
    fi
    sleep 1
done

# Create a user plus separate disposable and persistence auth keys.
echo "=== Creating Headscale user and auth keys ==="
docker compose -f "$COMPOSE_FILE" exec headscale \
    headscale users create dune-test 2>/dev/null || true

AUTH_KEY=$(docker compose -f "$COMPOSE_FILE" exec headscale \
    headscale preauthkeys create --user dune-test --reusable --ephemeral --expiration 10m \
    2>/dev/null | tail -1)

PERSIST_AUTH_KEY=$(docker compose -f "$COMPOSE_FILE" exec headscale \
    headscale preauthkeys create --user dune-test --reusable --expiration 10m \
    2>/dev/null | tail -1)

if [ -z "$AUTH_KEY" ]; then
    echo "ERROR: Failed to create ephemeral auth key"
    exit 1
fi
if [ -z "$PERSIST_AUTH_KEY" ]; then
    echo "ERROR: Failed to create persistence auth key"
    exit 1
fi
echo "Ephemeral auth key: ${AUTH_KEY:0:20}..."
echo "Persistence auth key: ${PERSIST_AUTH_KEY:0:20}..."

# Run the E2E Dart test
echo "=== Running E2E tests ==="
cd "$PKG_DIR"

HEADSCALE_URL="http://localhost:$HEADSCALE_PORT" \
HEADSCALE_AUTH_KEY="$AUTH_KEY" \
HEADSCALE_PERSIST_AUTH_KEY="$PERSIST_AUTH_KEY" \
    "${DART:-dart}" test test/e2e/e2e_test.dart --enable-experiment=native-assets --timeout=360s

echo "=== E2E tests passed ==="
