#!/usr/bin/env bash
# run_warp.sh <system> <run_dir> <warp_op> [extra warp flags...]
# Runs one warp benchmark against the 3 endpoints of <system> while the
# sampler records the resources of the nodes and of the client.
# Output in <run_dir>: warp.csv.zst (every request), warp.txt (warp summary),
# resources.csv (sampler), meta.json.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
sys=$1 run_dir=$2 op=$3; shift 3
mkdir -p "$run_dir"; run_dir=$(cd "$run_dir" && pwd)

docker rm -f warp-client sampler reclaimer >/dev/null 2>&1 || true
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# roundrobin on purpose: a client that routes around slow hosts ("weighed")
# would hide exactly the imbalance we want the storage system to deal with.
warp_args=("$op" --host "$(s3_hosts "$sys")" --host-select roundrobin --lookup path
  --access-key "$S3_ACCESS_KEY" --secret-key "$S3_SECRET_KEY" --region "$S3_REGION"
  --bucket bench --benchdata /out/warp --no-color "$@")

docker run -d --name warp-client --network bench --cpus "$CLIENT_CPUS" \
  --memory "$CLIENT_MEM" -v "$run_dir:/out" "$WARP_IMAGE" "${warp_args[@]}" >/dev/null

targets=()
for c in "$sys-node1" "$sys-node2" "$sys-node3" warp-client; do
  pid=$(docker inspect -f '{{.State.Pid}}' "$c")
  [ "$pid" != 0 ] && targets+=("$c=$pid:$(cgroup_of "$c")")
done
docker run -d --name sampler --privileged --pid=host --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:ro -v "$run_dir:/out" "$TOOLS_IMAGE" \
  python3 /usr/local/bin/sample.py --out /out/resources.csv --dev "$(disk_dev)" \
  --interval "${SAMPLE_INTERVAL:-1}" "${targets[@]}" >/dev/null

# RECLAIM=1: every second, ask the kernel to drop the page cache of each node
# (cgroup v2 memory.reclaim), so reads really reach the (slow) disk instead
# of memory, without needing a data set larger than the RAM
if [ "${RECLAIM:-0}" = 1 ]; then
  cgs=""; for c in "$sys-node1" "$sys-node2" "$sys-node3"; do cgs="$cgs $(cgroup_of "$c")"; done
  docker run -d --name reclaimer --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup \
    "$TOOLS_IMAGE" sh -c "while true; do for c in $cgs; do echo 1G > /sys/fs/cgroup\$c/memory.reclaim 2>/dev/null; done; sleep 1; done" >/dev/null
fi

leader=""
if [ "$sys" = seaweedfs ]; then
  leader=$(docker exec seaweedfs-node1 wget -qO- http://localhost:9333/cluster/status 2>/dev/null | sed -n 's/.*"Leader":"\([^"]*\)".*/\1/p' || true)
fi

rc=$(docker wait warp-client)
docker logs warp-client > "$run_dir/warp.txt" 2>&1
docker stop -t 5 sampler >/dev/null; docker rm sampler warp-client >/dev/null
docker rm -f reclaimer >/dev/null 2>&1 || true

images=$(docker inspect -f '{{.Config.Image}}' "$sys-node1")
cat > "$run_dir/meta.json" <<JSON
{"system":"$sys","op":"$op","started":"$started","warp_rc":$rc,
 "image":"$images","warp_image":"$WARP_IMAGE","client_cpus":$CLIENT_CPUS,
 "seaweedfs_master_leader":"$leader","reclaim":${RECLAIM:-0},"hdd_nodes":"${HDD_NODES:-}",
 "client_nodes":"${CLIENT_NODES:-1 2 3}","warp_args":"$*"}
JSON
[ "$rc" = 0 ] || { log "warp exited with $rc, see $run_dir/warp.txt"; exit "$rc"; }
log "run done: $run_dir"
