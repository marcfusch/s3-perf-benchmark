#!/usr/bin/env bash
# queue.sh <queue_file>: runs the steps of a queue file one after the other,
# in this single process, so two campaigns can never overlap. One step per
# line (a shell command run from the bench directory); empty lines and lines
# starting with # are ignored. A step that succeeds is recorded in
# <queue_file>.done and skipped when the queue is started again, and every
# campaign script is itself resumable, so stopping and restarting the queue
# loses at most the run in progress.
# Start it detached and without sleep:
#   nohup caffeinate -is scripts/queue.sh queues/tonight.txt > results/queue.log 2>&1 &
set -uo pipefail
cd "$(dirname "$0")/.."
q=$1
done_file="$q.done"
touch "$done_file"
# one queue at a time: mkdir is atomic, the lock goes away when we exit
lock="$(pwd)/results/.queue.lock"
mkdir -p results
if ! mkdir "$lock" 2>/dev/null; then
  echo "another queue.sh is already running ($lock exists), refusing to start" >&2; exit 1
fi
trap 'rmdir "$lock"' EXIT
while IFS= read -r step; do
  case "$step" in ''|'#'*) continue ;; esac
  grep -qxF "$step" "$done_file" && { echo "[$(date +%H:%M:%S)] skip (done): $step"; continue; }
  echo "[$(date +%H:%M:%S)] START $step"
  if bash -c "$step"; then
    echo "$step" >> "$done_file"
    echo "[$(date +%H:%M:%S)] DONE  $step"
  else
    echo "[$(date +%H:%M:%S)] FAIL  $step (queue goes on, rerun the queue to retry)"
  fi
done < "$q"
echo "[$(date +%H:%M:%S)] queue finished"
