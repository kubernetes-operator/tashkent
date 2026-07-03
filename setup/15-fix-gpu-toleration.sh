#!/usr/bin/env bash
set -euo pipefail

ROOT="/ai/tashkent/3d-model-factory"
MAIN="${ROOT}/portal/app/main.py"

if [ ! -f "${MAIN}" ]; then
  echo "[ERROR] main.py not found: ${MAIN}"
  exit 1
fi

cp "${MAIN}" "${MAIN}.bak.toleration.$(date +%Y%m%d%H%M%S)"

python3 - <<'PY'
from pathlib import Path

main = Path("/ai/tashkent/3d-model-factory/portal/app/main.py")
text = main.read_text(encoding="utf-8")

if "rtx4060" in text and "rtx2070" in text and "client.V1Toleration" in text:
    print("[INFO] GPU tolerations already exist")
    raise SystemExit(0)

# 1. tolerations 변수 삽입
marker = '''    volume = client.V1Volume(
        name="model-storage",
        persistent_volume_claim=client.V1PersistentVolumeClaimVolumeSource(claim_name=PVC_NAME),
    )

'''

insert = '''    volume = client.V1Volume(
        name="model-storage",
        persistent_volume_claim=client.V1PersistentVolumeClaimVolumeSource(claim_name=PVC_NAME),
    )

    tolerations = []
    if getattr(current_product_for_job, "use_gpu", False):
        tolerations = [
            client.V1Toleration(
                key="nvidia.com/gpu",
                operator="Equal",
                value="rtx4060",
                effect="NoSchedule",
            ),
            client.V1Toleration(
                key="nvidia.com/gpu",
                operator="Equal",
                value="rtx2070",
                effect="NoSchedule",
            ),
        ]

'''

if marker not in text:
    raise SystemExit("[ERROR] volume marker not found. Please inspect create_blender_job function.")

text = text.replace(marker, insert)

# 2. PodSpec에 tolerations 추가
old = '''    pod_spec = client.V1PodSpec(
        restart_policy="Never",
        containers=[container],
        volumes=[volume],
    )
'''

new = '''    pod_spec = client.V1PodSpec(
        restart_policy="Never",
        containers=[container],
        volumes=[volume],
        tolerations=tolerations,
    )
'''

if old not in text:
    raise SystemExit("[ERROR] pod_spec marker not found. Please inspect create_blender_job function.")

text = text.replace(old, new)

main.write_text(text, encoding="utf-8")
print("[DONE] GPU tolerations added")
PY

python3 -m py_compile "${MAIN}"

echo "[DONE] main.py syntax check passed"
