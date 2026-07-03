#!/usr/bin/env bash
set -euo pipefail

cd /ai/tashkent/3d-model-factory

echo "[INFO] Check environment"
make check

echo "[INFO] Apply Kubernetes resources"
make apply

echo "[INFO] Build image"
make build

echo "[INFO] Push image"
make push

if [ -n "${OPENAI_API_KEY:-}" ]; then
  echo "[INFO] Apply OpenAI secret"
  make secret
else
  echo "[WARN] OPENAI_API_KEY is empty. Secret creation skipped."
  echo "[WARN] Current fixed test model does not require OpenAI."
fi

echo "[INFO] Run test Job"
make run
