#!/usr/bin/env bash
set -euo pipefail

ROOT="/ai/tashkent/3d-model-factory"
REGISTRY="registry.local.cloud:5000"
IMAGE="${REGISTRY}/model-factory/blender-worker:latest"
NAMESPACE="model-factory"
STORAGE_CLASS="nfs-nas-sc-main"
PVC_NAME="model-factory-pvc"

mkdir -p "${ROOT}"/{.harness,k8s,docker/blender-worker,scripts,prompts,blender,docs,output}

cat > "${ROOT}/.factory.env" <<ENV
ROOT="${ROOT}"
REGISTRY="${REGISTRY}"
IMAGE="${IMAGE}"
NAMESPACE="${NAMESPACE}"
STORAGE_CLASS="${STORAGE_CLASS}"
PVC_NAME="${PVC_NAME}"
ENV

cat > "${ROOT}/README.md" <<README
# 3D Model Factory

Harness, Kubernetes, Blender Headless, PVC 기반 3D 모델 자동 생성 프로젝트.

## 기본 정보

| 항목 | 값 |
|---|---|
| Root | ${ROOT} |
| Registry | ${REGISTRY} |
| Image | ${IMAGE} |
| Namespace | ${NAMESPACE} |
| PVC | ${PVC_NAME} |
| StorageClass | ${STORAGE_CLASS} |

## Output

PVC 내부 경로:

\`\`\`
/data/<RUN_ID>/
├── model.stl
├── model.blend
├── validation.txt
└── README.md
\`\`\`
README

cat > "${ROOT}/.gitignore" <<'GITIGNORE'
output/*
!output/.gitkeep
.env
*.log
__pycache__/
GITIGNORE

touch "${ROOT}/output/.gitkeep"

cat > "${ROOT}/prompts/product-seed.yaml" <<'YAML'
product:
  category: bambu_accessory
  name: bambu_cable_clip_test
  description: Simple cable clip test model for Bambu Lab A1, P1S, P2S.
  target_printer:
    - Bambu Lab A1
    - Bambu Lab P1S
    - Bambu Lab P2S
  material:
    - PLA
    - PETG
YAML

cat > "${ROOT}/prompts/rules.yaml" <<'YAML'
rules:
  unit: mm
  minimum_wall_thickness: 2.0
  minimum_gap: 0.4
  preferred_nozzle: 0.4
  preferred_layer_height: 0.2
  support_required: false
  target_printer:
    - Bambu Lab A1
    - Bambu Lab P1S
    - Bambu Lab P2S
YAML

echo "[DONE] 00-init completed"
echo "ROOT=${ROOT}"
