#!/usr/bin/env bash
# replace.sh <n>: node n came back empty. Its filer reloads the metadata from
# its peers by itself, but SeaweedFS does not re-replicate volumes on its own
# right away: the operator runs volume.fix.replication, which we do as soon
# as the new volume server is registered, then again until nothing is left
# to fix (each pass adds at most one replica per volume).
set -euo pipefail
n=$1
p=1; [ "$n" = 1 ] && p=2
for i in $(seq 1 120); do
  docker exec seaweedfs-node$n wget -qO /dev/null http://localhost:8333/healthz 2>/dev/null && break
  sleep 1
done
sleep 5
for pass in 1 2 3; do
  printf 'lock\nvolume.fix.replication -apply\nunlock\n' | \
    docker exec -i seaweedfs-node$p weed shell -master=seaweedfs-node$p:9333 > /tmp/fix.$$ 2>&1 || true
  grep -qiE 'replicat(e|ing) volume|copy' /tmp/fix.$$ || break
  sleep 5
done
rm -f /tmp/fix.$$
echo "seaweedfs: node $n back, volume.fix.replication done ($pass passes)"
