#!/usr/bin/env bash
set -euo pipefail

# 03-harness.sh
# Purpose:
#   Create Harness pipeline YAML, cron note, Makefile, and local bootstrap script
#   for /ai/tashkent/3d-model-factory.
#
# Required previous steps:
#   /ai/tashkent/setup/00-init.sh
#   /ai/tashkent/setup/01-k8s.sh
#   /ai/tashkent/setup/02-worker.sh

ENV_FILE="/ai/tashkent/3d-model-factory/.factory.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "[ERROR] ${ENV_FILE} not found."
  echo "[ERROR] Run /ai/tashkent/setup/00-init.sh first."
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

if [ -z "${ROOT:-}" ] || [ -z "${REGISTRY:-}" ] || [ -z "${IMAGE:-}" ] || [ -z "${NAMESPACE:-}" ]; then
  echo "[ERROR] Required variables are missing from ${ENV_FILE}."
  echo "ROOT=${ROOT:-}"
  echo "REGISTRY=${REGISTRY:-}"
  echo "IMAGE=${IMAGE:-}"
  echo "NAMESPACE=${NAMESPACE:-}"
  exit 1
fi

mkdir -p "${ROOT}/.harness"

cat > "${ROOT}/.harness/pipeline-run-3d-factory.yaml" <<'YAML'
pipeline:
  name: 3D Model Factory Run
  identifier: model_factory_run
  projectIdentifier: YOUR_PROJECT
  orgIdentifier: YOUR_ORG
  tags: {}
  stages:
    - stage:
        name: Run 3D Model Factory
        identifier: run_3d_model_factory
        type: CI
        spec:
          cloneCodebase: true
          execution:
            steps:
              - step:
                  type: Run
                  name: Apply Base Resources
                  identifier: apply_base_resources
                  spec:
                    shell: Bash
                    command: |
                      kubectl apply -f k8s/namespace.yaml
                      kubectl apply -f k8s/pvc.yaml

              - step:
                  type: Run
                  name: Apply OpenAI Secret
                  identifier: apply_openai_secret
                  spec:
                    shell: Bash
                    command: |
                      kubectl -n model-factory create secret generic openai-secret \
                        --from-literal=OPENAI_API_KEY='<+secrets.getValue("openai_api_key")>' \
                        --dry-run=client -o yaml | kubectl apply -f -

              - step:
                  type: Run
                  name: Run Blender Job
                  identifier: run_blender_job
                  spec:
                    shell: Bash
                    command: |
                      RUN_ID=$(date +%Y%m%d%H%M%S)
                      JOB_NAME="model-factory-job-${RUN_ID}"

                      sed "s/name: model-factory-job/name: ${JOB_NAME}/" k8s/job-template.yaml | kubectl apply -f -

                      kubectl wait \
                        --for=condition=complete \
                        job/${JOB_NAME} \
                        -n model-factory \
                        --timeout=1800s

                      kubectl logs -n model-factory job/${JOB_NAME}
YAML

cat > "${ROOT}/.harness/cron-trigger-note.md" <<'MD'
# Harness Cron Trigger

Harness UI에서 Pipeline Trigger를 추가한다.

## 추천 Cron

| 목적 | Cron |
|---|---|
| 매일 새벽 2시 | `0 2 * * *` |
| 6시간마다 | `0 */6 * * *` |
| 매시간 | `0 * * * *` |

초기 권장값:

~~text
0 2 * * *
~~

## 주의

- Harness Pipeline의 `projectIdentifier`, `orgIdentifier`는 실제 Harness 값으로 수정해야 한다.
- Harness Secret에는 `openai_api_key` 이름으로 OpenAI API Key를 등록한다.
- 현재 1차 테스트 모델은 OpenAI API 없이도 실행 가능하다.
MD

cat > "${ROOT}/Makefile" <<'MAKE'
.RECIPEPREFIX := >

REGISTRY=__REGISTRY__
IMAGE=__IMAGE__
NAMESPACE=__NAMESPACE__

.PHONY: check build push apply secret run logs clean git-init

check:
>echo "REGISTRY=$(REGISTRY)"
>echo "IMAGE=$(IMAGE)"
>echo "NAMESPACE=$(NAMESPACE)"
>kubectl version --client
>docker version

build:
>docker build -t $(IMAGE) -f docker/blender-worker/Dockerfile .

push:
>docker push $(IMAGE)

apply:
>kubectl apply -f k8s/namespace.yaml
>kubectl apply -f k8s/pvc.yaml

secret:
>@if [ -z "$$OPENAI_API_KEY" ]; then echo "OPENAI_API_KEY is empty"; exit 1; fi
>kubectl -n $(NAMESPACE) create secret generic openai-secret --from-literal=OPENAI_API_KEY="$$OPENAI_API_KEY" --dry-run=client -o yaml | kubectl apply -f -

run:
>RUN_ID=$$(date +%Y%m%d%H%M%S); \
>JOB_NAME="model-factory-job-$${RUN_ID}"; \
>sed "s/name: model-factory-job/name: $${JOB_NAME}/" k8s/job-template.yaml | kubectl apply -f -; \
>kubectl wait --for=condition=complete job/$${JOB_NAME} -n $(NAMESPACE) --timeout=1800s; \
>kubectl logs -n $(NAMESPACE) job/$${JOB_NAME}

logs:
>kubectl logs -n $(NAMESPACE) job/$$(kubectl get jobs -n $(NAMESPACE) --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')

clean:
>kubectl delete jobs -n $(NAMESPACE) --all

git-init:
>git init
>git add .
>git commit -m "initial 3d model factory" || true
MAKE

sed -i "s|__REGISTRY__|${REGISTRY}|g" "${ROOT}/Makefile"
sed -i "s|__IMAGE__|${IMAGE}|g" "${ROOT}/Makefile"
sed -i "s|__NAMESPACE__|${NAMESPACE}|g" "${ROOT}/Makefile"

cat > "${ROOT}/bootstrap-local-test.sh" <<'BASH'
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
BASH

chmod +x "${ROOT}/bootstrap-local-test.sh"

echo "[DONE] 03-harness completed"
echo "ROOT=${ROOT}"
echo "REGISTRY=${REGISTRY}"
echo "IMAGE=${IMAGE}"
echo "NAMESPACE=${NAMESPACE}"
echo ""
echo "Next commands:"
echo "  cd ${ROOT}"
echo "  make check"
echo "  ./bootstrap-local-test.sh"

