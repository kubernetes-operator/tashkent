# 14 GPU Preview Worker Patch

## 목적

3D Model Factory에 선택형 GPU Preview 렌더링 기능을 추가합니다.

## 적용

```bash
mkdir -p /ai/tashkent/setup
cp 14-gpu-preview-worker.sh /ai/tashkent/setup/14-gpu-preview-worker.sh
chmod +x /ai/tashkent/setup/14-gpu-preview-worker.sh

/ai/tashkent/setup/14-gpu-preview-worker.sh

cd /ai/tashkent/3d-model-factory
make portal-build
make portal-push
make portal-restart

make build
make push
```

## GPU 테스트

```bash
kubectl apply -f k8s/gpu-test.yaml
kubectl logs -n model-factory gpu-test
kubectl delete pod -n model-factory gpu-test
```

## 동작 방식

- 웹 입력창에서 GPU Preview 렌더링 사용을 선택하면 Worker Job이 `nvidia.com/gpu: 1`을 요청합니다.
- Blender는 CUDA/OPTIX를 시도합니다.
- GPU 설정 실패 시 CPU/Eevee 렌더링으로 fallback합니다.
- 결과 파일에 `preview.png`가 추가됩니다.
