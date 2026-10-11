#!/usr/bin/env bash
# Connects the three Garage nodes, applies a layout with one zone per node
# and imports the shared benchmark key.
set -euo pipefail
source "$(dirname "$0")/../../env/creds.env"
g() { docker exec -e RUST_LOG=warn garage-node1 /garage "$@" 2>/dev/null; }

for i in $(seq 1 30); do g status >/dev/null 2>&1 && break; sleep 1; done
for n in 2 3; do
  id=$(docker exec garage-node$n /garage node id -q 2>/dev/null | cut -d@ -f1)
  g node connect "${id}@garage-node$n:3901" >/dev/null
done
sleep 2
for n in 1 2 3; do
  id=$(docker exec garage-node$n /garage node id -q 2>/dev/null | cut -d@ -f1)
  g layout assign -z dc$n -c 4G "${id:0:16}" >/dev/null
done
g layout apply --version 1 >/dev/null
g key import --yes -n bench "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null
g key allow --create-bucket "$S3_ACCESS_KEY" >/dev/null
# the benchmark bucket is created here: when warp creates it on a brand new
# cluster, its first uploads may not see it yet ("Bucket not found")
g bucket create bench >/dev/null
g bucket allow --read --write --owner bench --key "$S3_ACCESS_KEY" >/dev/null
# optional tuning of the block resync (rebuild) speed, e.g. GARAGE_RESYNC=4,0:
# number of resync workers (default 1, max 8) and tranquility (default 2: the
# worker sleeps twice the time it worked, to protect client traffic)
if [ -n "${GARAGE_RESYNC:-}" ]; then
  g worker set -a resync-worker-count "${GARAGE_RESYNC%,*}" >/dev/null
  g worker set -a resync-tranquility "${GARAGE_RESYNC#*,}" >/dev/null
fi
sleep 2
g status
