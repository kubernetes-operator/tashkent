#!/usr/bin/env bash
set -euo pipefail
source /ai/tashkent/3d-model-factory/.factory.env

echo "[INFO] Portal DB columns"
kubectl exec -n "${NAMESPACE}" postgresql-0 -- psql -U model_factory -d model_factory -c "
select column_name, data_type
from information_schema.columns
where table_name='product_requests'
and column_name in ('cable_channels','cable_diameter_mm','magnet_diameter_mm','magnet_thickness_mm','hinge_count','clearance_mm')
order by column_name;
"

echo ""
echo "[INFO] Local generator parser marker"
grep -n "Cable Channels\\|cable_diameter\\|magnet_diameter\\|hinge_count" "${ROOT}/scripts/generate_blender_script.py" | head -20 || true

echo ""
echo "[INFO] Worker image parser marker"
docker run --rm "${IMAGE}" sh -lc 'grep -n "Cable Channels\\|cable_diameter\\|magnet_diameter\\|hinge_count" /workspace/scripts/generate_blender_script.py | head -20 || true'
