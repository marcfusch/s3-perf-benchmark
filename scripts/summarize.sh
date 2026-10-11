#!/usr/bin/env bash
# summarize.sh [--csv] run_dir...: runs summarize.py (it needs zstandard)
# with uv on the host when available, otherwise in the helper image (run
# directories must then be under bench/results).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
if command -v uv >/dev/null 2>&1; then
  exec uv run --quiet --script "$BENCH_DIR/scripts/summarize.py" "$@"
fi
args=()
for a in "$@"; do
  case "$a" in
    -*) args+=("$a") ;;
    *) p=$(cd "$a" && pwd); args+=("/results${p#$BENCH_DIR/results}") ;;
  esac
done
docker run --rm -v "$BENCH_DIR/results:/results" -v "$BENCH_DIR/scripts:/scripts:ro" \
  "$TOOLS_IMAGE" python3 /scripts/summarize.py "${args[@]}"
