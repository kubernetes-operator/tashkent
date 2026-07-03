#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/ai/tashkent/3d-model-factory/.factory.env"
if [ ! -f "${ENV_FILE}" ]; then
  echo "[ERROR] ${ENV_FILE} not found. Run 00-init.sh first."
  exit 1
fi
source "${ENV_FILE}"

PORTAL_IMAGE="${REGISTRY}/model-factory/model-portal:latest"
DB_NAME="model_factory"
DB_USER="model_factory"
DB_PASSWORD="model_factory_pw_change_me"

mkdir -p "${ROOT}/portal/app/templates" "${ROOT}/portal/app/static" "${ROOT}/portal/docker" "${ROOT}/portal/k8s"

cat > "${ROOT}/portal/app/requirements.txt" <<'EOF'
fastapi
uvicorn[standard]
jinja2
python-multipart
sqlalchemy
psycopg2-binary
kubernetes
EOF

cat > "${ROOT}/portal/docker/Dockerfile" <<'EOF'
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY portal/app/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY portal/app /app
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

cat > "${ROOT}/portal/app/main.py" <<'EOF'
import os, uuid
from datetime import datetime
from pathlib import Path
from typing import List, Optional
from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, FileResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy import create_engine, Column, String, Text, DateTime, Boolean, Numeric, ForeignKey
from sqlalchemy.orm import declarative_base, sessionmaker, relationship
from kubernetes import client, config

DATABASE_URL = os.environ.get("DATABASE_URL")
NAMESPACE = os.environ.get("NAMESPACE", "model-factory")
WORKER_IMAGE = os.environ.get("WORKER_IMAGE")
OUTPUT_DIR = Path(os.environ.get("OUTPUT_DIR", "/data"))
PVC_NAME = os.environ.get("PVC_NAME", "model-factory-pvc")

Base = declarative_base()
engine = create_engine(DATABASE_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)

class ProductRequest(Base):
    __tablename__ = "product_requests"
    id = Column(String, primary_key=True)
    name = Column(String, nullable=False)
    category = Column(String, nullable=False)
    description = Column(Text)
    width_mm = Column(Numeric)
    depth_mm = Column(Numeric)
    height_mm = Column(Numeric)
    shape = Column(String)
    color = Column(String)
    surface = Column(String)
    material = Column(String)
    mount_type = Column(String)
    support_allowed = Column(Boolean, default=False)
    printer_targets = Column(Text)
    status = Column(String, default="PENDING")
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow)
    jobs = relationship("GenerationJob", back_populates="product")

class GenerationJob(Base):
    __tablename__ = "generation_jobs"
    id = Column(String, primary_key=True)
    product_id = Column(String, ForeignKey("product_requests.id"))
    k8s_job_name = Column(String)
    status = Column(String, default="QUEUED")
    error_message = Column(Text)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow)
    product = relationship("ProductRequest", back_populates="jobs")

app = FastAPI(title="3D Model Factory Portal")
templates = Jinja2Templates(directory="/app/templates")
app.mount("/static", StaticFiles(directory="/app/static"), name="static")

@app.on_event("startup")
def startup():
    Base.metadata.create_all(bind=engine)
    try:
        config.load_incluster_config()
    except Exception:
        try:
            config.load_kube_config()
        except Exception:
            pass

def db_session():
    return SessionLocal()

def product_dir(product_id: str) -> Path:
    return OUTPUT_DIR / "products" / product_id

def write_product_md(product: ProductRequest) -> Path:
    base = product_dir(product.id)
    for d in ["input", "output", "logs"]:
        (base / d).mkdir(parents=True, exist_ok=True)
    lines = [
        "# Product Design Request", "",
        "## Basic", "",
        f"- Product ID: {product.id}",
        f"- Name: {product.name}",
        f"- Category: {product.category}",
        f"- Description: {product.description or ''}", "",
        "## Dimensions", "",
        "| Item | Value |", "|---|---|",
        f"| Width | {product.width_mm or ''}mm |",
        f"| Depth | {product.depth_mm or ''}mm |",
        f"| Height | {product.height_mm or ''}mm |", "",
        "## Design", "",
        "| Item | Value |", "|---|---|",
        f"| Shape | {product.shape or ''} |",
        f"| Surface | {product.surface or ''} |",
        f"| Color | {product.color or ''} |",
        f"| Material | {product.material or ''} |",
        f"| Mount Type | {product.mount_type or ''} |",
        f"| Support Allowed | {product.support_allowed} |", "",
        "## Printer Target", "",
        product.printer_targets or "", "",
        "## Output Requirements", "",
        "- Generate STL", "- Generate BLEND", "- Generate README", "- Validate mesh", ""
    ]
    md_path = base / "input" / "product.md"
    md_path.write_text("\n".join(lines), encoding="utf-8")
    return md_path

def create_blender_job(product_id: str) -> str:
    batch = client.BatchV1Api()
    safe_id = product_id.replace("-", "")[:18]
    job_name = f"model-factory-{safe_id}"
    container = client.V1Container(
        name="blender-worker",
        image=WORKER_IMAGE,
        image_pull_policy="Always",
        env=[
            client.V1EnvVar(name="PRODUCT_ID", value=product_id),
            client.V1EnvVar(name="PRODUCT_MD", value=f"/data/products/{product_id}/input/product.md"),
            client.V1EnvVar(name="OUTPUT_DIR", value=f"/data/products/{product_id}/output"),
        ],
        volume_mounts=[client.V1VolumeMount(name="model-storage", mount_path="/data")],
    )
    volume = client.V1Volume(
        name="model-storage",
        persistent_volume_claim=client.V1PersistentVolumeClaimVolumeSource(claim_name=PVC_NAME),
    )
    pod_spec = client.V1PodSpec(restart_policy="Never", containers=[container], volumes=[volume])
    template = client.V1PodTemplateSpec(
        metadata=client.V1ObjectMeta(labels={"app": "model-factory-worker", "product-id": product_id}),
        spec=pod_spec,
    )
    job_spec = client.V1JobSpec(template=template, backoff_limit=1, ttl_seconds_after_finished=86400)
    job = client.V1Job(api_version="batch/v1", kind="Job", metadata=client.V1ObjectMeta(name=job_name, namespace=NAMESPACE), spec=job_spec)
    try:
        batch.create_namespaced_job(namespace=NAMESPACE, body=job)
    except client.exceptions.ApiException as e:
        if e.status == 409:
            job_name = f"{job_name}-{datetime.utcnow().strftime('%H%M%S')}"
            job.metadata.name = job_name
            batch.create_namespaced_job(namespace=NAMESPACE, body=job)
        else:
            raise
    return job_name

def refresh_job_status(db, product: ProductRequest):
    if not product.jobs:
        return product.status
    latest = sorted(product.jobs, key=lambda j: j.created_at)[-1]
    if not latest.k8s_job_name:
        return product.status
    try:
        job = client.BatchV1Api().read_namespaced_job(name=latest.k8s_job_name, namespace=NAMESPACE)
        if job.status.succeeded:
            product.status = latest.status = "COMPLETED"
        elif job.status.failed:
            product.status = latest.status = "FAILED"
        elif job.status.active:
            product.status = latest.status = "RUNNING"
        product.updated_at = latest.updated_at = datetime.utcnow()
        db.commit()
    except Exception:
        pass
    return product.status

@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    db = db_session()
    products = db.query(ProductRequest).order_by(ProductRequest.created_at.desc()).all()
    for p in products:
        refresh_job_status(db, p)
    db.close()
    return templates.TemplateResponse("index.html", {"request": request, "products": products})

@app.get("/products/new", response_class=HTMLResponse)
def new_product(request: Request):
    return templates.TemplateResponse("new_product.html", {"request": request})

@app.post("/products")
def create_product(
    name: str = Form(...),
    category: str = Form(...),
    description: str = Form(""),
    width_mm: Optional[float] = Form(None),
    depth_mm: Optional[float] = Form(None),
    height_mm: Optional[float] = Form(None),
    shape: str = Form(""),
    color: str = Form(""),
    surface: str = Form(""),
    material: str = Form("PETG"),
    mount_type: str = Form(""),
    support_allowed: Optional[str] = Form(None),
    printer_targets: List[str] = Form([]),
):
    db = db_session()
    product = ProductRequest(
        id=str(uuid.uuid4()), name=name, category=category, description=description,
        width_mm=width_mm, depth_mm=depth_mm, height_mm=height_mm,
        shape=shape, color=color, surface=surface, material=material, mount_type=mount_type,
        support_allowed=(support_allowed == "true"),
        printer_targets="\n".join([f"- {p}" for p in printer_targets]),
        status="MD_CREATED",
    )
    db.add(product)
    db.commit()
    write_product_md(product)
    try:
        job_name = create_blender_job(product.id)
        db.add(GenerationJob(id=str(uuid.uuid4()), product_id=product.id, k8s_job_name=job_name, status="QUEUED"))
        product.status = "QUEUED"
    except Exception as e:
        product.status = "FAILED"
        db.add(GenerationJob(id=str(uuid.uuid4()), product_id=product.id, status="FAILED", error_message=str(e)))
    db.commit()
    pid = product.id
    db.close()
    return RedirectResponse(url=f"/products/{pid}", status_code=303)

@app.get("/products/{product_id}", response_class=HTMLResponse)
def product_detail(request: Request, product_id: str):
    db = db_session()
    product = db.query(ProductRequest).filter(ProductRequest.id == product_id).first()
    if not product:
        db.close()
        raise HTTPException(status_code=404, detail="Product not found")
    refresh_job_status(db, product)
    files = []
    base = product_dir(product_id)
    for sub in ["input", "output", "logs"]:
        d = base / sub
        if d.exists():
            for f in sorted(d.glob("*")):
                if f.is_file():
                    files.append({"name": f.name, "subdir": sub, "size": f.stat().st_size, "download_url": f"/products/{product_id}/download/{sub}/{f.name}"})
    jobs = db.query(GenerationJob).filter(GenerationJob.product_id == product_id).order_by(GenerationJob.created_at.desc()).all()
    db.close()
    return templates.TemplateResponse("product_detail.html", {"request": request, "product": product, "files": files, "jobs": jobs})

@app.get("/products/{product_id}/download/{subdir}/{filename}")
def download_file(product_id: str, subdir: str, filename: str):
    if subdir not in ["input", "output", "logs"]:
        raise HTTPException(status_code=400, detail="Invalid subdir")
    path = product_dir(product_id) / subdir / filename
    if not path.exists() or not path.is_file():
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(path, filename=filename)

@app.post("/products/{product_id}/rerun")
def rerun_product(product_id: str):
    db = db_session()
    product = db.query(ProductRequest).filter(ProductRequest.id == product_id).first()
    if not product:
        db.close()
        raise HTTPException(status_code=404, detail="Product not found")
    write_product_md(product)
    try:
        job_name = create_blender_job(product.id)
        db.add(GenerationJob(id=str(uuid.uuid4()), product_id=product.id, k8s_job_name=job_name, status="QUEUED"))
        product.status = "QUEUED"
    except Exception as e:
        product.status = "FAILED"
        db.add(GenerationJob(id=str(uuid.uuid4()), product_id=product.id, status="FAILED", error_message=str(e)))
    db.commit()
    db.close()
    return RedirectResponse(url=f"/products/{product_id}", status_code=303)

@app.get("/healthz")
def healthz():
    return {"status": "ok"}
EOF

cat > "${ROOT}/portal/app/templates/base.html" <<'EOF'
<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8">
  <title>3D Model Factory</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
<header>
  <h1>3D Model Factory</h1>
  <nav>
    <a href="/">제품 목록</a>
    <a href="/products/new">새 제품 요청</a>
  </nav>
</header>
<main>{% block content %}{% endblock %}</main>
</body>
</html>
EOF

cat > "${ROOT}/portal/app/templates/index.html" <<'EOF'
{% extends "base.html" %}
{% block content %}
<section class="card">
  <h2>제품 요청 목록</h2>
  <table>
    <thead><tr><th>제품명</th><th>카테고리</th><th>상태</th><th>생성일</th></tr></thead>
    <tbody>
    {% for p in products %}
      <tr>
        <td><a href="/products/{{ p.id }}">{{ p.name }}</a></td>
        <td>{{ p.category }}</td>
        <td><span class="status">{{ p.status }}</span></td>
        <td>{{ p.created_at }}</td>
      </tr>
    {% endfor %}
    </tbody>
  </table>
</section>
{% endblock %}
EOF

cat > "${ROOT}/portal/app/templates/new_product.html" <<'EOF'
{% extends "base.html" %}
{% block content %}
<section class="card">
  <h2>새 제품 요청</h2>
  <form method="post" action="/products">
    <label>제품명</label><input name="name" required placeholder="Bambu A1 Tool Holder">
    <label>카테고리</label>
    <select name="category">
      <option value="bambu_accessory">Bambu 액세서리</option>
      <option value="homelab_accessory">홈랩 액세서리</option>
      <option value="cable_management">케이블 정리</option>
      <option value="battery_case">배터리 케이스</option>
      <option value="desk_organizer">책상 정리</option>
    </select>
    <label>설명</label><textarea name="description" rows="4"></textarea>
    <div class="grid3">
      <div><label>가로 mm</label><input name="width_mm" type="number" step="0.1"></div>
      <div><label>세로/깊이 mm</label><input name="depth_mm" type="number" step="0.1"></div>
      <div><label>높이 mm</label><input name="height_mm" type="number" step="0.1"></div>
    </div>
    <label>형태</label><input name="shape" placeholder="둥근 사각형, 클립형, 박스형, 경첩형">
    <label>색상</label><input name="color" placeholder="검정, 흰색, 투명">
    <label>표면</label><input name="surface" placeholder="무광, 격자 패턴, 로고 음각">
    <label>재료</label>
    <select name="material">
      <option value="PLA">PLA</option><option value="PETG" selected>PETG</option><option value="ASA">ASA</option><option value="ABS">ABS</option><option value="TPU">TPU</option>
    </select>
    <label>고정 방식</label><input name="mount_type" placeholder="걸이형, M3 볼트, 자석, 양면테이프">
    <label class="checkbox"><input type="checkbox" name="support_allowed" value="true"> 서포트 허용</label>
    <label>대상 프린터</label>
    <div class="checks">
      <label><input type="checkbox" name="printer_targets" value="Bambu Lab A1" checked> Bambu Lab A1</label>
      <label><input type="checkbox" name="printer_targets" value="Bambu Lab P1S" checked> Bambu Lab P1S</label>
      <label><input type="checkbox" name="printer_targets" value="Bambu Lab P2S" checked> Bambu Lab P2S</label>
    </div>
    <button type="submit">제품 요청 생성</button>
  </form>
</section>
{% endblock %}
EOF

cat > "${ROOT}/portal/app/templates/product_detail.html" <<'EOF'
{% extends "base.html" %}
{% block content %}
<section class="card">
  <h2>{{ product.name }}</h2>
  <p><strong>상태:</strong> <span class="status">{{ product.status }}</span></p>
  <p><strong>카테고리:</strong> {{ product.category }}</p>
  <p><strong>설명:</strong> {{ product.description }}</p>
  <h3>입력 조건</h3>
  <table>
    <tr><th>크기</th><td>{{ product.width_mm }} x {{ product.depth_mm }} x {{ product.height_mm }} mm</td></tr>
    <tr><th>형태</th><td>{{ product.shape }}</td></tr>
    <tr><th>색상</th><td>{{ product.color }}</td></tr>
    <tr><th>표면</th><td>{{ product.surface }}</td></tr>
    <tr><th>재료</th><td>{{ product.material }}</td></tr>
    <tr><th>고정 방식</th><td>{{ product.mount_type }}</td></tr>
    <tr><th>서포트 허용</th><td>{{ product.support_allowed }}</td></tr>
    <tr><th>프린터</th><td><pre>{{ product.printer_targets }}</pre></td></tr>
  </table>
  <form method="post" action="/products/{{ product.id }}/rerun"><button type="submit">다시 생성</button></form>
</section>
<section class="card">
  <h3>생성 Job</h3>
  <table><thead><tr><th>Job Name</th><th>Status</th><th>Error</th><th>Created</th></tr></thead><tbody>
  {% for j in jobs %}<tr><td>{{ j.k8s_job_name }}</td><td>{{ j.status }}</td><td>{{ j.error_message }}</td><td>{{ j.created_at }}</td></tr>{% endfor %}
  </tbody></table>
</section>
<section class="card">
  <h3>파일 다운로드</h3>
  {% if files %}
  <table><thead><tr><th>구분</th><th>파일</th><th>크기</th><th>다운로드</th></tr></thead><tbody>
  {% for f in files %}<tr><td>{{ f.subdir }}</td><td>{{ f.name }}</td><td>{{ f.size }}</td><td><a href="{{ f.download_url }}">Download</a></td></tr>{% endfor %}
  </tbody></table>
  {% else %}<p>아직 생성된 파일이 없습니다. 상태가 COMPLETED가 되면 새로고침하세요.</p>{% endif %}
</section>
{% endblock %}
EOF

cat > "${ROOT}/portal/app/static/style.css" <<'EOF'
body{font-family:Arial,sans-serif;margin:0;background:#f5f5f5;color:#222}header{background:#222;color:#fff;padding:16px 32px}header h1{margin:0 0 8px 0}nav a{color:#fff;margin-right:16px}main{max-width:1100px;margin:24px auto;padding:0 16px}.card{background:#fff;border:1px solid #ddd;padding:24px;margin-bottom:24px}label{display:block;margin-top:14px;font-weight:bold}input,select,textarea{width:100%;box-sizing:border-box;padding:10px;margin-top:6px;border:1px solid #aaa}button{margin-top:20px;padding:10px 18px;cursor:pointer}table{width:100%;border-collapse:collapse;margin-top:12px}th,td{border:1px solid #ddd;padding:8px;vertical-align:top}th{background:#f0f0f0}.grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}.checks label,.checkbox{font-weight:normal}.status{font-weight:bold}pre{margin:0}
EOF

cat > "${ROOT}/portal/k8s/postgresql.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  POSTGRES_DB: ${DB_NAME}
  POSTGRES_USER: ${DB_USER}
  POSTGRES_PASSWORD: ${DB_PASSWORD}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgresql-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql
  namespace: ${NAMESPACE}
spec:
  serviceName: postgresql
  replicas: 1
  selector:
    matchLabels:
      app: postgresql
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      containers:
        - name: postgresql
          image: postgres:16
          ports:
            - containerPort: 5432
          envFrom:
            - secretRef:
                name: postgresql-secret
          volumeMounts:
            - name: postgresql-data
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: postgresql-data
          persistentVolumeClaim:
            claimName: postgresql-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  namespace: ${NAMESPACE}
spec:
  selector:
    app: postgresql
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
EOF

cat > "${ROOT}/portal/k8s/portal-rbac.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: model-portal
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: model-portal-runner
  namespace: ${NAMESPACE}
rules:
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: model-portal-runner-binding
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: model-portal
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: model-portal-runner
  apiGroup: rbac.authorization.k8s.io
EOF

cat > "${ROOT}/portal/k8s/portal.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: model-portal
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: model-portal
  template:
    metadata:
      labels:
        app: model-portal
    spec:
      serviceAccountName: model-portal
      containers:
        - name: model-portal
          image: ${PORTAL_IMAGE}
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
          env:
            - name: DATABASE_URL
              value: postgresql://${DB_USER}:${DB_PASSWORD}@postgresql.${NAMESPACE}.svc.cluster.local:5432/${DB_NAME}
            - name: NAMESPACE
              value: ${NAMESPACE}
            - name: WORKER_IMAGE
              value: ${IMAGE}
            - name: PVC_NAME
              value: ${PVC_NAME}
            - name: OUTPUT_DIR
              value: /data
          volumeMounts:
            - name: model-storage
              mountPath: /data
      volumes:
        - name: model-storage
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
---
apiVersion: v1
kind: Service
metadata:
  name: model-portal
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    app: model-portal
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      nodePort: 30083
EOF

cat >> "${ROOT}/Makefile" <<EOF

.PHONY: portal-build portal-push portal-apply portal-restart portal-url

portal-build:
>docker build -t ${PORTAL_IMAGE} -f portal/docker/Dockerfile .

portal-push:
>docker push ${PORTAL_IMAGE}

portal-apply:
>kubectl apply -f k8s/namespace.yaml
>kubectl apply -f k8s/pvc.yaml
>kubectl apply -f portal/k8s/postgresql.yaml
>kubectl apply -f portal/k8s/portal-rbac.yaml
>kubectl apply -f portal/k8s/portal.yaml

portal-restart:
>kubectl rollout restart deployment/model-portal -n ${NAMESPACE}

portal-url:
>echo "NodePort URL: http://<NODE_IP>:30083"
>kubectl get svc model-portal -n ${NAMESPACE}
EOF

cat > "${ROOT}/portal-local-test.sh" <<'EOF'
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
EOF
chmod +x "${ROOT}/portal-local-test.sh"

echo "[DONE] 05-portal completed"
echo "Next: cd ${ROOT} && ./portal-local-test.sh"
