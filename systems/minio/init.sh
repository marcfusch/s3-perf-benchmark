#!/usr/bin/env bash
# MinIO forms its erasure set on its own, we only wait until the cluster
# reports itself healthy (all three drives online).
set -euo pipefail
for i in $(seq 1 60); do
  if docker exec minio-node1 curl -sf http://localhost:9000/minio/health/cluster >/dev/null 2>&1; then
    echo "minio cluster healthy"; exit 0
  fi
  sleep 1
done
echo "minio cluster not healthy after 60 s" >&2; exit 1
