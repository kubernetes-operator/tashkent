#!/usr/bin/env bash
set -euo pipefail

source /ai/tashkent/3d-model-factory/.factory.env

cat > "${ROOT}/k8s/namespace.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
YAML

cat > "${ROOT}/k8s/pvc.yaml" <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: 100Gi
YAML

cat > "${ROOT}/k8s/secret-openai.example.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
  namespace: model-factory
type: Opaque
stringData:
  OPENAI_API_KEY: "CHANGE_ME"
YAML

cat > "${ROOT}/k8s/job-template.yaml" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: model-factory-job
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: blender-worker
          image: ${IMAGE}
          imagePullPolicy: Always
          env:
            - name: OPENAI_API_KEY
              valueFrom:
                secretKeyRef:
                  name: openai-secret
                  key: OPENAI_API_KEY
                  optional: true
            - name: OUTPUT_DIR
              value: "/data"
          volumeMounts:
            - name: model-storage
              mountPath: /data
      volumes:
        - name: model-storage
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
YAML

cat > "${ROOT}/k8s/harness-delegate-rbac.yaml" <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: model-factory-runner
  namespace: model-factory
rules:
  - apiGroups: [""]
    resources:
      - pods
      - pods/log
      - persistentvolumeclaims
      - secrets
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
  - apiGroups: ["batch"]
    resources:
      - jobs
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: model-factory-runner-binding
  namespace: model-factory
subjects:
  - kind: ServiceAccount
    name: default
    namespace: harness-delegate
roleRef:
  kind: Role
  name: model-factory-runner
  apiGroup: rbac.authorization.k8s.io
YAML

echo "[DONE] 01-k8s completed"
