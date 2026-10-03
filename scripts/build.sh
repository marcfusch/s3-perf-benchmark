#!/usr/bin/env bash
# Builds the local images (MinIO from source, helper tools) and pulls the others.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
docker build -t mgl870/minio:RELEASE.2025-10-15T17-29-55Z "$BENCH_DIR/images/minio"
cp "$BENCH_DIR/scripts/s3load.py" "$BENCH_DIR/scripts/sample.py" "$BENCH_DIR/scripts/uniqueness.py" "$BENCH_DIR/images/tools/"
docker build -t "$TOOLS_IMAGE" "$BENCH_DIR/images/tools"
docker pull -q dxflrs/garage:v2.4.1
docker pull -q chrislusf/seaweedfs:4.48
docker pull -q "$WARP_IMAGE"
