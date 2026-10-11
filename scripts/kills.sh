#!/usr/bin/env bash
# kills.sh <out_dir>: all node kill campaigns, random order, resumable.
#   homogeneous cluster, node3 killed
#   one degraded node (all resources, 5x): the weak node1 killed
#   one degraded node (all resources, 5x): a healthy node (node3) killed
# x 3 systems x REPS repetitions.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
out=$1
REPS=${REPS:-2}
SYSTEMS=${SYSTEMS:-"garage minio seaweedfs"}
mkdir -p "$out"; out=$(cd "$out" && pwd)
plan="$out/plan.txt"
# SCENARIOS: "resource factor n_degraded victim" separated by commas
SCENARIOS=${SCENARIOS:-"none 1 0 3,all 5 1 1,all 5 1 3"}
if [ ! -s "$plan" ]; then
  for s in $SYSTEMS; do for r in $(seq 1 "$REPS"); do
    echo "$SCENARIOS" | tr ',' '\n' | while read -r sc; do echo "$s $sc $r"; done
  done; done | python3 -c 'import random,sys; l=sys.stdin.readlines(); random.seed(872); random.shuffle(l); print("".join(l), end="")' > "$plan"
fi
while read -r s res k nd victim r; do
  run="$out/$s-$res-${k}x$nd-kill$victim-r$r"
  [ -f "$run/events.json" ] && continue
  rm -rf "$run"
  log "campaign $s $res ${k}x$nd kill node$victim rep $r"
  "$BENCH_DIR/scripts/kill_campaign.sh" "$s" "$run" "$res" "$k" "$nd" "$victim" > "$run.log" 2>&1 \
    || { log "FAILED $run"; "$BENCH_DIR/scripts/down.sh" "$s" >/dev/null 2>&1 || true; }
done < "$plan"
uv run --quiet --script "$BENCH_DIR/scripts/kill_report.py" "$out" > "$out/kill.md"
log "kills done"
