.RECIPEPREFIX := >

REGISTRY=registry.local.cloud:5000
IMAGE=registry.local.cloud:5000/model-factory/blender-worker:latest
NAMESPACE=model-factory

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

.PHONY: portal-build portal-push portal-apply portal-restart portal-url

portal-build:
>docker build -t registry.local.cloud:5000/model-factory/model-portal:latest -f portal/docker/Dockerfile .

portal-push:
>docker push registry.local.cloud:5000/model-factory/model-portal:latest

portal-apply:
>kubectl apply -f k8s/namespace.yaml
>kubectl apply -f k8s/pvc.yaml
>kubectl apply -f portal/k8s/postgresql.yaml
>kubectl apply -f portal/k8s/portal-rbac.yaml
>kubectl apply -f portal/k8s/portal.yaml

portal-restart:
>kubectl rollout restart deployment/model-portal -n model-factory

portal-url:
>echo "NodePort URL: http://<NODE_IP>:30083"
>kubectl get svc model-portal -n model-factory
