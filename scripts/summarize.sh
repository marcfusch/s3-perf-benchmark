#!/usr/bin/env bash
# summarize.sh [--csv] run_dir...: runs summarize.py in the helper image
# (it needs zstandard). Run directories must be under bench/results.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
args=()
for a in "$@"; do
  case "$a" in
    -*) args+=("$a") ;;
    *) p=$(cd "$a" && pwd); args+=("/results${p#$BENCH_DIR/results}") ;;
  esac
done
docker run --rm -v "$BENCH_DIR/results:/results" -v "$BENCH_DIR/scripts:/scripts:ro" \
  "$TOOLS_IMAGE" python3 /scripts/summarize.py "${args[@]}"
