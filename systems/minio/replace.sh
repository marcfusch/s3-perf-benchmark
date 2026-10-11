#!/usr/bin/env bash
# replace.sh <n>: node n came back with an empty drive. MinIO formats it and
# heals it on its own, nothing to do but wait until the node answers.
set -euo pipefail
n=$1
for i in $(seq 1 120); do
  docker exec minio-node$n curl -sf http://localhost:9000/minio/health/live >/dev/null 2>&1 && break
  sleep 1
done
echo "minio: node $n back, healing is automatic"
