#!/usr/bin/env bash
# replace.sh <n>: node n was replaced by an empty one (new identity). Same
# procedure as the Garage documentation: connect the new node, give it the
# zone and capacity of the dead one, remove the dead one, apply the layout,
# then tell Garage that the old node is dead for good (skip-dead-nodes),
# otherwise the new layout waits forever to drain data from it.
set -euo pipefail
n=$1
p=1; [ "$n" = 1 ] && p=2
g() { docker exec -e RUST_LOG=warn garage-node$p /garage "$@" 2>/dev/null; }

for i in $(seq 1 60); do
  new=$(docker exec -e RUST_LOG=warn garage-node$n /garage node id -q 2>/dev/null | cut -d@ -f1) && [ -n "$new" ] && break
  sleep 1
done
g node connect "${new}@garage-node$n:3901" >/dev/null
old=$(g layout show | awk -v z="dc$n" '$1 ~ /^[0-9a-f]+$/ && $3 == z {print $1; exit}')
g layout remove "$old" >/dev/null
g layout assign -z "dc$n" -c 4G "${new:0:16}" >/dev/null
v=$(g layout show | sed -n 's/.*Current cluster layout version: \([0-9]*\).*/\1/p')
g layout apply --version $((v + 1)) >/dev/null
# a new node starts with the default resync settings
if [ -n "${GARAGE_RESYNC:-}" ]; then
  g worker set -a resync-worker-count "${GARAGE_RESYNC%,*}" >/dev/null
  g worker set -a resync-tranquility "${GARAGE_RESYNC#*,}" >/dev/null
fi
sleep 2
g layout skip-dead-nodes --version $((v + 1)) >/dev/null
# optional: start a full sync now instead of waiting for the next anti
# entropy round (every 10 minutes for sharded tables, src/table/replication/
# sharded.rs), which is what delays the rebuild by up to 10 minutes
if [ "${GARAGE_REPAIR:-0}" = 1 ]; then
  sleep 5
  g repair -a --yes tables >/dev/null
  g repair -a --yes blocks >/dev/null
fi
echo "garage: node $n replaced, $old -> ${new:0:16}, layout v$((v + 1))"
