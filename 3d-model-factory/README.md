# 3D Model Factory

Harness, Kubernetes, Blender Headless, PVC 기반 3D 모델 자동 생성 프로젝트.

## 기본 정보

| 항목 | 값 |
|---|---|
| Root | /ai/tashkent/3d-model-factory |
| Registry | registry.local.cloud:5000 |
| Image | registry.local.cloud:5000/model-factory/blender-worker:latest |
| Namespace | model-factory |
| PVC | model-factory-pvc |
| StorageClass | nfs-nas-sc-main |

## Output

PVC 내부 경로:

```
/data/<RUN_ID>/
├── model.stl
├── model.blend
├── validation.txt
└── README.md
```
