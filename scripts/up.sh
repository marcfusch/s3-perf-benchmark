#!/usr/bin/env bash
# up.sh <system>: starts a fresh 3 node cluster (empty volumes), forms it and
# applies the homogeneous limits. With HDD_NODES="1" (for example), those
# nodes get a modelled hard disk (scripts/hdd.sh) instead of the shared SSD.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
sys=$1
compose="$BENCH_DIR/systems/$sys/compose.yml"
docker network inspect bench >/dev/null 2>&1 || docker network create bench >/dev/null
"$BENCH_DIR/scripts/down.sh" "$sys" >/dev/null 2>&1 || true
if [ -n "${HDD_NODES:-}" ]; then
  docker compose -f "$compose" up --no-start
  for n in $HDD_NODES; do "$BENCH_DIR/scripts/hdd.sh" attach "$sys" "$n"; done
fi
docker compose -f "$compose" up -d
"$BENCH_DIR/systems/$sys/init.sh"
"$BENCH_DIR/scripts/limits.sh" "$sys" none 1 0
for n in ${HDD_NODES:-}; do "$BENCH_DIR/scripts/hdd.sh" limit "$sys" "$n"; done
