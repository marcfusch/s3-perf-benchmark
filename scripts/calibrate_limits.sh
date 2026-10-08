#!/usr/bin/env bash
# calibrate_limits.sh [out_dir]
# Checks that the limits really do what limits.sh claims, on three probe
# containers that get exactly the same treatment as the storage nodes
# (same limits.sh code path, same disk, same network).
#   1. "raw": no limit at all, the three probes in parallel. Tells how much
#      headroom the host has above the nominal budget: if 3 x nominal is
#      close to raw, the host and not the limits sets the pace.
#   2. homogeneous reference, one degraded condition per resource, and the
#      most extreme point of the sweeps (all resources, 10x, 2 nodes), where
#      the only healthy node gets 2.8x the nominal budget.
# All three probes always run a test at the same time, like a real cluster.
# Output: calibration.csv (condition,node,test,measured,limit).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
out=${1:-$BENCH_DIR/results/calib-$(date +%Y%m%d-%H%M)}
S=${S:-10}
FACTOR=${FACTOR:-5}
mkdir -p "$out"; out=$(cd "$out" && pwd)

cleanup() { docker rm -f probe-node1 probe-node2 probe-node3 probe-sink >/dev/null 2>&1 || true
            docker volume rm probe-d1 probe-d2 probe-d3 >/dev/null 2>&1 || true; trim_disk; }
trap cleanup EXIT
cleanup
docker network inspect bench >/dev/null 2>&1 || docker network create bench >/dev/null
for i in 1 2 3; do
  docker run -d --name probe-node$i --hostname probe-node$i --network bench \
    -v probe-d$i:/data -v "$BENCH_DIR/scripts:/scripts:ro" "$TOOLS_IMAGE" sleep infinity >/dev/null
done
# unlimited sink for the network tests, one iperf3 server per node
docker run -d --name probe-sink --network bench "$TOOLS_IMAGE" sh -c \
  'for p in 5201 5202 5203; do iperf3 -s -p $p -D; done; sleep infinity' >/dev/null
sleep 2

echo "condition,node,test,measured,limit" > "$out/calibration.csv"

# limit_of <limits.json> <node> <test>: the limit that applies to this test
limit_of() {
  [ -s "$1" ] || { echo ""; return; }
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
l = json.load(open(sys.argv[1]))["nodes"][sys.argv[2]]
m = {"cpu": l["cpus"], "disk_w": l["wbps"] / 2**20, "disk_r": l["rbps"] / 2**20,
     "disk_rr": l["riops"], "disk_rw": l["wiops"], "net_tx": l["net_mbit"],
     "net_rx": l["net_mbit"], "rtt": l["net_delay_ms"]}
print(round(m[sys.argv[3]], 3))
PY
}

measure() {
  local cond=$1 lim=$2 t
  for t in cpu disk_w disk_r disk_rr disk_rw net_tx net_rx rtt; do
    log "$cond: $t"
    for i in 1 2 3; do
      docker exec probe-node$i /scripts/probe.sh "$t" "$S" "probe-sink:520$i" > "$out/.$i" 2>/dev/null &
    done
    wait
    for i in 1 2 3; do
      echo "$cond,probe-node$i,$t,$(tr -d '\n' < "$out/.$i"),$(limit_of "$lim" probe-node$i "$t")" >> "$out/calibration.csv"
    done
  done
  rm -f "$out"/.1 "$out"/.2 "$out"/.3
}

measure raw ""
for cond in "none 1 0" "cpu $FACTOR 1" "disk $FACTOR 1" "net $FACTOR 1" "all 10 2"; do
  set -- $cond; label="$1-$2x$3"
  "$BENCH_DIR/scripts/limits.sh" probe $cond > "$out/limits-$label.json"
  measure "$label" "$out/limits-$label.json"
done
python3 "$BENCH_DIR/scripts/calib_report.py" "$out/calibration.csv" | tee "$out/calibration.md"
