#!/usr/bin/env bash
# sweep.sh <out_dir> [sweeps...]
# Runs the declared sweeps around the reference point
# (all resources, 5x slower, 1 degraded node, 1 MiB objects), one axis at a time:
#   S1  resource: cpu, disk, net, all          (5x, 1 node, 1 MiB)
#   S2  factor: 1, 2, 5, 10                    (all, 1 node, 1 MiB)
#   S3  degraded nodes: 0, 1, 2                (all, 5x, 1 MiB)
#   S4  object size: 16 KiB, 1 MiB, 8 MiB, each on the homogeneous
#       reference and on the reference point (ratios are per size)
#   GW  factor 1, 2, 5, 10 (all, 1 node, 1 MiB), meant to be run with
#       CLIENT_NODES="2 3": the client never uses the degraded node as its
#       gateway, which separates the storage effect from the gateway effect
#   CHK the homogeneous reference and the reference point only, to check
#       that a change of the host (e.g. VM memory) does not move the ratios
#   HDD node1 gets a modelled consumer hard disk (scripts/hdd.sh) and keeps
#       its nominal CPU and network; 16 KiB and 1 MiB objects, each with its
#       homogeneous reference. Meant to be run with RECLAIM_GET=1, so reads
#       are not served from the page cache.
# Conditions shared by several sweeps are run once. Every condition is run
# for PUT and GET, REPS times, in a random order, on a fresh cluster.
# Resumable: successful runs are skipped.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
out=$1; shift
sweeps=${*:-S1 S2 S4}
REPS=${REPS:-3}
PUT_DUR=${PUT_DUR:-60s}
GET_DUR=${GET_DUR:-30s}
SYSTEMS=${SYSTEMS:-"garage minio seaweedfs"}
mkdir -p "$out"; out=$(cd "$out" && pwd)

# condition = "resource factor n_degraded size"
conds() {
  for s in $sweeps; do
    case "$s" in
      S1) for r in cpu disk net all; do echo "$r 5 1 1MiB"; done ;;
      S2) echo "none 1 0 1MiB"; for k in 2 5 10; do echo "all $k 1 1MiB"; done ;;
      S3) echo "none 1 0 1MiB"; for n in 1 2; do echo "all 5 $n 1MiB"; done ;;
      S4) for z in 16KiB 1MiB 8MiB; do echo "none 1 0 $z"; echo "all 5 1 $z"; done ;;
      GW) echo "none 1 0 1MiB"; for k in 2 5 10; do echo "all $k 1 1MiB"; done ;;
      CHK) echo "none 1 0 1MiB"; echo "all 5 1 1MiB" ;;
      HDD) for z in 16KiB 1MiB; do echo "none 1 0 $z"; echo "hdd 1 1 $z"; done ;;
    esac
  done | sort -u
}

# objects prepared for GET: about 200 MiB in total, at most 2000 objects
get_objects() {
  case "$1" in
    16KiB) echo 2000 ;;
    1MiB) echo 200 ;;
    8MiB) echo 25 ;;
  esac
}

plan="$out/plan.txt"
if [ ! -s "$plan" ]; then
  for sys in $SYSTEMS; do
    conds | while read -r res k nd size; do
      for op in put get; do for r in $(seq 1 "$REPS"); do
        echo "$sys $res $k $nd $size $op $r"
      done; done
    done
  done | python3 -c 'import random,sys; l=sys.stdin.readlines(); random.seed(871); random.shuffle(l); print("".join(l), end="")' > "$plan"
fi
log "$(wc -l < "$plan" | tr -d ' ') runs in $plan"

while read -r sys res k nd size op r; do
  run="$out/$sys-$res-${k}x$nd-$size-$op-r$r"
  grep -q '"warp_rc":0' "$run/meta.json" 2>/dev/null && continue
  rm -rf "$run"; mkdir -p "$run"
  log "$sys $res ${k}x$nd $size $op rep $r"
  # a "hdd" condition gives node1 a modelled hard disk, other limits nominal
  export HDD_NODES=""; [ "$res" = hdd ] && HDD_NODES=1
  export RECLAIM=0; [ "$op" = get ] && RECLAIM=${RECLAIM_GET:-0}
  if ! "$BENCH_DIR/scripts/up.sh" "$sys" > "$run/up.log" 2>&1; then
    log "FAILED up $run"; "$BENCH_DIR/scripts/down.sh" "$sys" >/dev/null 2>&1 || true; continue
  fi
  "$BENCH_DIR/scripts/limits.sh" "$sys" "$res" "$k" "$nd" > "$run/limits.json"
  [ -n "$HDD_NODES" ] && grep '"hdd"' "$run/up.log" > "$run/hdd.json"
  if [ "$op" = put ]; then
    args=(put --obj.size "$size" --concurrent 8 --duration "$PUT_DUR")
  else
    args=(get --obj.size "$size" --concurrent 8 --objects "$(get_objects "$size")" --duration "$GET_DUR")
  fi
  "$BENCH_DIR/scripts/run_warp.sh" "$sys" "$run" "${args[@]}" || log "FAILED $run"
  "$BENCH_DIR/scripts/down.sh" "$sys" > /dev/null 2>&1
done < "$plan"

"$BENCH_DIR/scripts/summarize.sh" "$out"/*/ > /dev/null
log "sweep done"
