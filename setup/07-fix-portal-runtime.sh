#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/ai/tashkent/3d-model-factory/.factory.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "[ERROR] ${ENV_FILE} not found."
  exit 1
fi

source "${ENV_FILE}"

cat > "${ROOT}/portal/app/main.py" <<'PY'
import os
import uuid
from datetime import datetime
from pathlib import Path
from typing import List, Optional

from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, FileResponse, RedirectResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from sqlalchemy import create_engine, Column, String, Text, DateTime, Boolean, Numeric, ForeignKey
from sqlalchemy.orm import declarative_base, sessionmaker, relationship
from sqlalchemy.exc import SQLAlchemyError

from kubernetes import client, config


APP_DIR = Path(__file__).resolve().parent
TEMPLATE_DIR = APP_DIR / "templates"
STATIC_DIR = APP_DIR / "static"

TEMPLATE_DIR.mkdir(parents=True, exist_ok=True)
STATIC_DIR.mkdir(parents=True, exist_ok=True)

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
    description = Column(Text, nullable=True)

    width_mm = Column(Numeric, nullable=True)
    depth_mm = Column(Numeric, nullable=True)
    height_mm = Column(Numeric, nullable=True)

    shape = Column(String, nullable=True)
    color = Column(String, nullable=True)
    surface = Column(String, nullable=True)
    material = Column(String, nullable=True)
    mount_type = Column(String, nullable=True)
    support_allowed = Column(Boolean, default=False)
    printer_targets = Column(Text, nullable=True)

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
    k8s_job_name = Column(String, nullable=True)
    status = Column(String, default="QUEUED")
    error_message = Column(Text, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow)

    product = relationship("ProductRequest", back_populates="jobs")


app = FastAPI(title="3D Model Factory Portal")
templates = Jinja2Templates(directory=str(TEMPLATE_DIR))
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.on_event("startup")
def startup():
    try:
        Base.metadata.create_all(bind=engine)
        print("[INFO] DB schema initialized")
    except Exception as e:
        print("[ERROR] DB schema initialization failed:", repr(e))

    try:
        config.load_incluster_config()
        print("[INFO] Kubernetes incluster config loaded")
    except Exception as e:
        print("[WARN] Incluster config failed:", repr(e))
        try:
            config.load_kube_config()
            print("[INFO] Local kube config loaded")
        except Exception as e2:
            print("[WARN] kube config load failed:", repr(e2))


def get_db():
    return SessionLocal()


def product_dir(product_id: str) -> Path:
    return OUTPUT_DIR / "products" / product_id


def write_product_md(product: ProductRequest) -> Path:
    base = product_dir(product.id)
    input_dir = base / "input"
    output_dir = base / "output"
    logs_dir = base / "logs"

    input_dir.mkdir(parents=True, exist_ok=True)
    output_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)

    md = f"""# Product Design Request

## Basic

- Product ID: {product.id}
- Name: {product.name}
- Category: {product.category}
- Description: {product.description or ""}

## Dimensions

| Item | Value |
|---|---|
| Width | {product.width_mm or ""}mm |
| Depth | {product.depth_mm or ""}mm |
| Height | {product.height_mm or ""}mm |

## Design

| Item | Value |
|---|---|
| Shape | {product.shape or ""} |
| Surface | {product.surface or ""} |
| Color | {product.color or ""} |
| Material | {product.material or ""} |
| Mount Type | {product.mount_type or ""} |
| Support Allowed | {product.support_allowed} |

## Printer Target

{product.printer_targets or ""}

## Output Requirements

- Generate STL
- Generate BLEND
- Generate README
- Validate mesh
"""

    md_path = input_dir / "product.md"
    md_path.write_text(md, encoding="utf-8")
    return md_path


def create_blender_job(product_id: str) -> str:
    batch = client.BatchV1Api()

    safe_id = product_id.replace("-", "")[:18]
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
        persistent_volume_claim=client.V1PersistentVolumeClaimVolumeSource(
            claim_name=PVC_NAME
        )
    )

    pod_spec = client.V1PodSpec(
        restart_policy="Never",
        containers=[container],
        volumes=[volume],
    )

    pod_template = client.V1PodTemplateSpec(
        metadata=client.V1ObjectMeta(
            labels={
                "app": "model-factory-worker",
                "product-id": product_id,
            }
        ),
        spec=pod_spec,
    )

    job_spec = client.V1JobSpec(
        template=pod_template,
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


def refresh_job_status(db, product: ProductRequest):
    if not product.jobs:
        return product.status

    latest = sorted(product.jobs, key=lambda j: j.created_at)[-1]
    if not latest.k8s_job_name:
        return product.status

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
        print("[WARN] refresh_job_status failed:", repr(e))

    return product.status


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


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    db = get_db()
    try:
        products = db.query(ProductRequest).order_by(ProductRequest.created_at.desc()).all()
        for p in products:
            refresh_job_status(db, p)
        return templates.TemplateResponse("index.html", {"request": request, "products": products})
    except Exception as e:
        return HTMLResponse(
            f"<h1>Model Portal Error</h1><pre>{repr(e)}</pre><p>Check /debug and pod logs.</p>",
            status_code=500,
        )
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
    db = get_db()
    product_id = str(uuid.uuid4())

    try:
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

        product_file = ProductFile(
            id=str(uuid.uuid4()),
            product_id=product.id,
            file_type="product_md",
            file_name="product.md",
            file_path=str(md_path),
        )
        db.add(product_file)

        try:
            job_name = create_blender_job(product.id)
            job = GenerationJob(
                id=str(uuid.uuid4()),
                product_id=product.id,
                k8s_job_name=job_name,
                status="QUEUED",
            )
            product.status = "QUEUED"
            db.add(job)
            db.commit()
        except Exception as e:
            product.status = "FAILED"
            job = GenerationJob(
                id=str(uuid.uuid4()),
                product_id=product.id,
                k8s_job_name=None,
                status="FAILED",
                error_message=repr(e),
            )
            db.add(job)
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

        refresh_job_status(db, product)

        files = []
        base = product_dir(product_id)
        for sub in ["input", "output", "logs"]:
            d = base / sub
            if d.exists():
                for f in sorted(d.glob("*")):
                    if f.is_file():
                        files.append({
                            "name": f.name,
                            "subdir": sub,
                            "size": f.stat().st_size,
                            "download_url": f"/products/{product_id}/download/{sub}/{f.name}",
                        })

        jobs = db.query(GenerationJob).filter(
            GenerationJob.product_id == product_id
        ).order_by(GenerationJob.created_at.desc()).all()

        return templates.TemplateResponse(
            "product_detail.html",
            {"request": request, "product": product, "files": files, "jobs": jobs}
        )
    finally:
        db.close()


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
    db = get_db()
    try:
        product = db.query(ProductRequest).filter(ProductRequest.id == product_id).first()
        if not product:
            raise HTTPException(status_code=404, detail="Product not found")

        write_product_md(product)

        try:
            job_name = create_blender_job(product.id)
            job = GenerationJob(
                id=str(uuid.uuid4()),
                product_id=product.id,
                k8s_job_name=job_name,
                status="QUEUED",
            )
            product.status = "QUEUED"
            db.add(job)
            db.commit()
        except Exception as e:
            product.status = "FAILED"
            job = GenerationJob(
                id=str(uuid.uuid4()),
                product_id=product.id,
                status="FAILED",
                error_message=repr(e),
            )
            db.add(job)
            db.commit()

        return RedirectResponse(url=f"/products/{product_id}", status_code=303)
    finally:
        db.close()
PY

python3 -m py_compile "${ROOT}/portal/app/main.py"

echo "[DONE] portal runtime patch created"
