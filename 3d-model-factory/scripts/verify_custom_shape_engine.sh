#!/usr/bin/env bash
set -euo pipefail
source /ai/tashkent/3d-model-factory/.factory.env
echo "[INFO] Local generator marker"
grep -n "shape-engine-v22-custom-intent" "${ROOT}/scripts/generate_blender_script.py" || true
echo ""
echo "[INFO] Docker image generator marker"
docker run --rm "${IMAGE}" sh -lc 'grep -n "shape-engine-v22-custom-intent" /workspace/scripts/generate_blender_script.py || true'
