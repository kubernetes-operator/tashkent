#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/ai/tashkent/3d-model-factory/.factory.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "[ERROR] ${ENV_FILE} not found"
  exit 1
fi

source "${ENV_FILE}"

mkdir -p "${ROOT}/portal/app/templates"
mkdir -p "${ROOT}/portal/app/static"
mkdir -p "${ROOT}/portal/docker"

cat > "${ROOT}/portal/app/requirements.txt" <<'REQ'
fastapi
uvicorn[standard]
jinja2
python-multipart
sqlalchemy
psycopg2-binary
kubernetes
REQ

cat > "${ROOT}/portal/docker/Dockerfile" <<'DOCKERFILE'
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY portal/app/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY portal/app /app

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
DOCKERFILE

cat > "${ROOT}/portal/app/main.py" <<'PY'
import os
import uuid
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, Request, Form, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse, FileResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from sqlalchemy import create_engine, Column, String, Text, DateTime, Boolean, Numeric, ForeignKey
from sqlalchemy.orm import declarative_base, sessionmaker, relationship

from kubernetes import client, config


APP_DIR = Path(__file__).resolve().parent
TEMPLATE_DIR = APP_DIR / "templates"
STATIC_DIR = APP_DIR / "static"

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://model_factory:model_factory_pw_change_me@postgresql.model-factory.svc.cluster.local:5432/model_factory"
)

NAMESPACE = os.environ.get("NAMESPACE", "model-factory")
WORKER_IMAGE = os.environ.get("WORKER_IMAGE", "registry.local.cloud:5000/model-factory/blender-worker:latest")
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


class ProductFile(Base):
    __tablename__ = "product_files"

    id = Column(String, primary_key=True)
    product_id = Column(String, ForeignKey("product_requests.id"))
    file_type = Column(String, nullable=False)
    file_name = Column(String, nullable=False)
    file_path = Column(Text, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)


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

templates = Jinja2Templates(directory=str(TEMPLATE_DIR))
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.on_event("startup")
def startup():
    Base.metadata.create_all(bind=engine)

    try:
        config.load_incluster_config()
        print("[INFO] Kubernetes incluster config loaded")
    except Exception as e:
        print("[WARN] Kubernetes config load failed:", repr(e))


def get_db():
    return SessionLocal()


def product_base_dir(product_id: str) -> Path:
    return OUTPUT_DIR / "products" / product_id


def write_product_md(product: ProductRequest) -> Path:
    base = product_base_dir(product.id)
    input_dir = base / "input"
    output_dir = base / "output"
    logs_dir = base / "logs"

    input_dir.mkdir(parents=True, exist_ok=True)
    output_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)

    content = [
        "# Product Design Request",
        "",
        "## Basic",
        "",
        f"- Product ID: {product.id}",
        f"- Name: {product.name}",
        f"- Category: {product.category}",
        f"- Description: {product.description or ''}",
        "",
        "## Dimensions",
        "",
        f"- Width: {product.width_mm or ''}mm",
        f"- Depth: {product.depth_mm or ''}mm",
        f"- Height: {product.height_mm or ''}mm",
        "",
        "## Design",
        "",
        f"- Shape: {product.shape or ''}",
        f"- Surface: {product.surface or ''}",
        f"- Color: {product.color or ''}",
        f"- Material: {product.material or ''}",
        f"- Mount Type: {product.mount_type or ''}",
        f"- Support Allowed: {product.support_allowed}",
        "",
        "## Printer Target",
        "",
        product.printer_targets or "",
        "",
        "## Output Requirements",
        "",
        "- Generate STL",
        "- Generate BLEND",
        "- Generate README",
        "- Validate mesh",
        ""
    ]

    path = input_dir / "product.md"
    path.write_text("\n".join(content), encoding="utf-8")
    return path


def create_blender_job(product_id: str) -> str:
    batch = client.BatchV1Api()

    safe_id = product_id.replace("-", "")[:16]
    suffix = datetime.utcnow().strftime("%H%M%S")
    job_name = f"model-factory-{safe_id}-{suffix}"

    container = client.V1Container(
        name="blender-worker",
        image=WORKER_IMAGE,
        image_pull_policy="Always",
        env=[
            client.V1EnvVar(name="PRODUCT_ID", value=product_id),
            client.V1EnvVar(name="PRODUCT_MD", value=f"/data/products/{product_id}/input/product.md"),
            client.V1EnvVar(name="OUTPUT_DIR", value=f"/data/products/{product_id}/output"),
        ],
        volume_mounts=[
            client.V1VolumeMount(name="model-storage", mount_path="/data")
        ],
    )

    volume = client.V1Volume(
        name="model-storage",
        persistent_volume_claim=client.V1PersistentVolumeClaimVolumeSource(claim_name=PVC_NAME),
    )

    pod_spec = client.V1PodSpec(
        restart_policy="Never",
        containers=[container],
        volumes=[volume],
    )

    template = client.V1PodTemplateSpec(
        metadata=client.V1ObjectMeta(labels={"app": "model-factory-worker", "product-id": product_id}),
        spec=pod_spec,
    )

    job_spec = client.V1JobSpec(
        template=template,
        backoff_limit=1,
        ttl_seconds_after_finished=86400,
    )

    job = client.V1Job(
        api_version="batch/v1",
        kind="Job",
        metadata=client.V1ObjectMeta(name=job_name, namespace=NAMESPACE),
        spec=job_spec,
    )

    batch.create_namespaced_job(namespace=NAMESPACE, body=job)
    return job_name


def refresh_product_status(db, product: ProductRequest):
    if not product.jobs:
        return

    latest = sorted(product.jobs, key=lambda x: x.created_at)[-1]

    if not latest.k8s_job_name:
        return

    try:
        batch = client.BatchV1Api()
        job = batch.read_namespaced_job(name=latest.k8s_job_name, namespace=NAMESPACE)

        if job.status.succeeded:
            product.status = "COMPLETED"
            latest.status = "COMPLETED"
        elif job.status.failed:
            product.status = "FAILED"
            latest.status = "FAILED"
        elif job.status.active:
            product.status = "RUNNING"
            latest.status = "RUNNING"

        product.updated_at = datetime.utcnow()
        latest.updated_at = datetime.utcnow()
        db.commit()
    except Exception as e:
        print("[WARN] failed to refresh job status:", repr(e))


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/debug", response_class=PlainTextResponse)
def debug():
    lines = [
        f"APP_DIR={APP_DIR}",
        f"TEMPLATE_DIR={TEMPLATE_DIR}",
        f"TEMPLATE_EXISTS={TEMPLATE_DIR.exists()}",
        f"STATIC_DIR={STATIC_DIR}",
        f"STATIC_EXISTS={STATIC_DIR.exists()}",
        f"DATABASE_URL={DATABASE_URL}",
        f"NAMESPACE={NAMESPACE}",
        f"WORKER_IMAGE={WORKER_IMAGE}",
        f"OUTPUT_DIR={OUTPUT_DIR}",
        f"OUTPUT_EXISTS={OUTPUT_DIR.exists()}",
        f"PVC_NAME={PVC_NAME}",
    ]
    return "\n".join(lines)


@app.get("/dbcheck", response_class=PlainTextResponse)
def dbcheck():
    db = get_db()
    try:
        count = db.query(ProductRequest).count()
        return f"DB OK\nproduct_requests count={count}\n"
    except Exception as e:
        return f"DB FAIL\n{repr(e)}\n"
    finally:
        db.close()


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    db = get_db()
    try:
        products = db.query(ProductRequest).order_by(ProductRequest.created_at.desc()).all()
        for p in products:
            refresh_product_status(db, p)
        return templates.TemplateResponse("index.html", {"request": request, "products": products})
    finally:
        db.close()


@app.get("/products/new", response_class=HTMLResponse)
def new_product(request: Request):
    return templates.TemplateResponse("new_product.html", {"request": request})


@app.post("/products")
def create_product(
    name: str = Form(...),
    category: str = Form(...),
    description: str = Form(""),
    width_mm: float | None = Form(None),
    depth_mm: float | None = Form(None),
    height_mm: float | None = Form(None),
    shape: str = Form(""),
    color: str = Form(""),
    surface: str = Form(""),
    material: str = Form("PETG"),
    mount_type: str = Form(""),
    support_allowed: str | None = Form(None),
    printer_targets: list[str] = Form([]),
):
    db = get_db()
    try:
        product_id = str(uuid.uuid4())

        product = ProductRequest(
            id=product_id,
            name=name,
            category=category,
            description=description,
            width_mm=width_mm,
            depth_mm=depth_mm,
            height_mm=height_mm,
            shape=shape,
            color=color,
            surface=surface,
            material=material,
            mount_type=mount_type,
            support_allowed=(support_allowed == "true"),
            printer_targets="\n".join([f"- {p}" for p in printer_targets]),
            status="MD_CREATED",
        )

        db.add(product)
        db.commit()

        md_path = write_product_md(product)

        db.add(ProductFile(
            id=str(uuid.uuid4()),
            product_id=product.id,
            file_type="product_md",
            file_name="product.md",
            file_path=str(md_path),
        ))

        try:
            job_name = create_blender_job(product.id)

            db.add(GenerationJob(
                id=str(uuid.uuid4()),
                product_id=product.id,
                k8s_job_name=job_name,
                status="QUEUED",
            ))

            product.status = "QUEUED"

        except Exception as e:
            db.add(GenerationJob(
                id=str(uuid.uuid4()),
                product_id=product.id,
                k8s_job_name=None,
                status="FAILED",
                error_message=repr(e),
            ))

            product.status = "FAILED"

        db.commit()

        return RedirectResponse(url=f"/products/{product_id}", status_code=303)
    finally:
        db.close()


@app.get("/products/{product_id}", response_class=HTMLResponse)
def product_detail(request: Request, product_id: str):
    db = get_db()
    try:
        product = db.query(ProductRequest).filter(ProductRequest.id == product_id).first()
        if not product:
            raise HTTPException(status_code=404, detail="Product not found")

        refresh_product_status(db, product)

        files = []
        base = product_base_dir(product_id)

        for subdir in ["input", "output", "logs"]:
            target = base / subdir
            if target.exists():
                for f in sorted(target.glob("*")):
                    if f.is_file():
                        files.append({
                            "subdir": subdir,
                            "name": f.name,
                            "size": f.stat().st_size,
                            "download_url": f"/products/{product_id}/download/{subdir}/{f.name}",
                        })

        jobs = db.query(GenerationJob).filter(
            GenerationJob.product_id == product_id
        ).order_by(GenerationJob.created_at.desc()).all()

        return templates.TemplateResponse(
            "product_detail.html",
            {"request": request, "product": product, "files": files, "jobs": jobs},
        )
    finally:
        db.close()


@app.get("/products/{product_id}/download/{subdir}/{filename}")
def download_file(product_id: str, subdir: str, filename: str):
    if subdir not in ["input", "output", "logs"]:
        raise HTTPException(status_code=400, detail="Invalid subdir")

    path = product_base_dir(product_id) / subdir / filename

    if not path.exists():
        raise HTTPException(status_code=404, detail="File not found")

    return FileResponse(path, filename=filename)


@app.post("/products/{product_id}/rerun")
def rerun_product(product_id: str):
    db = get_db()
    try:
        product = db.query(ProductRequest).filter(ProductRequest.id == product_id).first()
        if not product:
            raise HTTPException(status_code=404, detail="Product not found")

        write_product_md(product)

        try:
            job_name = create_blender_job(product.id)

            db.add(GenerationJob(
                id=str(uuid.uuid4()),
                product_id=product.id,
                k8s_job_name=job_name,
                status="QUEUED",
            ))

            product.status = "QUEUED"
        except Exception as e:
            db.add(GenerationJob(
                id=str(uuid.uuid4()),
                product_id=product.id,
                status="FAILED",
                error_message=repr(e),
            ))

            product.status = "FAILED"

        db.commit()

        return RedirectResponse(url=f"/products/{product_id}", status_code=303)
    finally:
        db.close()
PY

cat > "${ROOT}/portal/app/templates/base.html" <<'HTML'
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
      <a href="/debug">Debug</a>
      <a href="/dbcheck">DB Check</a>
    </nav>
  </header>
  <main>
    {% block content %}{% endblock %}
  </main>
</body>
</html>
HTML

cat > "${ROOT}/portal/app/templates/index.html" <<'HTML'
{% extends "base.html" %}
{% block content %}
<section class="card">
  <h2>제품 요청 목록</h2>
  <p><a href="/products/new">새 제품 요청 생성</a></p>
  <table>
    <thead>
      <tr>
        <th>제품명</th>
        <th>카테고리</th>
        <th>상태</th>
        <th>생성일</th>
      </tr>
    </thead>
    <tbody>
      {% for p in products %}
      <tr>
        <td><a href="/products/{{ p.id }}">{{ p.name }}</a></td>
        <td>{{ p.category }}</td>
        <td>{{ p.status }}</td>
        <td>{{ p.created_at }}</td>
      </tr>
      {% endfor %}
    </tbody>
  </table>
</section>
{% endblock %}
HTML

cat > "${ROOT}/portal/app/templates/new_product.html" <<'HTML'
{% extends "base.html" %}
{% block content %}
<section class="card">
  <h2>새 제품 요청</h2>

  <form method="post" action="/products">
    <label>제품명</label>
    <input name="name" required placeholder="Bambu A1 Tool Holder">

    <label>카테고리</label>
    <select name="category">
      <option value="bambu_accessory">Bambu 액세서리</option>
      <option value="homelab_accessory">홈랩 액세서리</option>
      <option value="cable_management">케이블 정리</option>
      <option value="battery_case">배터리 케이스</option>
      <option value="desk_organizer">책상 정리</option>
    </select>

    <label>설명</label>
    <textarea name="description" rows="4"></textarea>

    <div class="grid3">
      <div>
        <label>가로 mm</label>
        <input name="width_mm" type="number" step="0.1">
      </div>
      <div>
        <label>세로/깊이 mm</label>
        <input name="depth_mm" type="number" step="0.1">
      </div>
      <div>
        <label>높이 mm</label>
        <input name="height_mm" type="number" step="0.1">
      </div>
    </div>

    <label>형태</label>
    <input name="shape" placeholder="둥근 사각형, 클립형, 박스형">

    <label>색상</label>
    <input name="color" placeholder="검정, 흰색, 투명">

    <label>표면</label>
    <input name="surface" placeholder="무광, 격자 패턴, 로고 음각">

    <label>재료</label>
    <select name="material">
      <option value="PLA">PLA</option>
      <option value="PETG" selected>PETG</option>
      <option value="ASA">ASA</option>
      <option value="ABS">ABS</option>
      <option value="TPU">TPU</option>
    </select>

    <label>고정 방식</label>
    <input name="mount_type" placeholder="걸이형, M3 볼트, 자석">

    <label>
      <input type="checkbox" name="support_allowed" value="true">
      서포트 허용
    </label>

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
HTML

cat > "${ROOT}/portal/app/templates/product_detail.html" <<'HTML'
{% extends "base.html" %}
{% block content %}
<section class="card">
  <h2>{{ product.name }}</h2>

  <table>
    <tr><th>상태</th><td>{{ product.status }}</td></tr>
    <tr><th>카테고리</th><td>{{ product.category }}</td></tr>
    <tr><th>설명</th><td>{{ product.description }}</td></tr>
    <tr><th>크기</th><td>{{ product.width_mm }} x {{ product.depth_mm }} x {{ product.height_mm }} mm</td></tr>
    <tr><th>형태</th><td>{{ product.shape }}</td></tr>
    <tr><th>색상</th><td>{{ product.color }}</td></tr>
    <tr><th>표면</th><td>{{ product.surface }}</td></tr>
    <tr><th>재료</th><td>{{ product.material }}</td></tr>
    <tr><th>고정 방식</th><td>{{ product.mount_type }}</td></tr>
    <tr><th>서포트 허용</th><td>{{ product.support_allowed }}</td></tr>
    <tr><th>프린터</th><td><pre>{{ product.printer_targets }}</pre></td></tr>
  </table>

  <form method="post" action="/products/{{ product.id }}/rerun">
    <button type="submit">다시 생성</button>
  </form>
</section>

<section class="card">
  <h3>생성 Job</h3>
  <table>
    <thead>
      <tr>
        <th>Job Name</th>
        <th>Status</th>
        <th>Error</th>
        <th>Created</th>
      </tr>
    </thead>
    <tbody>
      {% for j in jobs %}
      <tr>
        <td>{{ j.k8s_job_name }}</td>
        <td>{{ j.status }}</td>
        <td>{{ j.error_message }}</td>
        <td>{{ j.created_at }}</td>
      </tr>
      {% endfor %}
    </tbody>
  </table>
</section>

<section class="card">
  <h3>파일 다운로드</h3>
  {% if files %}
  <table>
    <thead>
      <tr>
        <th>구분</th>
        <th>파일</th>
        <th>크기</th>
        <th>다운로드</th>
      </tr>
    </thead>
    <tbody>
      {% for f in files %}
      <tr>
        <td>{{ f.subdir }}</td>
        <td>{{ f.name }}</td>
        <td>{{ f.size }}</td>
        <td><a href="{{ f.download_url }}">Download</a></td>
      </tr>
      {% endfor %}
    </tbody>
  </table>
  {% else %}
  <p>아직 생성된 파일이 없습니다.</p>
  {% endif %}
</section>
{% endblock %}
HTML

cat > "${ROOT}/portal/app/static/style.css" <<'CSS'
body {
  font-family: Arial, sans-serif;
  margin: 0;
  background: #f5f5f5;
  color: #222;
}

header {
  background: #222;
  color: #fff;
  padding: 16px 32px;
}

header h1 {
  margin: 0 0 8px 0;
}

nav a {
  color: #fff;
  margin-right: 16px;
}

main {
  max-width: 1100px;
  margin: 24px auto;
  padding: 0 16px;
}

.card {
  background: #fff;
  border: 1px solid #ddd;
  padding: 24px;
  margin-bottom: 24px;
}

label {
  display: block;
  margin-top: 14px;
  font-weight: bold;
}

input,
select,
textarea {
  width: 100%;
  box-sizing: border-box;
  padding: 10px;
  margin-top: 6px;
  border: 1px solid #aaa;
}

button {
  margin-top: 20px;
  padding: 10px 18px;
  cursor: pointer;
}

table {
  width: 100%;
  border-collapse: collapse;
  margin-top: 12px;
}

th,
td {
  border: 1px solid #ddd;
  padding: 8px;
  vertical-align: top;
}

th {
  background: #f0f0f0;
}

.grid3 {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 12px;
}

.checks label {
  font-weight: normal;
}
CSS

python3 -m py_compile "${ROOT}/portal/app/main.py"

echo "[DONE] portal minimal rebuild files created"
echo "ROOT=${ROOT}"
