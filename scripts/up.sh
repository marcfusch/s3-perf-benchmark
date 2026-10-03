#!/usr/bin/env bash
# up.sh <system>: starts a fresh 3 node cluster (empty volumes), forms it and
# applies the homogeneous limits.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
sys=$1
docker network inspect bench >/dev/null 2>&1 || docker network create bench >/dev/null
docker compose -f "$BENCH_DIR/systems/$sys/compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
docker compose -f "$BENCH_DIR/systems/$sys/compose.yml" up -d
"$BENCH_DIR/systems/$sys/init.sh"
"$BENCH_DIR/scripts/limits.sh" "$sys" none 1 0
