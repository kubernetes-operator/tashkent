#!/usr/bin/env bash
set -euo pipefail
cd /ai/tashkent/3d-model-factory
make build
make push
make portal-build
make portal-push
make portal-apply
kubectl rollout status deployment/model-portal -n model-factory --timeout=300s
make portal-url
echo "[DONE] Portal installed. Open: http://<NODE_IP>:30083"
