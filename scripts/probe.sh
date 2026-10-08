#!/usr/bin/env bash
# probe.sh <test> <seconds> [target]: runs inside a probe container (helper
# image) and prints one number. Used by calibrate_limits.sh.
#   cpu       stress-ng bogo ops/s (real time), 4 workers (more than any node gets)
#   disk_w    sequential write MiB/s, 1 MiB blocks, O_DIRECT
#   disk_r    sequential read MiB/s
#   disk_rr   random read IOPS, 4 KiB
#   disk_rw   random write IOPS, 4 KiB
#   net_tx    Mbit/s sent to target (iperf3 server port in target as host:port)
#   net_rx    Mbit/s received from target
#   rtt       mean ping RTT in ms to target
set -euo pipefail
t=$1 s=$2 target=${3:-}
f=/data/probe.bin
fio_run() {
  fio --name=p --filename=$f --size=256M --direct=1 --ioengine=libaio --time_based \
    --runtime="$s" --output-format=json "$@"
}
case "$t" in
  cpu) stress-ng --cpu 4 --cpu-method int64 -t "${s}s" --metrics --yaml /tmp/m.yaml >/dev/null 2>&1
       awk '/bogo-ops-per-second-real-time/ {print $2; exit}' /tmp/m.yaml ;;
  disk_w) fio_run --rw=write --bs=1M --iodepth=8 | jq '.jobs[0].write.bw_bytes / 1048576' ;;
  disk_r) fio_run --rw=read --bs=1M --iodepth=8 | jq '.jobs[0].read.bw_bytes / 1048576' ;;
  disk_rr) fio_run --rw=randread --bs=4k --iodepth=32 | jq '.jobs[0].read.iops' ;;
  disk_rw) fio_run --rw=randwrite --bs=4k --iodepth=32 | jq '.jobs[0].write.iops' ;;
  net_tx) iperf3 -c "${target%:*}" -p "${target#*:}" -t "$s" -J | jq '.end.sum_received.bits_per_second / 1e6' ;;
  net_rx) iperf3 -c "${target%:*}" -p "${target#*:}" -t "$s" -R -J | jq '.end.sum_received.bits_per_second / 1e6' ;;
  rtt) ping -q -c $((s * 5)) -i 0.2 "${target%:*}" | awk -F/ '/^rtt|^round-trip/ {print $5}' ;;
  *) echo "unknown test $t" >&2; exit 1 ;;
esac
