#!/bin/bash
# Runs the head-of-line-blocking demo (benchmark/audit/http_client_reuse.dart)
# against a throwaway local Headscale, mirroring test/e2e/run_e2e.sh.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE_FILE="$PKG_DIR/test/e2e/docker-compose.yml"
export HEADSCALE_PORT="${HEADSCALE_PORT:-8080}"

echo "=== Starting Headscale ==="
docker compose -f "$COMPOSE_FILE" up -d --wait

cleanup() {
  echo "=== Tearing down Headscale ==="
  docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Waiting for Headscale API ==="
for i in $(seq 1 30); do
  if curl -sf "http://localhost:$HEADSCALE_PORT/health" >/dev/null 2>&1; then break; fi
  [ "$i" -eq 30 ] && { echo "Headscale failed to start"; exit 1; }
  sleep 1
done

docker compose -f "$COMPOSE_FILE" exec headscale \
  headscale users create dune-httpreuse 2>/dev/null || true
AUTH_KEY=$(docker compose -f "$COMPOSE_FILE" exec headscale \
  headscale preauthkeys create --user dune-httpreuse --reusable --ephemeral --expiration 10m 2>/dev/null | tail -1)
[ -z "$AUTH_KEY" ] && { echo "failed to create auth key"; exit 1; }

echo "=== Running head-of-line demo ==="
cd "$PKG_DIR"
HEADSCALE_URL="http://localhost:$HEADSCALE_PORT" \
HEADSCALE_AUTH_KEY="$AUTH_KEY" \
  "${DART:-dart}" run --enable-experiment=native-assets benchmark/audit/http_client_reuse.dart
