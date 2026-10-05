#!/usr/bin/env bash
# pilot.sh [out_dir] [systems...]
# First pilot run: checks the whole chain (deploy, limits, load, sampling,
# summary) on every system, on the homogeneous reference and on one
# degraded condition, with short runs. Not meant to produce results.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
out=${1:-$BENCH_DIR/results/pilot-$(date +%Y%m%d-%H%M)}; [ $# -gt 0 ] && shift
if [ $# -gt 0 ]; then systems=("$@"); else systems=(garage minio seaweedfs); fi
DUR=${DUR:-30s}
mkdir -p "$out"

# condition label, then limits.sh arguments
conditions=("homog none 1 0" "cpu5x1 cpu 5 1")
# workload label, then warp arguments
workloads=("put put --obj.size 1MiB --concurrent 8"
           "get get --obj.size 1MiB --concurrent 8 --objects 300"
           "mixed mixed --obj.size 1MiB --concurrent 8 --objects 300")

for sys in "${systems[@]}"; do
  log "== $sys"
  "$BENCH_DIR/scripts/up.sh" "$sys" >/dev/null
  for cond in "${conditions[@]}"; do
    set -- $cond; clabel=$1; shift
    for wl in "${workloads[@]}"; do
      set -- $wl; wlabel=$1; shift
      run="$out/$sys-$clabel-$wlabel"
      mkdir -p "$run"
      "$BENCH_DIR/scripts/limits.sh" "$sys" ${cond#* } > "$run/limits.json"
      "$BENCH_DIR/scripts/run_warp.sh" "$sys" "$run" "$@" --duration "$DUR" || log "FAILED $run"
    done
  done
  "$BENCH_DIR/scripts/down.sh" "$sys" >/dev/null 2>&1
done
"$BENCH_DIR/scripts/summarize.sh" --csv "$out"/*/ > "$out/pilot.csv"
column -s, -t < "$out/pilot.csv"
