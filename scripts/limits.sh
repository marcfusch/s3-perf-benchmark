#!/usr/bin/env bash
# limits.sh <prefix> <resource> <factor> <n_degraded>
#   prefix      container prefix, the nodes are <prefix>-node1..3 (a system name or "probe")
#   resource    none | cpu | disk | net | all   (sweep S1)
#   factor      how many times slower a degraded node is: 1, 2, 5, 10   (sweep S2)
#   n_degraded  0, 1 or 2, the degraded nodes are node1 then node2   (sweep S3)
#
# The cluster budget (3 x nominal) is conserved: what a degraded node loses
# is shared equally between the healthy ones. Link delay is the exception,
# it is not a budget, a degraded node gets factor x the nominal delay.
# Writes the applied values as JSON on stdout.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
prefix=$1 res=$2 k=$3 nd=$4
[ "$res" = none ] && { k=1; nd=0; }

# share <nominal> <node>: value for this node, rounded to an integer unless the nominal is fractional
share() {
  awk -v b="$1" -v k="$k" -v nd="$nd" -v i="$2" 'BEGIN {
    if (i <= nd) v = b / k; else v = b + nd * (b - b / k) / (3 - nd);
    if (b == int(b) && b >= 10) printf "%d", v; else printf "%.3f", v }'
}
hits() { [ "$res" = all ] || [ "$res" = "$1" ]; }

dev=$(disk_dev)
echo "{\"prefix\":\"$prefix\",\"resource\":\"$res\",\"factor\":$k,\"n_degraded\":$nd,\"disk_dev\":\"$dev\",\"nodes\":{"
for i in "${NODES[@]}"; do
  c="$prefix-node$i"
  cpu=$CPU_PER_NODE rbps=$DISK_RBPS wbps=$DISK_WBPS riops=$DISK_RIOPS wiops=$DISK_WIOPS
  mbit=$NET_MBIT delay=$NET_DELAY_MS
  if hits cpu; then cpu=$(share "$CPU_PER_NODE" "$i"); fi
  if hits disk; then
    rbps=$(share "$DISK_RBPS" "$i"); wbps=$(share "$DISK_WBPS" "$i")
    riops=$(share "$DISK_RIOPS" "$i"); wiops=$(share "$DISK_WIOPS" "$i")
  fi
  if hits net; then
    mbit=$(share "$NET_MBIT" "$i")
    [ "$i" -le "$nd" ] && delay=$(awk -v d="$NET_DELAY_MS" -v k="$k" 'BEGIN{print d*k}')
  fi

  docker update --cpus "$cpu" --memory "$MEM_PER_NODE" --memory-swap "$MEM_PER_NODE" "$c" >/dev/null
  cg=$(cgroup_of "$c")
  host_tool sh -c "echo '$dev rbps=$rbps wbps=$wbps riops=$riops wiops=$wiops' > /sys/fs/cgroup$cg/io.max"
  docker run --rm --net "container:$c" --cap-add NET_ADMIN "$TOOLS_IMAGE" sh -c "
    tc qdisc del dev eth0 root 2>/dev/null; tc qdisc del dev eth0 ingress 2>/dev/null
    tc qdisc add dev eth0 root handle 1: netem delay ${delay}ms rate ${mbit}mbit limit 100000
    tc qdisc add dev eth0 handle ffff: ingress
    tc filter add dev eth0 parent ffff: matchall action police rate ${mbit}mbit burst 1m drop"

  sep=","; [ "$i" = "${NODES[${#NODES[@]}-1]}" ] && sep=""
  echo "\"$c\":{\"cpus\":$cpu,\"mem\":\"$MEM_PER_NODE\",\"rbps\":$rbps,\"wbps\":$wbps,\"riops\":$riops,\"wiops\":$wiops,\"net_mbit\":$mbit,\"net_delay_ms\":$delay}$sep"
done
echo "}}"
