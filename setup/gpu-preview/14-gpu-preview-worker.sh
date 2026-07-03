#!/usr/bin/env bash
set -euo pipefail

# 14-gpu-preview-worker.sh
#
# Adds optional GPU preview rendering to the 3D Model Factory.
#
# Summary:
# - Adds DB columns: use_gpu, gpu_task
# - Rewrites portal templates with GPU fields
# - Patches portal main.py to pass GPU options to worker Job
# - Rewrites worker generate_blender_script.py to render preview.png
# - GPU is optional. If selected, Job requests nvidia.com/gpu: 1.
# - Blender tries CUDA/OPTIX and falls back to CPU/Eevee if unavailable.

ENV_FILE="/ai/tashkent/3d-model-factory/.factory.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "[ERROR] ${ENV_FILE} not found."
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

MAIN="${ROOT}/portal/app/main.py"

if [ ! -f "${MAIN}" ]; then
  echo "[ERROR] main.py not found: ${MAIN}"
  exit 1
fi

mkdir -p "${ROOT}/portal/app/templates"
mkdir -p "${ROOT}/scripts"
mkdir -p "${ROOT}/k8s"

cp "${MAIN}" "${MAIN}.bak.gpu.$(date +%Y%m%d%H%M%S)" || true
cp "${ROOT}/scripts/generate_blender_script.py" "${ROOT}/scripts/generate_blender_script.py.bak.gpu.$(date +%Y%m%d%H%M%S)" || true
cp "${ROOT}/scripts/create_report.py" "${ROOT}/scripts/create_report.py.bak.gpu.$(date +%Y%m%d%H%M%S)" || true

echo "[INFO] Patch DB schema"
kubectl exec -n "${NAMESPACE}" postgresql-0 -- \
  psql -U model_factory -d model_factory -c "
ALTER TABLE product_requests
  ADD COLUMN IF NOT EXISTS use_gpu BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS gpu_task VARCHAR DEFAULT 'none';
" || echo "[WARN] DB schema patch failed. Check postgresql-0 status."

echo "[INFO] Patch portal main.py"
python3 - <<'PY'
from pathlib import Path

main = Path("/ai/tashkent/3d-model-factory/portal/app/main.py")
text = main.read_text(encoding="utf-8")

# ProductRequest model columns
if "use_gpu = Column" not in text:
    marker = "    support_allowed = Column(Boolean, default=False)\n"
    if marker not in text:
        raise SystemExit("[ERROR] support_allowed model marker not found")
    text = text.replace(
        marker,
        marker + "    use_gpu = Column(Boolean, default=False)\n    gpu_task = Column(String, default=\"none\")\n"
    )

# Form arguments
if "use_gpu: str | None = Form(None)" not in text and "use_gpu: Optional[str] = Form(None)" not in text:
    marker = "    printer_targets: list[str] = Form([]),\n"
    if marker not in text:
        marker = "    printer_targets: List[str] = Form([]),\n"
    if marker not in text:
        raise SystemExit("[ERROR] printer_targets marker not found")
    text = text.replace(
        marker,
        marker + "    use_gpu: str | None = Form(None),\n    gpu_task: str = Form(\"none\"),\n"
    )

# ProductRequest constructor assignment
if "use_gpu=(use_gpu == \"true\")" not in text:
    marker = "            support_allowed=(support_allowed == \"true\"),\n"
    if marker not in text:
        raise SystemExit("[ERROR] support_allowed assignment marker not found")
    text = text.replace(
        marker,
        marker + "            use_gpu=(use_gpu == \"true\"),\n            gpu_task=gpu_task,\n"
    )

# product.md write lines
if "GPU Enabled:" not in text:
    marker = '        f"- Support Allowed: {product.support_allowed}",\n'
    if marker not in text:
        raise SystemExit("[ERROR] product.md support marker not found")
    text = text.replace(
        marker,
        marker + '        f"- GPU Enabled: {product.use_gpu}",\n        f"- GPU Task: {product.gpu_task or \'none\'}",\n'
    )

# create_blender_job signature and local product object
if "def create_blender_job(product_id: str, product_obj=None)" not in text:
    text = text.replace(
        "def create_blender_job(product_id: str) -> str:\n",
        "def create_blender_job(product_id: str, product_obj=None) -> str:\n    current_product_for_job = product_obj\n"
    )

# calls
text = text.replace("job_name = create_blender_job(product.id)", "job_name = create_blender_job(product.id, product)")

# Env block
if 'client.V1EnvVar(name="USE_GPU"' not in text:
    old = '''        env=[
            client.V1EnvVar(name="PRODUCT_ID", value=product_id),
            client.V1EnvVar(name="PRODUCT_MD", value=f"/data/products/{product_id}/input/product.md"),
            client.V1EnvVar(name="OUTPUT_DIR", value=f"/data/products/{product_id}/output"),
        ],
'''
    new = '''        env=[
            client.V1EnvVar(name="PRODUCT_ID", value=product_id),
            client.V1EnvVar(name="PRODUCT_MD", value=f"/data/products/{product_id}/input/product.md"),
            client.V1EnvVar(name="OUTPUT_DIR", value=f"/data/products/{product_id}/output"),
            client.V1EnvVar(name="USE_GPU", value="true" if getattr(current_product_for_job, "use_gpu", False) else "false"),
            client.V1EnvVar(name="GPU_TASK", value=getattr(current_product_for_job, "gpu_task", "none") or "none"),
        ],
'''
    if old not in text:
        raise SystemExit("[ERROR] container env block not found")
    text = text.replace(old, new)

# Resources
if "nvidia.com/gpu" not in text:
    marker = '        image_pull_policy="Always",\n'
    if marker not in text:
        raise SystemExit("[ERROR] image_pull_policy marker not found")
    text = text.replace(
        marker,
        marker + '''        resources=client.V1ResourceRequirements(
            requests={"cpu": "1", "memory": "2Gi"},
            limits=({"cpu": "4", "memory": "8Gi", "nvidia.com/gpu": "1"} if getattr(current_product_for_job, "use_gpu", False) else {"cpu": "4", "memory": "8Gi"}),
        ),
'''
    )

main.write_text(text, encoding="utf-8")
print("[DONE] main.py patched")
PY

python3 -m py_compile "${MAIN}"

echo "[INFO] Rewrite templates"

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
    <input name="shape" placeholder="둥근 사각형, clip, box, hook holder">

    <label>색상</label>
    <input name="color" placeholder="검정, 흰색, 투명">

    <label>표면</label>
    <input name="surface" placeholder="무광, grid matte, 로고 음각">

    <label>재료</label>
    <select name="material">
      <option value="PLA">PLA</option>
      <option value="PETG" selected>PETG</option>
      <option value="ASA">ASA</option>
      <option value="ABS">ABS</option>
      <option value="TPU">TPU</option>
    </select>

    <label>고정 방식</label>
    <input name="mount_type" placeholder="hook, M3 bolt, 자석">

    <label>
      <input type="checkbox" name="support_allowed" value="true">
      서포트 허용
    </label>

    <label>
      <input type="checkbox" name="use_gpu" value="true">
      GPU Preview 렌더링 사용
    </label>

    <label>GPU 작업</label>
    <select name="gpu_task">
      <option value="none">사용 안 함</option>
      <option value="preview">Preview 렌더링</option>
      <option value="ai_design">AI 디자인 보조</option>
      <option value="preview,ai_design">Preview + AI 디자인 보조</option>
    </select>

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
    <tr><th>GPU 사용</th><td>{{ product.use_gpu }}</td></tr>
    <tr><th>GPU 작업</th><td>{{ product.gpu_task }}</td></tr>
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

echo "[INFO] Rewrite worker generate_blender_script.py"

cat > "${ROOT}/scripts/generate_blender_script.py" <<'PY'
import os
import re
import sys
from pathlib import Path


def read_md(path: str) -> str:
    if not path:
        return ""
    p = Path(path)
    if not p.exists():
        print(f"[WARN] PRODUCT_MD not found: {p}")
        return ""
    return p.read_text(encoding="utf-8", errors="ignore")


def find_value(md: str, key: str, default: str = "") -> str:
    patterns = [
        rf"^- {re.escape(key)}:\s*(.+)$",
        rf"^\|\s*{re.escape(key)}\s*\|\s*(.+?)\s*\|$",
    ]
    for pattern in patterns:
        m = re.search(pattern, md, re.IGNORECASE | re.MULTILINE)
        if m:
            return m.group(1).strip()
    return default


def find_number(md: str, key: str, default: float) -> float:
    value = find_value(md, key, "")
    m = re.search(r"[-+]?\d+(\.\d+)?", value)
    if m:
        return float(m.group(0))
    return default


def bool_value(value: str) -> bool:
    return str(value).strip().lower() in ["true", "yes", "y", "1", "allowed", "허용"]


run_dir = Path(sys.argv[1])
product_md_path = sys.argv[2] if len(sys.argv) >= 3 else ""
md = read_md(product_md_path)

name = find_value(md, "Name", "Auto Generated Product")
category = find_value(md, "Category", "bambu_accessory")
description = find_value(md, "Description", "")
shape = find_value(md, "Shape", "rounded rectangular holder")
surface = find_value(md, "Surface", "matte")
color = find_value(md, "Color", "black")
material = find_value(md, "Material", "PETG")
mount_type = find_value(md, "Mount Type", "hook")
support_allowed = bool_value(find_value(md, "Support Allowed", "false"))

gpu_enabled = os.environ.get("USE_GPU", "false").lower() == "true"
gpu_task = os.environ.get("GPU_TASK", "none")

width = find_number(md, "Width", 80.0)
depth = find_number(md, "Depth", 35.0)
height = find_number(md, "Height", 25.0)

width = max(30.0, min(width, 220.0))
depth = max(15.0, min(depth, 160.0))
height = max(8.0, min(height, 120.0))

base_thickness = max(3.0, min(height * 0.18, 6.0))
wall_thickness = 3.0
bevel_amount = 1.5

design_profile = "holder"
shape_lower = shape.lower()
mount_lower = mount_type.lower()

if "clip" in shape_lower or "클립" in shape_lower:
    design_profile = "clip"
elif "box" in shape_lower or "case" in shape_lower or "박스" in shape_lower or "케이스" in shape_lower:
    design_profile = "box"
elif "hook" in mount_lower or "걸이" in mount_lower:
    design_profile = "hook_holder"

script = f'''
import bpy
import sys
from pathlib import Path

argv = sys.argv
run_dir = Path(argv[argv.index("--") + 1])

PRODUCT = {{
    "name": {name!r},
    "category": {category!r},
    "description": {description!r},
    "shape": {shape!r},
    "surface": {surface!r},
    "color": {color!r},
    "material": {material!r},
    "mount_type": {mount_type!r},
    "support_allowed": {support_allowed!r},
    "width": {width!r},
    "depth": {depth!r},
    "height": {height!r},
    "design_profile": {design_profile!r},
    "gpu_enabled": {gpu_enabled!r},
    "gpu_task": {gpu_task!r},
}}

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete()

bpy.context.scene.unit_settings.system = "METRIC"
bpy.context.scene.unit_settings.scale_length = 0.001

def make_mat(name, rgba):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = rgba
    return mat

mat_default = make_mat("recommended_" + PRODUCT["material"], (0.05, 0.05, 0.05, 1.0))
mat_marker = make_mat("marker_light", (0.75, 0.75, 0.75, 1.0))

def add_cube(name, location, dimensions, material=None, bevel=0):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = dimensions
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if material:
        obj.data.materials.append(material)
    if bevel > 0:
        mod = obj.modifiers.new(name="small_bevel", type="BEVEL")
        mod.width = bevel
        mod.segments = 4
        mod.affect = "EDGES"
        obj.modifiers.new(name="weighted_normals", type="WEIGHTED_NORMAL")
    return obj

def add_cylinder(name, location, radius, depth, material=None, vertices=48):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=location)
    obj = bpy.context.object
    obj.name = name
    if material:
        obj.data.materials.append(material)
    obj.modifiers.new(name="weighted_normals", type="WEIGHTED_NORMAL")
    return obj

def add_text(name, text, location, size, material=None):
    bpy.ops.object.text_add(location=location, rotation=(0, 0, 0))
    obj = bpy.context.object
    obj.name = name
    obj.data.body = text
    obj.data.align_x = "CENTER"
    obj.data.align_y = "CENTER"
    obj.data.size = size
    obj.data.extrude = 0.4
    if material:
        obj.data.materials.append(material)
    return obj

w = PRODUCT["width"]
d = PRODUCT["depth"]
h = PRODUCT["height"]
base_t = {base_thickness!r}
wall_t = {wall_thickness!r}
bevel = {bevel_amount!r}
profile = PRODUCT["design_profile"]

add_cube("base_plate", (0, 0, base_t / 2), (w, d, base_t), mat_default, bevel)

if profile == "clip":
    wall_h = max(h - base_t, 10)
    gap = max(d * 0.45, 8)
    side_x = w * 0.32
    add_cube("left_wall", (-side_x, 0, base_t + wall_h / 2), (wall_t * 2, gap, wall_h), mat_default, bevel)
    add_cube("right_wall", (side_x, 0, base_t + wall_h / 2), (wall_t * 2, gap, wall_h), mat_default, bevel)
    add_cube("top_bridge", (0, 0, base_t + wall_h + wall_t / 2), (side_x * 2 + wall_t * 2, gap, wall_t), mat_default, bevel)
elif profile == "box":
    wall_h = max(h - base_t, 10)
    add_cube("back_wall", (0, d / 2 - wall_t / 2, base_t + wall_h / 2), (w, wall_t, wall_h), mat_default, bevel)
    add_cube("front_lip", (0, -d / 2 + wall_t / 2, base_t + min(wall_h, 10) / 2), (w, wall_t, min(wall_h, 10)), mat_default, bevel)
    add_cube("left_wall", (-w / 2 + wall_t / 2, 0, base_t + wall_h / 2), (wall_t, d, wall_h), mat_default, bevel)
    add_cube("right_wall", (w / 2 - wall_t / 2, 0, base_t + wall_h / 2), (wall_t, d, wall_h), mat_default, bevel)
elif profile == "hook_holder":
    add_cube("vertical_back_plate", (0, d / 2 - wall_t / 2, h / 2), (w, wall_t, h), mat_default, bevel)
    hook_depth = max(d * 0.6, 15)
    add_cube("lower_hook_shelf", (0, -hook_depth / 4, base_t + 2), (w * 0.85, hook_depth, base_t), mat_default, bevel)
    add_cube("front_retainer_lip", (0, -hook_depth / 2, base_t + 8), (w * 0.85, wall_t, 12), mat_default, bevel)
else:
    rail_h = max(h * 0.45, 10)
    add_cube("left_rail", (-w / 2 + wall_t / 2, 0, base_t + rail_h / 2), (wall_t, d, rail_h), mat_default, bevel)
    add_cube("right_rail", (w / 2 - wall_t / 2, 0, base_t + rail_h / 2), (wall_t, d, rail_h), mat_default, bevel)
    add_cube("back_stop", (0, d / 2 - wall_t / 2, base_t + rail_h / 2), (w, wall_t, rail_h), mat_default, bevel)

mount = PRODUCT["mount_type"].lower()
if "m3" in mount or "bolt" in mount or "볼트" in mount:
    add_cylinder("m3_marker_left", (-w * 0.3, 0, base_t + 0.4), 2.0, 0.8, mat_marker)
    add_cylinder("m3_marker_right", (w * 0.3, 0, base_t + 0.4), 2.0, 0.8, mat_marker)

if "grid" in PRODUCT["surface"].lower() or "격자" in PRODUCT["surface"].lower():
    for i in range(5):
        x = -w * 0.35 + i * (w * 0.7 / 4)
        add_cube("surface_grid_x_" + str(i), (x, 0, base_t + 0.25), (0.7, d * 0.75, 0.5), mat_marker, 0)
    for j in range(3):
        y = -d * 0.25 + j * (d * 0.5 / 2)
        add_cube("surface_grid_y_" + str(j), (0, y, base_t + 0.3), (w * 0.75, 0.7, 0.5), mat_marker, 0)

add_text("product_label", PRODUCT["name"][:18], (0, -d * 0.35, base_t + 0.7), max(min(w / 15, 6), 3), mat_marker)

metadata_path = run_dir / "design_metadata.txt"
metadata_path.write_text("\\n".join([
    "name=" + PRODUCT["name"],
    "category=" + PRODUCT["category"],
    "shape=" + PRODUCT["shape"],
    "surface=" + PRODUCT["surface"],
    "color=" + PRODUCT["color"],
    "material=" + PRODUCT["material"],
    "mount_type=" + PRODUCT["mount_type"],
    "support_allowed=" + str(PRODUCT["support_allowed"]),
    "width_mm=" + str(PRODUCT["width"]),
    "depth_mm=" + str(PRODUCT["depth"]),
    "height_mm=" + str(PRODUCT["height"]),
    "design_profile=" + PRODUCT["design_profile"],
    "gpu_enabled=" + str(PRODUCT["gpu_enabled"]),
    "gpu_task=" + PRODUCT["gpu_task"],
]), encoding="utf-8")

# Preview camera and lighting.
bpy.ops.object.light_add(type="AREA", location=(0, -120, 160))
light = bpy.context.object
light.name = "preview_area_light"
light.data.energy = 500
light.data.size = 80

bpy.ops.object.camera_add(location=(w * 0.8, -d * 2.4, h * 1.6), rotation=(1.1, 0, 0.42))
camera = bpy.context.object
bpy.context.scene.camera = camera

bpy.context.scene.render.resolution_x = 1200
bpy.context.scene.render.resolution_y = 900

render_mode = "CPU"
try:
    bpy.context.scene.render.engine = "CYCLES"
    if PRODUCT["gpu_enabled"]:
        prefs = bpy.context.preferences
        cycles_prefs = prefs.addons["cycles"].preferences
        for backend in ["CUDA", "OPTIX"]:
            try:
                cycles_prefs.compute_device_type = backend
                cycles_prefs.get_devices()
                for device in cycles_prefs.devices:
                    device.use = True
                bpy.context.scene.cycles.device = "GPU"
                render_mode = "GPU:" + backend
                break
            except Exception:
                continue
    bpy.context.scene.cycles.samples = 64
except Exception as e:
    print("[WARN] GPU/Cycles setup failed:", repr(e))
    try:
        bpy.context.scene.render.engine = "BLENDER_EEVEE_NEXT"
    except Exception:
        pass
    render_mode = "CPU_OR_EEVEE"

bpy.ops.object.select_all(action="SELECT")

stl_path = str(run_dir / "model.stl")
blend_path = str(run_dir / "model.blend")
preview_path = str(run_dir / "preview.png")

try:
    bpy.ops.wm.stl_export(filepath=stl_path)
except Exception:
    bpy.ops.export_mesh.stl(filepath=stl_path)

bpy.ops.wm.save_as_mainfile(filepath=blend_path)

try:
    bpy.context.scene.render.filepath = preview_path
    bpy.ops.render.render(write_still=True)
    print("[INFO] Preview rendered:", preview_path, "mode:", render_mode)
except Exception as e:
    print("[WARN] Preview render failed:", repr(e))

print("[INFO] Product:", PRODUCT["name"])
print("[INFO] Profile:", PRODUCT["design_profile"])
print("[INFO] Dimensions:", w, d, h)
print("[INFO] Render mode:", render_mode)
print("[INFO] STL exported:", stl_path)
print("[INFO] BLEND saved:", blend_path)
'''

Path("/workspace/blender/generated_model.py").write_text(script, encoding="utf-8")

print("[INFO] Blender script generated from product.md")
print(f"[INFO] name={name}")
print(f"[INFO] category={category}")
print(f"[INFO] shape={shape}")
print(f"[INFO] material={material}")
print(f"[INFO] dimensions={width} x {depth} x {height} mm")
print(f"[INFO] gpu_enabled={gpu_enabled}")
print(f"[INFO] gpu_task={gpu_task}")
print(f"[INFO] design_profile={design_profile}")
PY

cat > "${ROOT}/scripts/create_report.py" <<'PY'
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
product_md = Path(sys.argv[2]) if len(sys.argv) >= 3 and sys.argv[2] else None

validation_file = run_dir / "validation.txt"
metadata_file = run_dir / "design_metadata.txt"

validation_text = validation_file.read_text(encoding="utf-8") if validation_file.exists() else "No validation result."
metadata_text = metadata_file.read_text(encoding="utf-8") if metadata_file.exists() else "No design metadata."

product_md_text = ""
if product_md and product_md.exists():
    product_md_text = product_md.read_text(encoding="utf-8", errors="ignore")

preview_exists = (run_dir / "preview.png").exists()

lines = [
    "# 3D Model Report",
    "",
    "## Generation Result",
    "",
    "| File | Description |",
    "|---|---|",
    "| model.stl | 3D printable STL |",
    "| model.blend | Blender source file |",
    "| preview.png | Rendered preview image |" if preview_exists else "| preview.png | Not generated |",
    "| validation.txt | Mesh validation report |",
    "| design_metadata.txt | Parsed design metadata |",
    "| README.md | Product report |",
    "",
    "## Design Metadata",
    "",
    metadata_text,
    "",
    "## Recommended Print Settings",
    "",
    "| Item | Value |",
    "|---|---|",
    "| Material | See design_metadata.txt |",
    "| Nozzle | 0.4mm |",
    "| Layer Height | 0.2mm |",
    "| Wall Loop | 3 |",
    "| Infill | 15% |",
    "| Support | Prefer No |",
    "",
    "## Validation",
    "",
    validation_text,
    "",
]

if product_md_text:
    lines.extend([
        "## Original Product Request",
        "",
        product_md_text,
        "",
    ])

lines.extend([
    "## Next Step",
    "",
    "Download model.stl and test slicing in Bambu Studio.",
    "Use preview.png for visual inspection only.",
    "",
])

readme_path = run_dir / "README.md"
readme_path.write_text("\n".join(lines), encoding="utf-8")

print("[INFO] README created:", readme_path)
PY

python3 -m py_compile "${ROOT}/scripts/generate_blender_script.py"
python3 -m py_compile "${ROOT}/scripts/create_report.py"
python3 -m py_compile "${MAIN}"

cat > "${ROOT}/k8s/gpu-test.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
  namespace: model-factory
spec:
  restartPolicy: Never
  containers:
    - name: gpu-test
      image: nvidia/cuda:12.4.1-base-ubuntu22.04
      command: ["nvidia-smi"]
      resources:
        limits:
          nvidia.com/gpu: 1
YAML

echo "[DONE] GPU preview patch completed"
echo ""
echo "Next commands:"
echo "  cd ${ROOT}"
echo "  make portal-build && make portal-push && make portal-restart"
echo "  make build && make push"
echo ""
echo "Optional GPU test:"
echo "  kubectl apply -f k8s/gpu-test.yaml"
echo "  kubectl logs -n ${NAMESPACE} gpu-test"
