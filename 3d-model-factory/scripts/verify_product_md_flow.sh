#!/usr/bin/env bash
set -euo pipefail

source /ai/tashkent/3d-model-factory/.factory.env

echo "[INFO] Latest products"
kubectl exec -n "${NAMESPACE}" postgresql-0 -- \
  psql -U model_factory -d model_factory -c "
select id, name, preset_id, category, shape, mount_type, status, created_at
from product_requests
order by created_at desc
limit 5;
"

echo ""
echo "[INFO] Worker image run_factory marker"
docker run --rm "${IMAGE}" sh -lc 'grep -n "run_factory-v21-product-md-flow" /workspace/scripts/run_factory.py || true'

echo ""
echo "[INFO] Worker image shape profiles"
docker run --rm "${IMAGE}" sh -lc 'grep -n "bambu_a1_nozzle_holder\|m3_wall_hook\|cable_clip_small\|battery_case_2cell" /workspace/scripts/generate_blender_script.py | head -20 || true'
