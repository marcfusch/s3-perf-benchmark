#!/usr/bin/env bash
# validate_loadgen.sh [out_dir]
# Validation of the load generator, on the homogeneous reference of each system:
#   1. data uniqueness: the objects warp writes must all be distinct,
#      otherwise Garage (dedup + compression) is favoured;
#   2. cross check with an independent client (s3load.py, boto3) at the
#      same size and concurrency, PUT then GET: same order of magnitude
#      and same ranking of conditions is what we need, not equal numbers;
#   3. client headroom: the warp container must not be CPU bound;
#   4. byte accounting: what warp says it sent vs what left the client NIC.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
out=${1:-$BENCH_DIR/results/loadgen-$(date +%Y%m%d-%H%M)}
DUR=${DUR:-30}
CONC=${CONC:-8}
SYSTEMS=${SYSTEMS:-"garage minio seaweedfs"}
mkdir -p "$out"; out=$(cd "$out" && pwd)

s3load() {
  docker run --rm --network bench --cpus "$CLIENT_CPUS" --memory "$CLIENT_MEM" \
    --env-file "$BENCH_DIR/env/creds.env" -v "$out:/out" "$TOOLS_IMAGE" \
    python3 /usr/local/bin/s3load.py --hosts "$(s3_hosts "$1")" --size 1048576 \
    --concurrent "$CONC" --duration "$DUR" --op "$2" --out "/out/$1-s3load-$2.json" >/dev/null
}

for s in $SYSTEMS; do
  log "== $s"
  "$BENCH_DIR/scripts/up.sh" "$s" > /dev/null 2>&1
  limits=$("$BENCH_DIR/scripts/limits.sh" "$s" none 1 0)
  for op in put get; do
    run="$out/$s-warp-$op"; mkdir -p "$run"; echo "$limits" > "$run/limits.json"
    extra=(); [ "$op" = get ] && extra=(--objects 300)
    # --noclear keeps the PUT objects for the uniqueness check
    "$BENCH_DIR/scripts/run_warp.sh" "$s" "$run" "$op" --obj.size 1MiB --concurrent "$CONC" \
      --duration "${DUR}s" --noclear ${extra[@]+"${extra[@]}"}
    if [ "$op" = put ]; then
      p=$(s3_port "$s")
      docker run --rm --network bench --env-file "$BENCH_DIR/env/creds.env" "$TOOLS_IMAGE" \
        python3 /usr/local/bin/uniqueness.py --host "$s-node1:$p" --bucket bench --max 100 \
        > "$out/$s-uniqueness.json"
    fi
  done
  s3load "$s" put
  s3load "$s" get
  "$BENCH_DIR/scripts/down.sh" "$s" > /dev/null 2>&1
done

"$BENCH_DIR/scripts/summarize.sh" "$out"/*-warp-*/ > /dev/null
python3 "$BENCH_DIR/scripts/loadgen_report.py" "$out" | tee "$out/loadgen.md"
