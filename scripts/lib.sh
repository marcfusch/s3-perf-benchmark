# Shared helpers, sourced by the other scripts.
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_IMAGE=mgl870/benchtools:1
# v1.0.8 on purpose: from v1.1.0 to v1.3.1 the random generator sends almost
# identical objects (see uniqueness.py), which Garage deduplicates.
WARP_IMAGE=minio/warp:v1.0.8
NODES=(1 2 3)

source "$BENCH_DIR/env/budget.env"
source "$BENCH_DIR/env/creds.env"

s3_port() {
  case "$1" in
    garage) echo 3900 ;;
    minio) echo 9000 ;;
    seaweedfs) echo 8333 ;;
    *) echo "unknown system: $1" >&2; return 1 ;;
  esac
}

# Comma separated list of the three S3 endpoints, the client spreads its
# requests over them.
s3_hosts() {
  local p; p=$(s3_port "$1") || return 1
  echo "$1-node1:$p,$1-node2:$p,$1-node3:$p"
}

# Runs a command in the helper image with access to the VM cgroups and pids.
host_tool() {
  docker run --rm --privileged --pid=host --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup -v /var/lib/docker:/var/lib/docker:ro \
    "$TOOLS_IMAGE" "$@"
}

# cgroup v2 path of a running container, relative to /sys/fs/cgroup.
cgroup_of() {
  local pid; pid=$(docker inspect -f '{{.State.Pid}}' "$1")
  host_tool sh -c "sed -n 's/^0:://p' /proc/$pid/cgroup"
}

# major:minor of the whole disk holding the docker volumes (io.max wants a disk, not a partition).
disk_dev() {
  if [ -n "${DISK_DEV:-}" ]; then echo "$DISK_DEV"; return; fi
  host_tool sh -c '
    d=$(mountpoint -d /var/lib/docker)
    if [ -e /sys/dev/block/$d/partition ]; then
      p=$(basename "$(dirname "$(readlink -f /sys/dev/block/$d)")"); cat /sys/block/$p/dev
    else echo $d; fi'
}

# Gives the space freed in the VM back to the host (the Colima disk is a
# sparse file that otherwise only grows).
trim_disk() {
  docker run --rm --privileged -v /var/lib/docker:/var/lib/docker "$TOOLS_IMAGE" \
    fstrim /var/lib/docker >/dev/null 2>&1 || true
}

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
