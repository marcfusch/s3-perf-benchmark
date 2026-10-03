#!/usr/bin/env bash
# down.sh <system>: stops the cluster and deletes its volumes.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
docker compose -f "$BENCH_DIR/systems/$1/compose.yml" down -v --remove-orphans
trim_disk
