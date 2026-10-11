#!/usr/bin/env bash
# kill_campaign.sh <system> <run_dir> <resource> <factor> <n_degraded> <victim>
# One node kill campaign, on a fresh cluster under the given condition:
#   1. preload 500 x 1 MiB objects of random data, with their SHA256;
#   2. continuous read load: back to back 20 s warp GET runs on the
#      preloaded objects (warp loses its data when interrupted, so the load
#      is cut in slices); the client only talks to the two nodes that are
#      never killed, so a dead endpoint is not counted as a storage failure;
#   3. WARM s of load, then the victim node is killed (container and disk);
#   4. DEGRADED s later: every preloaded object is read back and checked;
#   5. the node is replaced by an empty one, the system specific procedure
#      is applied (systems/<sys>/replace.sh), and the rebuild is considered
#      done when the new node holds at least 95 % of the bytes of the median
#      survivor (polled every 5 s, given up after REBUILD_TIMEOUT s);
#   6. AFTER s more of load, then a final check of every object.
# Resource "hdd": node1 gets a modelled hard disk (scripts/hdd.sh), other
# limits nominal. RECLAIM=1: the page cache of every container is dropped
# every second, so reads reach the disks.
# Output: events.json (timeline, checks), chunks/*.csv.zst (every request),
# rebuild.csv (bytes per node over time), resources-*.csv, limits.json.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
sys=$1 run=$2 res=$3 k=$4 nd=$5 victim=$6
WARM=${WARM:-60}; DEGRADED=${DEGRADED:-60}; AFTER=${AFTER:-60}
REBUILD_TIMEOUT=${REBUILD_TIMEOUT:-1500}
mkdir -p "$run/chunks"; run=$(cd "$run" && pwd)
compose="$BENCH_DIR/systems/$sys/compose.yml"
port=$(s3_port "$sys")
hosts=$(for i in 1 2 3; do if [ "$i" != "$victim" ]; then printf '%s-node%s:%s,' "$sys" "$i" "$port"; fi; done); hosts=${hosts%,}
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
ev() { echo "\"$1\": $2," >> "$run/.events"; }
: > "$run/.events"

tool() {
  docker run --rm --network bench --env-file "$BENCH_DIR/env/creds.env" \
    -v "$BENCH_DIR/scripts:/scripts:ro" -v "$run:/out" "$TOOLS_IMAGE" "$@"
}
check() {
  local out; out=$(tool python3 /scripts/preload.py check --hosts "$hosts" --manifest /out/manifest.json 2>/dev/null | tail -1 || true)
  echo "${out:-null}"
}

start_sampler() {
  local targets=() c pid
  for c in "$sys-node1" "$sys-node2" "$sys-node3"; do
    pid=$(docker inspect -f '{{.State.Pid}}' "$c" 2>/dev/null || echo 0)
    [ "$pid" != 0 ] && targets+=("$c=$pid:$(cgroup_of "$c")")
  done
  docker run -d --name sampler --privileged --pid=host --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:ro -v "$run:/out" "$TOOLS_IMAGE" \
    python3 /usr/local/bin/sample.py --out "/out/resources-$1.csv" --dev "$(disk_dev)" "${targets[@]}" >/dev/null
}
stop_sampler() { docker stop -t 3 sampler >/dev/null 2>&1 || true; docker rm sampler >/dev/null 2>&1 || true; }

volume_bytes() {
  host_tool sh -c "for i in 1 2 3; do d=/var/lib/docker/volumes/${sys}_d\$i/_data; \
    if [ -d \$d ]; then du -sb \$d | cut -f1; else echo 0; fi; done" | tr '\n' ' '
}

load_loop() {
  local i=0
  while [ ! -f "$run/.stop" ]; do
    i=$((i + 1))
    docker run --rm --name "warp-chunk" --network bench --cpus "$CLIENT_CPUS" --memory "$CLIENT_MEM" \
      -v "$run/chunks:/out" "$WARP_IMAGE" get --host "$hosts" --host-select roundrobin --lookup path \
      --access-key "$S3_ACCESS_KEY" --secret-key "$S3_SECRET_KEY" --region "$S3_REGION" \
      --bucket durable --list-existing --noclear --concurrent 8 --duration 20s \
      --benchdata "/out/c$(printf %04d $i)" --no-color > "$run/chunks/c$(printf %04d $i).txt" 2>&1 || true
  done
}

docker rm -f sampler warp-chunk reclaimer >/dev/null 2>&1 || true
rm -f "$run/.stop"
export HDD_NODES=""; [ "$res" = hdd ] && HDD_NODES=1
"$BENCH_DIR/scripts/up.sh" "$sys" > "$run/up.log" 2>&1
"$BENCH_DIR/scripts/limits.sh" "$sys" "$res" "$k" "$nd" > "$run/limits.json"
leader=""
[ "$sys" = seaweedfs ] && leader=$(docker exec seaweedfs-node1 wget -qO- http://localhost:9333/cluster/status 2>/dev/null | sed -n 's/.*"Leader":"\([^"]*\)".*/\1/p' || true)

log "$sys: preload"
pre=$(tool python3 /scripts/preload.py write --hosts "$hosts" --manifest /out/manifest.json --objects 500 | tail -1 || true)
if [ -z "$pre" ] || [ ! -s "$run/manifest.json" ]; then
  log "$sys: preload failed"; "$BENCH_DIR/scripts/down.sh" "$sys" > /dev/null 2>&1; exit 1
fi
ev preload "$pre"

start_sampler a
if [ "${RECLAIM:-0}" = 1 ]; then
  docker run -d --name reclaimer --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup \
    "$TOOLS_IMAGE" sh -c 'while true; do for f in $(find /sys/fs/cgroup -path "*docker*" -name memory.reclaim); do echo 1G > $f 2>/dev/null; done; sleep 1; done' >/dev/null
fi
load_loop & loop_pid=$!
ev t_load_start "$(now)"
sleep "$WARM"

log "$sys: kill node$victim"
ev t_kill "$(now)"
docker kill "$sys-node$victim" >/dev/null
sleep "$DEGRADED"

ev t_check_degraded_start "$(now)"
ev check_degraded "$(check)"
ev t_check_degraded_end "$(now)"

log "$sys: replace node$victim"
stop_sampler
docker rm -f "$sys-node$victim" >/dev/null
docker volume rm "${sys}_d$victim" >/dev/null
ev t_replace "$(now)"
docker compose -f "$compose" up -d "node$victim" > /dev/null 2>&1
"$BENCH_DIR/systems/$sys/replace.sh" "$victim" > "$run/replace.log" 2>&1 || log "replace hook failed, see replace.log"
ev t_replace_done "$(now)"
"$BENCH_DIR/scripts/limits.sh" "$sys" "$res" "$k" "$nd" > "$run/limits-after.json"
start_sampler b

echo "t,node1,node2,node3" > "$run/rebuild.csv"
rebuilt=0
deadline=$(( $(date +%s) + REBUILD_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  set -- $(volume_bytes)
  echo "$(now),$1,$2,$3" >> "$run/rebuild.csv"
  if python3 - "$victim" "$1" "$2" "$3" <<'PY'
import statistics, sys
v = int(sys.argv[1]); b = [int(x) for x in sys.argv[2:5]]
others = [b[i] for i in range(3) if i != v - 1]
sys.exit(0 if b[v - 1] >= 0.95 * statistics.median(others) else 1)
PY
  then rebuilt=1; break; fi
  sleep 5
done
ev t_rebuilt "$( [ $rebuilt = 1 ] && now || echo null)"
log "$sys: rebuilt=$rebuilt"
sleep "$AFTER"

touch "$run/.stop"; wait "$loop_pid" || true
ev t_load_end "$(now)"
stop_sampler
docker rm -f reclaimer >/dev/null 2>&1 || true
ev check_final "$(check)"
{
  echo "{"
  cat "$run/.events"
  echo "\"system\": \"$sys\", \"resource\": \"$res\", \"factor\": $k, \"n_degraded\": $nd,"
  echo "\"victim\": $victim, \"client_hosts\": \"$hosts\", \"seaweedfs_master_leader\": \"$leader\","
  echo "\"warp_image\": \"$WARP_IMAGE\", \"reclaim\": ${RECLAIM:-0}, \"hdd_nodes\": \"$HDD_NODES\", \"rebuilt\": $rebuilt}"
} > "$run/events.json"
rm -f "$run/.events" "$run/.stop"
python3 -c "import json; json.load(open('$run/events.json'))" && log "$sys: campaign done: $run"
"$BENCH_DIR/scripts/down.sh" "$sys" > /dev/null 2>&1
