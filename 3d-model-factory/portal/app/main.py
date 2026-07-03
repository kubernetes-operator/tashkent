import os
import uuid
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, Request, Form, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse, FileResponse, PlainTextResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from sqlalchemy import create_engine, Column, String, Text, DateTime, Boolean, Numeric, Integer, ForeignKey, text
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
DEBUG_TEXT_LIMIT = 20000

Base = declarative_base()
engine = create_engine(DATABASE_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)


class ProductRequest(Base):
    __tablename__ = "product_requests"

    id = Column(String, primary_key=True)
    name = Column(String, nullable=False)
    category = Column(String, nullable=False)
    preset_id = Column(String, default="custom")
    description = Column(Text)

    width_mm = Column(Numeric)
    depth_mm = Column(Numeric)
    height_mm = Column(Numeric)

    shape = Column(String)
    color = Column(String)
    surface = Column(String)
    material = Column(String)
    mount_type = Column(String)
    cable_channels = Column(Integer, default=1)
    cable_diameter_mm = Column(Numeric, default=6.0)
    magnet_diameter_mm = Column(Numeric, default=10.0)
    magnet_thickness_mm = Column(Numeric, default=2.0)
    hinge_count = Column(Integer, default=3)
    clearance_mm = Column(Numeric, default=0.3)
    support_allowed = Column(Boolean, default=False)
    use_gpu = Column(Boolean, default=False)
    gpu_task = Column(String, default="none")
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

PRODUCT_PRESETS = [
    {
        "id": "custom",
        "label": "직접 입력",
        "category": "",
        "description": "",
        "width_mm": "",
        "depth_mm": "",
        "height_mm": "",
        "shape": "",
        "color": "",
        "surface": "",
        "material": "PETG",
        "mount_type": "",
        "support_allowed": False,
        "use_gpu": False,
        "gpu_task": "none",
    },
    {
        "id": "bambu_a1_nozzle_holder",
        "label": "Bambu A1 노즐 홀더",
        "category": "bambu_accessory",
        "description": "Bambu Lab A1 주변에 둘 수 있는 소형 노즐/소모품 홀더",
        "width_mm": 95,
        "depth_mm": 45,
        "height_mm": 28,
        "shape": "box tray",
        "color": "black",
        "surface": "grid matte",
        "material": "PETG",
        "mount_type": "desktop",
        "support_allowed": False,
        "use_gpu": True,
        "gpu_task": "preview",
    },
    {
        "id": "bambu_scraper_holder",
        "label": "Bambu 스크래퍼 거치대",
        "category": "bambu_accessory",
        "description": "스크래퍼 또는 얇은 공구를 세워 보관하는 거치대",
        "width_mm": 110,
        "depth_mm": 38,
        "height_mm": 42,
        "shape": "hook holder",
        "color": "black",
        "surface": "matte",
        "material": "PETG",
        "mount_type": "M3 bolt",
        "support_allowed": False,
        "use_gpu": True,
        "gpu_task": "preview",
    },
    {
        "id": "m3_wall_hook",
        "label": "M3 벽걸이 후크",
        "category": "desk_organizer",
        "description": "M3 볼트 2개로 고정하는 범용 벽걸이 후크",
        "width_mm": 80,
        "depth_mm": 42,
        "height_mm": 35,
        "shape": "hook holder",
        "color": "black",
        "surface": "matte",
        "material": "PETG",
        "mount_type": "M3 bolt",
        "support_allowed": False,
        "use_gpu": True,
        "gpu_task": "preview",
    },
    {
        "id": "cable_clip_small",
        "label": "소형 케이블 클립",
        "category": "cable_management",
        "description": "USB-C, 전원선 등 얇은 케이블을 정리하는 클립",
        "width_mm": 55,
        "depth_mm": 24,
        "height_mm": 18,
        "shape": "clip",
        "color": "black",
        "surface": "matte",
        "material": "PETG",
        "mount_type": "adhesive",
        "support_allowed": False,
        "use_gpu": False,
        "gpu_task": "none",
    },
    {
        "id": "homelab_label_holder",
        "label": "홈랩/랙 라벨 홀더",
        "category": "homelab_accessory",
        "description": "서버, 스위치, 케이블 앞단에 붙이는 라벨 홀더",
        "width_mm": 120,
        "depth_mm": 22,
        "height_mm": 16,
        "shape": "rounded rectangular holder",
        "color": "white",
        "surface": "matte",
        "material": "PLA",
        "mount_type": "adhesive",
        "support_allowed": False,
        "use_gpu": False,
        "gpu_task": "none",
    },
    {
        "id": "battery_case_2cell",
        "label": "2셀 배터리 케이스",
        "category": "battery_case",
        "description": "소형 배터리 2개를 보관하는 단순 오픈 트레이 케이스",
        "width_mm": 72,
        "depth_mm": 38,
        "height_mm": 18,
        "shape": "box case",
        "color": "black",
        "surface": "grid matte",
        "material": "PETG",
        "mount_type": "none",
        "support_allowed": False,
        "use_gpu": True,
        "gpu_task": "preview",
    },
]


templates = Jinja2Templates(directory=str(TEMPLATE_DIR))
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.on_event("startup")
def startup():
    Base.metadata.create_all(bind=engine)
    ensure_product_request_parameter_columns()

    try:
        config.load_incluster_config()
        print("[INFO] Kubernetes incluster config loaded")
    except Exception as e:
        print("[WARN] Kubernetes config load failed:", repr(e))


def ensure_product_request_parameter_columns():
    statements = [
        "ALTER TABLE product_requests ADD COLUMN IF NOT EXISTS cable_channels integer DEFAULT 1",
        "ALTER TABLE product_requests ADD COLUMN IF NOT EXISTS cable_diameter_mm numeric DEFAULT 6.0",
        "ALTER TABLE product_requests ADD COLUMN IF NOT EXISTS magnet_diameter_mm numeric DEFAULT 10.0",
        "ALTER TABLE product_requests ADD COLUMN IF NOT EXISTS magnet_thickness_mm numeric DEFAULT 2.0",
        "ALTER TABLE product_requests ADD COLUMN IF NOT EXISTS hinge_count integer DEFAULT 3",
        "ALTER TABLE product_requests ADD COLUMN IF NOT EXISTS clearance_mm numeric DEFAULT 0.3",
    ]
    with engine.begin() as conn:
        for stmt in statements:
            conn.execute(text(stmt))


def get_db():
    return SessionLocal()


def product_base_dir(product_id: str) -> Path:
    return OUTPUT_DIR / "products" / product_id


def read_limited_text(path: Path, limit: int = DEBUG_TEXT_LIMIT) -> tuple[str | None, bool]:
    if not path.exists() or not path.is_file():
        return None, False

    text_value = path.read_text(encoding="utf-8", errors="replace")
    if len(text_value) > limit:
        return text_value[:limit] + "\n... truncated ...", True
    return text_value, False


def collect_debug_texts(product_id: str):
    base = product_base_dir(product_id)
    targets = [
        ("validation.txt", base / "output" / "validation.txt"),
        ("product.md", base / "input" / "product.md"),
        ("output_status.txt", base / "output" / "output_status.txt"),
        ("design_metadata.txt", base / "output" / "design_metadata.txt"),
        ("worker_flow_debug.txt", base / "output" / "worker_flow_debug.txt"),
        ("worker_error.txt", base / "output" / "worker_error.txt"),
        ("shape_intent_debug.txt", base / "output" / "shape_intent_debug.txt"),
        ("job.log", base / "logs" / "job.log"),
    ]

    debug_texts = []
    validation_status = "UNKNOWN"
    for label, path in targets:
        try:
            content, truncated = read_limited_text(path)
        except Exception as e:
            content = f"파일 읽기 실패: {repr(e)}"
            truncated = False

        if label == "validation.txt" and content:
            for line in content.splitlines():
                if line.startswith("VALIDATION_STATUS="):
                    validation_status = line.split("=", 1)[1].strip() or "UNKNOWN"
                    break

        debug_texts.append({
            "label": label,
            "content": content,
            "truncated": truncated,
            "exists": content is not None,
        })

    return debug_texts, validation_status


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
        f"- Preset ID: {product.preset_id or 'custom'}",
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
        f"- Cable Channels: {product.cable_channels or 1}",
        f"- Cable Diameter: {product.cable_diameter_mm or 6.0}mm",
        f"- Magnet Diameter: {product.magnet_diameter_mm or 10.0}mm",
        f"- Magnet Thickness: {product.magnet_thickness_mm or 2.0}mm",
        f"- Hinge Count: {product.hinge_count or 3}",
        f"- Clearance: {product.clearance_mm or 0.3}mm",
        f"- GPU Enabled: {product.use_gpu}",
        f"- GPU Task: {product.gpu_task or 'none'}",
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


def create_blender_job(product_id: str, product_obj=None) -> str:
    current_product_for_job = product_obj
    batch = client.BatchV1Api()

    safe_id = product_id.replace("-", "")[:16]
    suffix = datetime.utcnow().strftime("%H%M%S")
    job_name = f"model-factory-{safe_id}-{suffix}"

    container = client.V1Container(
        name="blender-worker",
        image=WORKER_IMAGE,
        image_pull_policy="Always",
        resources=client.V1ResourceRequirements(
            requests={"cpu": "1", "memory": "2Gi"},
            limits=({"cpu": "4", "memory": "8Gi", "nvidia.com/gpu": "1"} if getattr(current_product_for_job, "use_gpu", False) else {"cpu": "4", "memory": "8Gi"}),
        ),
        env=[
            client.V1EnvVar(name="PRODUCT_ID", value=product_id),
            client.V1EnvVar(name="PRODUCT_MD", value=f"/data/products/{product_id}/input/product.md"),
            client.V1EnvVar(name="OUTPUT_DIR", value=f"/data/products/{product_id}/output"),
            client.V1EnvVar(name="USE_GPU", value="true" if getattr(current_product_for_job, "use_gpu", False) else "false"),
            client.V1EnvVar(name="GPU_TASK", value=getattr(current_product_for_job, "gpu_task", "none") or "none"),
        ],
        volume_mounts=[
            client.V1VolumeMount(name="model-storage", mount_path="/data")
        ],
    )

    volume = client.V1Volume(
        name="model-storage",
        persistent_volume_claim=client.V1PersistentVolumeClaimVolumeSource(claim_name=PVC_NAME),
    )

    tolerations = []
    if getattr(current_product_for_job, "use_gpu", False):
        tolerations = [
            client.V1Toleration(
                key="nvidia.com/gpu",
                operator="Equal",
                value="rtx4060",
                effect="NoSchedule",
            ),
            client.V1Toleration(
                key="nvidia.com/gpu",
                operator="Equal",
                value="rtx2070",
                effect="NoSchedule",
            ),
        ]

    pod_spec = client.V1PodSpec(
        restart_policy="Never",
        containers=[container],
        volumes=[volume],
        tolerations=tolerations,
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



@app.get("/api/presets")
def api_presets():
    return {"presets": PRODUCT_PRESETS}

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
        safe_products = []
        for p in products:
            try:
                refresh_product_status(db, p)
            except Exception as e:
                print("[WARN] refresh_product_status failed on index:", repr(e))
            safe_products.append(p)

        try:
            return templates.TemplateResponse(name="index.html", request=request, context={"products": safe_products})
        except Exception as e:
            return HTMLResponse(
                "<h1>Template Render Error</h1><pre>" + repr(e) + "</pre>",
                status_code=500
            )
    except Exception as e:
        return HTMLResponse(
            "<h1>Index DB Error</h1><pre>" + repr(e) + "</pre>",
            status_code=500
        )
    finally:
        db.close()


@app.get("/products/new", response_class=HTMLResponse)
def new_product(request: Request):
    return templates.TemplateResponse(name="new_product.html", request=request, context={})


@app.post("/products")
def create_product(
    preset_id: str = Form("custom"),
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
    cable_channels: int = Form(1),
    cable_diameter_mm: float = Form(6.0),
    magnet_diameter_mm: float = Form(10.0),
    magnet_thickness_mm: float = Form(2.0),
    hinge_count: int = Form(3),
    clearance_mm: float = Form(0.3),
    printer_targets: list[str] = Form([]),
    use_gpu: str | None = Form(None),
    gpu_task: str = Form("none"),
):
    db = get_db()
    try:
        product_id = str(uuid.uuid4())

        product = ProductRequest(
            id=product_id,
            preset_id=preset_id,
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
            cable_channels=cable_channels,
            cable_diameter_mm=cable_diameter_mm,
            magnet_diameter_mm=magnet_diameter_mm,
            magnet_thickness_mm=magnet_thickness_mm,
            hinge_count=hinge_count,
            clearance_mm=clearance_mm,
            support_allowed=(support_allowed == "true"),
            use_gpu=(use_gpu == "true"),
            gpu_task=gpu_task,
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
            job_name = create_blender_job(product.id, product)

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

        debug_texts, validation_status = collect_debug_texts(product_id)

        return templates.TemplateResponse(
            name="product_detail.html",
            request=request,
            context={
                "product": product,
                "files": files,
                "jobs": jobs,
                "debug_texts": debug_texts,
                "validation_status": validation_status,
            },
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
            job_name = create_blender_job(product.id, product)

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
