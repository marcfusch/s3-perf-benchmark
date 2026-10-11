#!/usr/bin/env bash
# host_monitor.sh <out.csv>: every 5 s, logs the memory state of the macOS
# host (swap ins and outs, compressor, free pages) and the resident memory of
# the VM, to detect runs during which the VM was being swapped by the host.
out=$1
echo "t,swapins,swapouts,pageouts,compressed_pages,free_pages,swap_used_mb,vm_rss_kb" > "$out"
while true; do
  v=$(vm_stat)
  get() { echo "$v" | awk -F: -v k="$1" '$1 == k {gsub(/[ .]/, "", $2); print $2}'; }
  swap=$(sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')
  rss=$(ps -Ao rss,comm | awk '/Virtualization.VirtualMachine/ {s += $1} END {print s + 0}')
  echo "$(date +%s),$(get Swapins),$(get Swapouts),$(get Pageouts),$(get 'Pages stored in compressor'),$(get 'Pages free'),$swap,$rss" >> "$out"
  sleep 5
done
