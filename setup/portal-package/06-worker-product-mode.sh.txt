#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/ai/tashkent/3d-model-factory/.factory.env"
if [ ! -f "${ENV_FILE}" ]; then echo "[ERROR] ${ENV_FILE} not found."; exit 1; fi
source "${ENV_FILE}"

cat > "${ROOT}/scripts/run_factory.py" <<'PY'
import os
import subprocess
from datetime import datetime
from pathlib import Path

product_id = os.environ.get("PRODUCT_ID", "").strip()
output_env = os.environ.get("OUTPUT_DIR", "/data")

if product_id:
    run_id = product_id
    run_dir = Path(output_env)
else:
    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = Path(output_env) / run_id

run_dir.mkdir(parents=True, exist_ok=True)

print(f"[INFO] PRODUCT_ID={product_id or 'N/A'}")
print(f"[INFO] RUN_ID={run_id}")
print(f"[INFO] OUTPUT_DIR={run_dir}")

subprocess.check_call(["python3", "/workspace/scripts/generate_blender_script.py", str(run_dir)])
subprocess.check_call(["blender", "--background", "--python", "/workspace/blender/generated_model.py", "--", str(run_dir)])
subprocess.check_call(["python3", "/workspace/scripts/validate_stl.py", str(run_dir / "model.stl")])
subprocess.check_call(["python3", "/workspace/scripts/create_report.py", str(run_dir)])

print("[INFO] Factory job completed")
PY

python3 -m py_compile "${ROOT}/scripts/run_factory.py"

echo "[DONE] Worker patched for product mode"
echo "Next: cd ${ROOT} && make build && make push"
