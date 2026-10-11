#!/usr/bin/env bash
# down.sh <system>: stops the cluster and deletes its volumes, including the
# modelled hard disks attached by hdd.sh, if any.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
compose="$BENCH_DIR/systems/$1/compose.yml"
hdds=$(host_tool sh -c "ls /var/lib/docker/hdd/ 2>/dev/null" | sed -n "s/^hdd-$1-\([0-9]\)\.img$/\1/p" || true)
if [ -n "$hdds" ]; then
  docker compose -f "$compose" rm -sf >/dev/null 2>&1 || true
  for n in $hdds; do "$BENCH_DIR/scripts/hdd.sh" detach "$1" "$n"; done
fi
docker compose -f "$compose" down -v --remove-orphans
trim_disk
