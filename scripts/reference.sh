#!/usr/bin/env bash
# reference.sh [out_dir]
# Calibration of the homogeneous reference: every system x workload is run
# REPS times on identical nodes, in a random order, each run on a freshly
# deployed cluster. Tells (a) the run to run noise, hence how many
# repetitions the sweeps need, and (b) whether the homogeneous condition is
# really homogeneous (per node load and latency).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
out=${1:-$BENCH_DIR/results/reference-$(date +%Y%m%d-%H%M)}
REPS=${REPS:-5}
DUR=${DUR:-30s}
SYSTEMS=${SYSTEMS:-"garage minio seaweedfs"}
mkdir -p "$out"; out=$(cd "$out" && pwd)

workload_args() {
  case "$1" in
    put) echo "put --obj.size 1MiB --concurrent 8" ;;
    get) echo "get --obj.size 1MiB --concurrent 8 --objects 200" ;;
    mixed) echo "mixed --obj.size 1MiB --concurrent 8 --objects 200" ;;
  esac
}

plan="$out/plan.txt"
if [ ! -s "$plan" ]; then
  for s in $SYSTEMS; do for w in put get mixed; do for r in $(seq 1 "$REPS"); do
    echo "$s $w $r"; done; done; done | python3 -c 'import random,sys; l=sys.stdin.readlines(); random.seed(870); random.shuffle(l); print("".join(l), end="")' > "$plan"
fi

# resumable: successful runs are skipped, failed ones are redone
while read -r s w r; do
  run="$out/$s-$w-r$r"
  grep -q '"warp_rc":0' "$run/meta.json" 2>/dev/null && continue
  rm -rf "$run"
  log "$s $w rep $r"
  "$BENCH_DIR/scripts/up.sh" "$s" > /dev/null 2>&1
  mkdir -p "$run"
  "$BENCH_DIR/scripts/limits.sh" "$s" none 1 0 > "$run/limits.json"
  "$BENCH_DIR/scripts/run_warp.sh" "$s" "$run" $(workload_args "$w") --duration "$DUR" || log "FAILED $run"
  "$BENCH_DIR/scripts/down.sh" "$s" > /dev/null 2>&1
done < "$plan"

"$BENCH_DIR/scripts/summarize.sh" "$out"/*/ > /dev/null
python3 "$BENCH_DIR/scripts/reference_report.py" "$out" | tee "$out/reference.md"
