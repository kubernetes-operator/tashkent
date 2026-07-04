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

from file_reader import (
    parse_key_value_text,
    parse_validation_status,
    read_product_debug_files,
    read_run_debug_files,
)
from job_runner import create_blender_job
from preset_service import (
    create_preset as create_preset_record,
    custom_preset_dict,
    deactivate_preset,
    get_preset_or_404,
    list_active_presets,
    preset_form_to_data,
    preset_to_dict,
    seed_default_presets,
    update_preset as update_preset_record,
)
from product_md import write_product_md
from run_service import (
    build_run_summaries,
    get_next_run_number,
    get_product_base_dir,
    get_run_dir,
    list_run_numbers,
    write_run_metadata as write_run_metadata_file,
)


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
PRODUCTS_DATA_ROOT = OUTPUT_DIR / "products"

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


class ProductPreset(Base):
    __tablename__ = "product_presets"

    id = Column(String, primary_key=True)
    label = Column(String, nullable=False)
    category = Column(String)
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
    use_gpu = Column(Boolean, default=False)
    gpu_task = Column(String, default="none")
    cable_channels = Column(Integer, default=1)
    cable_diameter_mm = Column(Numeric, default=6.0)
    magnet_diameter_mm = Column(Numeric, default=10.0)
    magnet_thickness_mm = Column(Numeric, default=2.0)
    hinge_count = Column(Integer, default=3)
    clearance_mm = Column(Numeric, default=0.3)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow)


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
    run_number = Column(Integer)
    output_dir = Column(Text)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow)

    product = relationship("ProductRequest", back_populates="jobs")


app = FastAPI(title="3D Model Factory Portal")


templates = Jinja2Templates(directory=str(TEMPLATE_DIR))
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.on_event("startup")
def startup():
    Base.metadata.create_all(bind=engine)
    ensure_product_request_parameter_columns()
    ensure_generation_job_run_columns()
    seed_default_presets_if_empty()

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


def ensure_generation_job_run_columns():
    statements = [
        "ALTER TABLE generation_jobs ADD COLUMN IF NOT EXISTS run_number integer",
        "ALTER TABLE generation_jobs ADD COLUMN IF NOT EXISTS output_dir text",
    ]
    with engine.begin() as conn:
        for stmt in statements:
            conn.execute(text(stmt))


def get_db():
    return SessionLocal()


def preset_custom_dict() -> dict:
    return custom_preset_dict()


def active_preset_dicts(db, include_custom: bool = True) -> list[dict]:
    presets = list_active_presets(db, ProductPreset)
    result = [preset_to_dict(preset) for preset in presets]
    if include_custom:
        return [preset_custom_dict()] + result
    return result


def seed_default_presets_if_empty():
    db = get_db()
    try:
        seed_default_presets(db, ProductPreset)
    except Exception as e:
        db.rollback()
        print("[WARN] failed to seed product presets:", repr(e))
    finally:
        db.close()


def product_base_dir(product_id: str) -> Path:
    return get_product_base_dir(product_id, PRODUCTS_DATA_ROOT)


def product_container_base_dir(product_id: str) -> str:
    return f"/data/products/{product_id}"


def run_dir_for(product_id: str, run_number: int) -> Path:
    return get_run_dir(product_id, run_number, PRODUCTS_DATA_ROOT)


def run_container_dir_for(product_id: str, run_number: int) -> str:
    return f"{product_container_base_dir(product_id)}/runs/{run_number}"


def parse_run_selection(runs_param: str | None, available: list[int]) -> tuple[list[int], list[str]]:
    warnings = []
    available_set = set(available)

    if not runs_param:
        return list(reversed(available))[:3], warnings

    selected = []
    for raw in runs_param.split(","):
        value = raw.strip()
        if not value:
            continue
        if not value.isdigit():
            warnings.append(f"숫자가 아닌 run 값은 무시했습니다: {value}")
            continue

        run_number = int(value)
        if run_number not in available_set:
            warnings.append(f"존재하지 않는 run은 무시했습니다: {run_number}")
            continue
        if run_number not in selected:
            selected.append(run_number)

    return selected, warnings


def collect_compare_runs(product_id: str, run_numbers: list[int]):
    design_keys = [
        "engine_version",
        "design_profile",
        "material",
        "width_mm",
        "depth_mm",
        "height_mm",
        "cable_channels",
        "cable_diameter_mm",
        "magnet_diameter_mm",
        "magnet_thickness_mm",
        "hinge_count",
        "clearance_mm",
    ]
    output_keys = ["preview_status", "render_mode", "three_mf_status", "design_profile"]
    compare_runs = []

    for run_number in run_numbers:
        run_dir = run_dir_for(product_id, run_number)
        texts = read_run_debug_files(run_dir)
        design_values = parse_key_value_text(texts["design_metadata.txt"]["content"])
        output_values = parse_key_value_text(texts["output_status.txt"]["content"])
        preview_path = run_dir / "preview.png"
        preview_exists = preview_path.exists() and preview_path.is_file()

        compare_runs.append({
            "number": run_number,
            "preview_exists": preview_exists,
            "preview_url": f"/products/{product_id}/download/runs/{run_number}/preview.png",
            "validation_status": parse_validation_status(texts["validation.txt"]["content"]),
            "design": {key: design_values.get(key, "") for key in design_keys},
            "output": {key: output_values.get(key, "") for key in output_keys},
            "texts": texts,
        })

    return compare_runs


def collect_debug_texts(product_id: str):
    debug_files = read_product_debug_files(product_base_dir(product_id))
    return debug_files["debug_texts"], debug_files["validation_status"]


def update_product_from_form(
    product: ProductRequest,
    preset_id: str,
    name: str,
    category: str,
    description: str,
    width_mm: float | None,
    depth_mm: float | None,
    height_mm: float | None,
    shape: str,
    color: str,
    surface: str,
    material: str,
    mount_type: str,
    support_allowed: str | None,
    cable_channels: int,
    cable_diameter_mm: float,
    magnet_diameter_mm: float,
    magnet_thickness_mm: float,
    hinge_count: int,
    clearance_mm: float,
    printer_targets: list[str],
    use_gpu: str | None,
    gpu_task: str,
) -> None:
    product.preset_id = preset_id
    product.name = name
    product.category = category
    product.description = description
    product.width_mm = width_mm
    product.depth_mm = depth_mm
    product.height_mm = height_mm
    product.shape = shape
    product.color = color
    product.surface = surface
    product.material = material
    product.mount_type = mount_type
    product.cable_channels = cable_channels
    product.cable_diameter_mm = cable_diameter_mm
    product.magnet_diameter_mm = magnet_diameter_mm
    product.magnet_thickness_mm = magnet_thickness_mm
    product.hinge_count = hinge_count
    product.clearance_mm = clearance_mm
    product.support_allowed = (support_allowed == "true")
    product.use_gpu = (use_gpu == "true")
    product.gpu_task = gpu_task
    product.printer_targets = "\n".join([f"- {p}" for p in printer_targets])
    product.updated_at = datetime.utcnow()


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
    db = get_db()
    try:
        presets = [preset_to_dict(preset) for preset in list_active_presets(db, ProductPreset)]
        return {"presets": [preset_custom_dict()] + presets}
    finally:
        db.close()

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


@app.get("/presets", response_class=HTMLResponse)
def presets_index(request: Request):
    db = get_db()
    try:
        active_presets = list_active_presets(db, ProductPreset)
        inactive_presets = db.query(ProductPreset).filter(
            ProductPreset.is_active == False
        ).order_by(ProductPreset.label.asc()).all()
        return templates.TemplateResponse(
            name="presets.html",
            request=request,
            context={
                "presets": active_presets + inactive_presets,
            },
        )
    finally:
        db.close()


@app.get("/presets/new", response_class=HTMLResponse)
def new_preset(request: Request):
    return templates.TemplateResponse(
        name="preset_form.html",
        request=request,
        context={
            "mode": "new",
            "preset": None,
            "action": "/presets",
            "error": "",
        },
    )


@app.post("/presets")
def create_preset(
    preset_id: str = Form(...),
    label: str = Form(...),
    category: str = Form(""),
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
    use_gpu: str | None = Form(None),
    gpu_task: str = Form("none"),
    cable_channels: int = Form(1),
    cable_diameter_mm: float = Form(6.0),
    magnet_diameter_mm: float = Form(10.0),
    magnet_thickness_mm: float = Form(2.0),
    hinge_count: int = Form(3),
    clearance_mm: float = Form(0.3),
):
    db = get_db()
    try:
        data = preset_form_to_data(
            label=label,
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
            support_allowed=support_allowed,
            printer_targets=printer_targets,
            use_gpu=use_gpu,
            gpu_task=gpu_task,
            cable_channels=cable_channels,
            cable_diameter_mm=cable_diameter_mm,
            magnet_diameter_mm=magnet_diameter_mm,
            magnet_thickness_mm=magnet_thickness_mm,
            hinge_count=hinge_count,
            clearance_mm=clearance_mm,
        )
        data["id"] = preset_id
        create_preset_record(db, ProductPreset, data)
        db.commit()
        return RedirectResponse(url="/presets", status_code=303)
    finally:
        db.close()


@app.get("/presets/{preset_id}/edit", response_class=HTMLResponse)
def edit_preset_form(request: Request, preset_id: str):
    db = get_db()
    try:
        preset = get_preset_or_404(db, ProductPreset, preset_id)
        return templates.TemplateResponse(
            name="preset_form.html",
            request=request,
            context={
                "mode": "edit",
                "preset": preset,
                "action": f"/presets/{preset.id}/edit",
                "error": "",
            },
        )
    finally:
        db.close()


@app.post("/presets/{preset_id}/edit")
def edit_preset(
    preset_id: str,
    label: str = Form(...),
    category: str = Form(""),
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
    use_gpu: str | None = Form(None),
    gpu_task: str = Form("none"),
    cable_channels: int = Form(1),
    cable_diameter_mm: float = Form(6.0),
    magnet_diameter_mm: float = Form(10.0),
    magnet_thickness_mm: float = Form(2.0),
    hinge_count: int = Form(3),
    clearance_mm: float = Form(0.3),
):
    db = get_db()
    try:
        preset = get_preset_or_404(db, ProductPreset, preset_id)
        data = preset_form_to_data(
            label=label,
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
            support_allowed=support_allowed,
            printer_targets=printer_targets,
            use_gpu=use_gpu,
            gpu_task=gpu_task,
            cable_channels=cable_channels,
            cable_diameter_mm=cable_diameter_mm,
            magnet_diameter_mm=magnet_diameter_mm,
            magnet_thickness_mm=magnet_thickness_mm,
            hinge_count=hinge_count,
            clearance_mm=clearance_mm,
        )
        update_preset_record(preset, data)
        db.commit()
        return RedirectResponse(url="/presets", status_code=303)
    finally:
        db.close()


@app.post("/presets/{preset_id}/delete")
def delete_preset(preset_id: str):
    db = get_db()
    try:
        preset = get_preset_or_404(db, ProductPreset, preset_id)
        deactivate_preset(preset)
        db.commit()
        return RedirectResponse(url="/presets", status_code=303)
    finally:
        db.close()


@app.get("/products/new", response_class=HTMLResponse)
def new_product(request: Request):
    db = get_db()
    try:
        return templates.TemplateResponse(
            name="new_product.html",
            request=request,
            context={
                "presets": active_preset_dicts(db, include_custom=True),
            },
        )
    finally:
        db.close()


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

        md_path = write_product_md(product, product_base_dir(product.id))
        run_number = get_next_run_number(product.id, PRODUCTS_DATA_ROOT)
        output_dir = run_dir_for(product.id, run_number)
        write_run_metadata_file(
            product_id=product.id,
            run_number=run_number,
            output_dir=output_dir,
            product_md_path=Path(product_container_base_dir(product.id)) / "input" / "product.md",
            image=WORKER_IMAGE,
            use_gpu=bool(product.use_gpu),
            gpu_task=product.gpu_task or "none",
            trigger="create",
        )

        db.add(ProductFile(
            id=str(uuid.uuid4()),
            product_id=product.id,
            file_type="product_md",
            file_name="product.md",
            file_path=str(md_path),
        ))

        try:
            job_name = create_blender_job(
                product_id=product.id,
                product_md_path=f"{product_container_base_dir(product.id)}/input/product.md",
                output_dir=run_container_dir_for(product.id, run_number),
                image=WORKER_IMAGE,
                namespace=NAMESPACE,
                use_gpu=bool(product.use_gpu),
                gpu_task=product.gpu_task or "none",
                run_number=run_number,
                trigger="create",
                pvc_name=PVC_NAME,
            )

            db.add(GenerationJob(
                id=str(uuid.uuid4()),
                product_id=product.id,
                k8s_job_name=job_name,
                status="QUEUED",
                run_number=run_number,
                output_dir=run_container_dir_for(product.id, run_number),
            ))

            product.status = "QUEUED"

        except Exception as e:
            db.add(GenerationJob(
                id=str(uuid.uuid4()),
                product_id=product.id,
                k8s_job_name=None,
                status="FAILED",
                error_message=repr(e),
                run_number=run_number,
                output_dir=run_container_dir_for(product.id, run_number),
            ))

            product.status = "FAILED"

        db.commit()

        return RedirectResponse(url=f"/products/{product_id}", status_code=303)
    finally:
        db.close()


@app.get("/products/{product_id}/edit", response_class=HTMLResponse)
def edit_product_form(request: Request, product_id: str):
    db = get_db()
    try:
        product = db.query(ProductRequest).filter(ProductRequest.id == product_id).first()
        if not product:
            raise HTTPException(status_code=404, detail="Product not found")

        return templates.TemplateResponse(
            name="edit_product.html",
            request=request,
            context={
                "product": product,
                "presets": active_preset_dicts(db, include_custom=True),
            },
        )
    finally:
        db.close()


@app.post("/products/{product_id}/edit")
def edit_product(
    product_id: str,
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
        product = db.query(ProductRequest).filter(ProductRequest.id == product_id).first()
        if not product:
            raise HTTPException(status_code=404, detail="Product not found")

        update_product_from_form(
            product=product,
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
            support_allowed=support_allowed,
            cable_channels=cable_channels,
            cable_diameter_mm=cable_diameter_mm,
            magnet_diameter_mm=magnet_diameter_mm,
            magnet_thickness_mm=magnet_thickness_mm,
            hinge_count=hinge_count,
            clearance_mm=clearance_mm,
            printer_targets=printer_targets,
            use_gpu=use_gpu,
            gpu_task=gpu_task,
        )
        product.status = "MD_CREATED"

        write_product_md(product, product_base_dir(product.id))
        run_number = get_next_run_number(product.id, PRODUCTS_DATA_ROOT)
        output_dir = run_dir_for(product.id, run_number)
        write_run_metadata_file(
            product_id=product.id,
            run_number=run_number,
            output_dir=output_dir,
            product_md_path=Path(product_container_base_dir(product.id)) / "input" / "product.md",
            image=WORKER_IMAGE,
            use_gpu=bool(product.use_gpu),
            gpu_task=product.gpu_task or "none",
            trigger="edit",
        )

        try:
            job_name = create_blender_job(
                product_id=product.id,
                product_md_path=f"{product_container_base_dir(product.id)}/input/product.md",
                output_dir=run_container_dir_for(product.id, run_number),
                image=WORKER_IMAGE,
                namespace=NAMESPACE,
                use_gpu=bool(product.use_gpu),
                gpu_task=product.gpu_task or "none",
                run_number=run_number,
                trigger="edit",
                pvc_name=PVC_NAME,
            )

            db.add(GenerationJob(
                id=str(uuid.uuid4()),
                product_id=product.id,
                k8s_job_name=job_name,
                status="QUEUED",
                run_number=run_number,
                output_dir=run_container_dir_for(product.id, run_number),
            ))

            product.status = "QUEUED"
        except Exception as e:
            db.add(GenerationJob(
                id=str(uuid.uuid4()),
                product_id=product.id,
                k8s_job_name=None,
                status="FAILED",
                error_message=repr(e),
                run_number=run_number,
                output_dir=run_container_dir_for(product.id, run_number),
            ))

            product.status = "FAILED"

        product.updated_at = datetime.utcnow()
        db.commit()

        return RedirectResponse(url=f"/products/{product_id}", status_code=303)
    finally:
        db.close()


@app.get("/products/{product_id}/compare", response_class=HTMLResponse)
def compare_product_runs(request: Request, product_id: str):
    db = get_db()
    try:
        product = db.query(ProductRequest).filter(ProductRequest.id == product_id).first()
        if not product:
            raise HTTPException(status_code=404, detail="Product not found")

        available = list_run_numbers(product_id, PRODUCTS_DATA_ROOT)
        selected, warnings = parse_run_selection(request.query_params.get("runs"), available)
        compare_runs = collect_compare_runs(product_id, selected)

        return templates.TemplateResponse(
            name="product_compare.html",
            request=request,
            context={
                "product": product,
                "available_runs": list(reversed(available)),
                "selected_runs": selected,
                "compare_runs": compare_runs,
                "warnings": warnings,
            },
        )
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
                        try:
                            size = f.stat().st_size
                        except OSError:
                            continue
                        files.append({
                            "subdir": subdir,
                            "name": f.name,
                            "size": size,
                            "download_url": f"/products/{product_id}/download/{subdir}/{f.name}",
                        })

        jobs = db.query(GenerationJob).filter(
            GenerationJob.product_id == product_id
        ).order_by(GenerationJob.created_at.desc()).all()

        debug_texts, validation_status = collect_debug_texts(product_id)
        runs = build_run_summaries(product_id, data_root=PRODUCTS_DATA_ROOT)

        return templates.TemplateResponse(
            name="product_detail.html",
            request=request,
            context={
                "product": product,
                "files": files,
                "jobs": jobs,
                "debug_texts": debug_texts,
                "validation_status": validation_status,
                "runs": runs,
            },
        )
    finally:
        db.close()


@app.get("/products/{product_id}/download/{subdir}/{filename}")
def download_file(product_id: str, subdir: str, filename: str):
    if subdir not in ["input", "output", "logs"]:
        raise HTTPException(status_code=400, detail="Invalid subdir")
    if filename != Path(filename).name:
        raise HTTPException(status_code=400, detail="Invalid filename")

    try:
        path = product_base_dir(product_id) / subdir / filename
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid product_id")

    if not path.exists():
        raise HTTPException(status_code=404, detail="File not found")

    return FileResponse(path, filename=filename)


@app.get("/products/{product_id}/download/runs/{run_number}/{filename}")
def download_run_file(product_id: str, run_number: int, filename: str):
    if run_number < 1:
        raise HTTPException(status_code=400, detail="Invalid run number")
    if filename != Path(filename).name:
        raise HTTPException(status_code=400, detail="Invalid filename")

    try:
        path = run_dir_for(product_id, run_number) / filename
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid path")

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

        run_number = get_next_run_number(product.id, PRODUCTS_DATA_ROOT)
        output_dir = run_dir_for(product.id, run_number)
        write_run_metadata_file(
            product_id=product.id,
            run_number=run_number,
            output_dir=output_dir,
            product_md_path=Path(product_container_base_dir(product.id)) / "input" / "product.md",
            image=WORKER_IMAGE,
            use_gpu=bool(product.use_gpu),
            gpu_task=product.gpu_task or "none",
            trigger="rerun",
        )

        try:
            job_name = create_blender_job(
                product_id=product.id,
                product_md_path=f"{product_container_base_dir(product.id)}/input/product.md",
                output_dir=run_container_dir_for(product.id, run_number),
                image=WORKER_IMAGE,
                namespace=NAMESPACE,
                use_gpu=bool(product.use_gpu),
                gpu_task=product.gpu_task or "none",
                run_number=run_number,
                trigger="rerun",
                pvc_name=PVC_NAME,
            )

            db.add(GenerationJob(
                id=str(uuid.uuid4()),
                product_id=product.id,
                k8s_job_name=job_name,
                status="QUEUED",
                run_number=run_number,
                output_dir=run_container_dir_for(product.id, run_number),
            ))

            product.status = "QUEUED"
        except Exception as e:
            db.add(GenerationJob(
                id=str(uuid.uuid4()),
                product_id=product.id,
                status="FAILED",
                error_message=repr(e),
                run_number=run_number,
                output_dir=run_container_dir_for(product.id, run_number),
            ))

            product.status = "FAILED"

        db.commit()

        return RedirectResponse(url=f"/products/{product_id}", status_code=303)
    finally:
        db.close()
