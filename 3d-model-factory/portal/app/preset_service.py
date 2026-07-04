from datetime import datetime

from fastapi import HTTPException


DEFAULT_PRINTER_TARGETS = "- Bambu Lab A1\n- Bambu Lab P1S\n- Bambu Lab P2S"


def get_default_presets() -> list[dict]:
    return [
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
            "printer_targets": "",
            "use_gpu": False,
            "gpu_task": "none",
            "cable_channels": 1,
            "cable_diameter_mm": 6.0,
            "magnet_diameter_mm": 10.0,
            "magnet_thickness_mm": 2.0,
            "hinge_count": 3,
            "clearance_mm": 0.3,
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


def _number_or_empty(value):
    if value is None:
        return ""
    return float(value)


def preset_to_dict(preset) -> dict:
    return {
        "id": preset.id,
        "label": preset.label,
        "category": preset.category or "",
        "description": preset.description or "",
        "width_mm": _number_or_empty(preset.width_mm),
        "depth_mm": _number_or_empty(preset.depth_mm),
        "height_mm": _number_or_empty(preset.height_mm),
        "shape": preset.shape or "",
        "color": preset.color or "",
        "surface": preset.surface or "",
        "material": preset.material or "PETG",
        "mount_type": preset.mount_type or "",
        "support_allowed": bool(preset.support_allowed),
        "printer_targets": preset.printer_targets or "",
        "use_gpu": bool(preset.use_gpu),
        "gpu_task": preset.gpu_task or "none",
        "cable_channels": preset.cable_channels or 1,
        "cable_diameter_mm": _number_or_empty(preset.cable_diameter_mm) or 6.0,
        "magnet_diameter_mm": _number_or_empty(preset.magnet_diameter_mm) or 10.0,
        "magnet_thickness_mm": _number_or_empty(preset.magnet_thickness_mm) or 2.0,
        "hinge_count": preset.hinge_count or 3,
        "clearance_mm": _number_or_empty(preset.clearance_mm) or 0.3,
    }


def custom_preset_dict() -> dict:
    return get_default_presets()[0]


def _float_or_none(value):
    if value in (None, ""):
        return None
    return float(value)


def _float_or_default(value, default: float) -> float:
    if value in (None, ""):
        return default
    return float(value)


def _int_or_default(value, default: int) -> int:
    if value in (None, ""):
        return default
    return int(value)


def _checked(value) -> bool:
    return value == "true" or value is True


def _printer_targets(value) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return "\n".join([f"- {target}" for target in value])


def preset_form_to_data(form=None, **kwargs) -> dict:
    if form is not None:
        form_values = dict(form)
        if hasattr(form, "getlist"):
            form_values["printer_targets"] = form.getlist("printer_targets")
        kwargs = {**form_values, **kwargs}

    return {
        "label": kwargs.get("label") or "",
        "category": kwargs.get("category") or "",
        "description": kwargs.get("description") or "",
        "width_mm": _float_or_none(kwargs.get("width_mm")),
        "depth_mm": _float_or_none(kwargs.get("depth_mm")),
        "height_mm": _float_or_none(kwargs.get("height_mm")),
        "shape": kwargs.get("shape") or "",
        "color": kwargs.get("color") or "",
        "surface": kwargs.get("surface") or "",
        "material": kwargs.get("material") or "PETG",
        "mount_type": kwargs.get("mount_type") or "",
        "support_allowed": _checked(kwargs.get("support_allowed")),
        "printer_targets": _printer_targets(kwargs.get("printer_targets")),
        "use_gpu": _checked(kwargs.get("use_gpu")),
        "gpu_task": kwargs.get("gpu_task") or "none",
        "cable_channels": _int_or_default(kwargs.get("cable_channels"), 1),
        "cable_diameter_mm": _float_or_default(kwargs.get("cable_diameter_mm"), 6.0),
        "magnet_diameter_mm": _float_or_default(kwargs.get("magnet_diameter_mm"), 10.0),
        "magnet_thickness_mm": _float_or_default(kwargs.get("magnet_thickness_mm"), 2.0),
        "hinge_count": _int_or_default(kwargs.get("hinge_count"), 3),
        "clearance_mm": _float_or_default(kwargs.get("clearance_mm"), 0.3),
    }


def seed_default_presets(db, ProductPreset) -> None:
    if db.query(ProductPreset).count() > 0:
        return

    for data in get_default_presets():
        if data["id"] == "custom":
            continue
        preset = ProductPreset(id=data["id"], is_active=True)
        update_preset(preset, {
            **data,
            "printer_targets": data.get("printer_targets") or DEFAULT_PRINTER_TARGETS,
            "cable_channels": data.get("cable_channels") or 1,
            "cable_diameter_mm": data.get("cable_diameter_mm") or 6.0,
            "magnet_diameter_mm": data.get("magnet_diameter_mm") or 10.0,
            "magnet_thickness_mm": data.get("magnet_thickness_mm") or 2.0,
            "hinge_count": data.get("hinge_count") or 3,
            "clearance_mm": data.get("clearance_mm") or 0.3,
        })
        db.add(preset)
    db.commit()


def list_active_presets(db, ProductPreset) -> list:
    return db.query(ProductPreset).filter(
        ProductPreset.is_active == True
    ).order_by(ProductPreset.label.asc()).all()


def get_preset_or_404(db, ProductPreset, preset_id: str):
    preset = db.query(ProductPreset).filter(ProductPreset.id == preset_id).first()
    if not preset:
        raise HTTPException(status_code=404, detail="Preset not found")
    return preset


def create_preset(db, ProductPreset, data: dict):
    preset_id = (data.get("id") or "").strip()
    if not preset_id or preset_id == "custom" or "/" in preset_id or "\\" in preset_id:
        raise HTTPException(status_code=400, detail="Invalid preset id")

    existing = db.query(ProductPreset).filter(ProductPreset.id == preset_id).first()
    if existing:
        raise HTTPException(status_code=400, detail="Preset id already exists")

    preset = ProductPreset(id=preset_id, is_active=True)
    update_preset(preset, data)
    db.add(preset)
    return preset


def update_preset(preset, data: dict):
    preset.label = data.get("label") or ""
    preset.category = data.get("category") or ""
    preset.description = data.get("description") or ""
    preset.width_mm = data.get("width_mm")
    preset.depth_mm = data.get("depth_mm")
    preset.height_mm = data.get("height_mm")
    preset.shape = data.get("shape") or ""
    preset.color = data.get("color") or ""
    preset.surface = data.get("surface") or ""
    preset.material = data.get("material") or "PETG"
    preset.mount_type = data.get("mount_type") or ""
    preset.support_allowed = bool(data.get("support_allowed"))
    preset.printer_targets = data.get("printer_targets") or ""
    preset.use_gpu = bool(data.get("use_gpu"))
    preset.gpu_task = data.get("gpu_task") or "none"
    preset.cable_channels = data.get("cable_channels") or 1
    preset.cable_diameter_mm = data.get("cable_diameter_mm") or 6.0
    preset.magnet_diameter_mm = data.get("magnet_diameter_mm") or 10.0
    preset.magnet_thickness_mm = data.get("magnet_thickness_mm") or 2.0
    preset.hinge_count = data.get("hinge_count") or 3
    preset.clearance_mm = data.get("clearance_mm") or 0.3
    preset.is_active = True
    preset.updated_at = datetime.utcnow()
    return preset


def deactivate_preset(preset):
    preset.is_active = False
    preset.updated_at = datetime.utcnow()
    return preset
