#!/usr/bin/env bash
# Waits for a raft leader among the masters and for the three S3 gateways,
# 3 checks in a row, since a node may still restart once (see compose.yml).
set -euo pipefail
stable=0
for i in $(seq 1 90); do
  leader=$(docker exec seaweedfs-node1 wget -qO- http://localhost:9333/cluster/status 2>/dev/null | sed -n 's/.*"Leader":"\([^"]*\)".*/\1/p' || true)
  ok=0
  for n in 1 2 3; do
    docker exec seaweedfs-node$n wget -qO /dev/null http://localhost:8333/healthz 2>/dev/null && ok=$((ok+1))
  done
  if [ -n "$leader" ] && [ "$ok" = 3 ]; then stable=$((stable+1)); else stable=0; fi
  if [ "$stable" = 3 ]; then echo "seaweedfs ready, master leader: $leader"; exit 0; fi
  sleep 1
done
echo "seaweedfs not ready after 90 s" >&2; exit 1
