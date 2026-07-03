#!/usr/bin/env bash
set -euo pipefail

# 19-shape-specific-engine.sh
#
# Purpose:
#   Replace the overly-generic Blender generator with a shape/preset-specific generator.
#
# This patch adds distinct geometry strategies:
#   - bambu_a1_nozzle_holder: tray + nozzle wells
#   - bambu_scraper_holder: slanted back plate + scraper slot + M3 holes
#   - m3_wall_hook: back plate + hook arm + retainer lip + M3 holes
#   - cable_clip_small: U-shaped cable clip with adhesive base
#   - homelab_label_holder: long label rail / nameplate holder
#   - battery_case_2cell: two-cell battery tray with divider
#   - generic fallback: uses shape keywords

ENV_FILE="/ai/tashkent/3d-model-factory/.factory.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "[ERROR] ${ENV_FILE} not found."
  exit 1
fi

source "${ENV_FILE}"

GEN="${ROOT}/scripts/generate_blender_script.py"

if [ ! -f "${GEN}" ]; then
  echo "[ERROR] generate_blender_script.py not found: ${GEN}"
  exit 1
fi

cp "${GEN}" "${GEN}.bak.shape-engine.$(date +%Y%m%d%H%M%S)"

cat > "${GEN}" <<'PY'
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
preset_id = find_value(md, "Preset ID", "custom")
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

width = max(30.0, min(width, 240.0))
depth = max(15.0, min(depth, 180.0))
height = max(8.0, min(height, 140.0))

shape_lower = shape.lower()
mount_lower = mount_type.lower()
wants_m3 = ("m3" in mount_lower) or ("bolt" in mount_lower) or ("볼트" in mount_lower) or ("나사" in mount_lower)

if preset_id and preset_id != "custom":
    design_profile = preset_id
elif "nozzle" in name.lower() or "노즐" in name:
    design_profile = "bambu_a1_nozzle_holder"
elif "scraper" in name.lower() or "스크래퍼" in name:
    design_profile = "bambu_scraper_holder"
elif "label" in name.lower() or "라벨" in name:
    design_profile = "homelab_label_holder"
elif "battery" in name.lower() or "배터리" in name:
    design_profile = "battery_case_2cell"
elif "clip" in shape_lower or "클립" in shape_lower:
    design_profile = "cable_clip_small"
elif "hook" in shape_lower or "걸이" in mount_lower:
    design_profile = "m3_wall_hook"
elif "box" in shape_lower or "case" in shape_lower or "박스" in shape_lower or "케이스" in shape_lower:
    design_profile = "generic_box"
else:
    design_profile = "generic_holder"

base_thickness = max(3.2, min(height * 0.18, 6.0))
wall_thickness = 3.0
bevel_amount = 1.5

blender_script = f'''
import bpy
import sys
import math
from pathlib import Path

argv = sys.argv
run_dir = Path(argv[argv.index("--") + 1])

PRODUCT = {{
    "name": {name!r},
    "category": {category!r},
    "preset_id": {preset_id!r},
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
    "wants_m3": {wants_m3!r},
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
mat_light = make_mat("accent_light", (0.75, 0.75, 0.75, 1.0))
mat_cut = make_mat("cut_visual", (0.25, 0.25, 0.25, 1.0))

def add_cube(name, location, dimensions, material=None, bevel=0):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = dimensions
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if material:
        obj.data.materials.append(material)
    if bevel > 0:
        mod = obj.modifiers.new(name="bevel", type="BEVEL")
        mod.width = bevel
        mod.segments = 4
        mod.affect = "EDGES"
        obj.modifiers.new(name="weighted_normals", type="WEIGHTED_NORMAL")
    return obj

def add_cylinder(name, location, radius, depth, material=None, vertices=64, rotation=(0,0,0)):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    if material:
        obj.data.materials.append(material)
    obj.modifiers.new(name="weighted_normals", type="WEIGHTED_NORMAL")
    return obj

def add_text(name, text, location, size, material=None, rotation=(0,0,0)):
    bpy.ops.object.text_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.data.body = text
    obj.data.align_x = "CENTER"
    obj.data.align_y = "CENTER"
    obj.data.size = size
    obj.data.extrude = 0.35
    if material:
        obj.data.materials.append(material)
    return obj

def boolean_difference(target, cutter, apply=True):
    mod = target.modifiers.new(name="bool_cut_" + cutter.name, type="BOOLEAN")
    mod.operation = "DIFFERENCE"
    mod.object = cutter
    try:
        mod.solver = "FAST"
    except Exception:
        pass
    bpy.context.view_layer.objects.active = target
    target.select_set(True)
    if apply:
        try:
            bpy.ops.object.modifier_apply(modifier=mod.name)
            bpy.data.objects.remove(cutter, do_unlink=True)
        except Exception as e:
            print("[WARN] boolean apply failed:", target.name, cutter.name, repr(e))
    return mod

def add_m3_holes(base, w, z_center, plate_thickness, y=0):
    hole_report = []
    positions = [(-w * 0.30, y), (w * 0.30, y)]
    for idx, (x, yy) in enumerate(positions, start=1):
        through = add_cylinder("m3_clearance_cutter_" + str(idx), (x, yy, z_center), 1.7, plate_thickness + 3.0, None, 72)
        boolean_difference(base, through, apply=True)
        recess = add_cylinder("m3_counterbore_cutter_" + str(idx), (x, yy, z_center + plate_thickness / 2 - 0.65), 3.1, 1.4, None, 72)
        boolean_difference(base, recess, apply=True)
        add_cylinder("m3_hole_ring_" + str(idx), (x, yy, z_center + plate_thickness / 2 + 0.08), 3.3, 0.15, mat_light, 72)
        hole_report.append("M3 clearance hole " + str(idx) + ": diameter=3.4mm")
    return hole_report

def add_surface_grid(w, d, z):
    for i in range(5):
        x = -w * 0.35 + i * (w * 0.7 / 4)
        add_cube("surface_grid_x_" + str(i), (x, 0, z), (0.7, d * 0.75, 0.45), mat_light, 0)
    for j in range(3):
        y = -d * 0.25 + j * (d * 0.5 / 2)
        add_cube("surface_grid_y_" + str(j), (0, y, z + 0.05), (w * 0.75, 0.7, 0.45), mat_light, 0)

w = PRODUCT["width"]
d = PRODUCT["depth"]
h = PRODUCT["height"]
base_t = {base_thickness!r}
wall_t = {wall_thickness!r}
bevel = {bevel_amount!r}
profile = PRODUCT["design_profile"]
hole_report = []

def gen_nozzle_holder():
    base = add_cube("nozzle_holder_base", (0, 0, base_t/2), (w, d, base_t), mat_default, bevel)
    lip_h = min(max(h * 0.38, 8), 16)
    add_cube("rear_wall", (0, d/2-wall_t/2, base_t+lip_h/2), (w, wall_t, lip_h), mat_default, bevel)
    add_cube("left_side_wall", (-w/2+wall_t/2, 0, base_t+lip_h/2), (wall_t, d, lip_h), mat_default, bevel)
    add_cube("right_side_wall", (w/2-wall_t/2, 0, base_t+lip_h/2), (wall_t, d, lip_h), mat_default, bevel)
    add_cube("front_low_lip", (0, -d/2+wall_t/2, base_t+4), (w, wall_t, 8), mat_default, bevel)
    count = 6
    usable_w = w - 18
    for i in range(count):
        x = -usable_w/2 + i * usable_w/(count-1)
        cutter = add_cylinder("nozzle_well_cutter_" + str(i+1), (x, -d*0.08, base_t+1.0), 4.2, 3.0, None, 64)
        boolean_difference(base, cutter, apply=True)
        add_cylinder("nozzle_well_ring_" + str(i+1), (x, -d*0.08, base_t+0.15), 4.8, 0.25, mat_light, 64)
    add_text("label_nozzle", "NOZZLES", (0, -d*0.35, base_t+0.65), 5, mat_light)
    return ["nozzle_wells=6", "profile=nozzle_holder"]

def gen_scraper_holder():
    base = add_cube("scraper_base", (0, 0, base_t/2), (w, d, base_t), mat_default, bevel)
    back = add_cube("slanted_back_plate", (0, d/2-wall_t/2, h/2), (w, wall_t, h), mat_default, bevel)
    back.rotation_euler[0] = math.radians(-8)
    slot_w = w * 0.72
    slot_d = 5.5
    slot_h = min(max(h * 0.55, 18), h-4)
    add_cube("scraper_thin_slot_visual", (0, d*0.08, base_t+slot_h/2), (slot_w, slot_d, slot_h), mat_light, 0.8)
    add_cube("front_stop_left", (-w*0.35, -d/2+wall_t, base_t+8), (w*0.18, wall_t*1.2, 12), mat_default, bevel)
    add_cube("front_stop_right", (w*0.35, -d/2+wall_t, base_t+8), (w*0.18, wall_t*1.2, 12), mat_default, bevel)
    hole_report.extend(add_m3_holes(base, w, base_t/2, base_t, y=0))
    add_text("label_scraper", "SCRAPER", (0, -d*0.28, base_t+0.65), 5, mat_light)
    return ["scraper_slot=yes", "slanted_back_plate=yes"]

def gen_wall_hook():
    back_t = max(wall_t, 4)
    back = add_cube("wall_back_plate", (0, d/2-back_t/2, h/2), (w, back_t, h), mat_default, bevel)
    hole_report.extend(add_m3_holes(back, w, h/2, h, y=d/2-back_t/2))
    shelf_len = max(d*0.75, 28)
    add_cube("hook_main_arm", (0, -shelf_len/4, h*0.36), (w*0.72, shelf_len, base_t*1.3), mat_default, bevel)
    add_cube("hook_front_lip", (0, -shelf_len/2, h*0.36+8), (w*0.72, wall_t*1.2, 16), mat_default, bevel)
    add_cube("lower_gusset_left", (-w*0.24, d*0.05, h*0.22), (wall_t*1.5, d*0.55, h*0.35), mat_default, bevel)
    add_cube("lower_gusset_right", (w*0.24, d*0.05, h*0.22), (wall_t*1.5, d*0.55, h*0.35), mat_default, bevel)
    add_text("label_hook", "HOOK", (0, d/2-back_t-0.1, h*0.78), 5, mat_light, rotation=(math.radians(90),0,0))
    return ["wall_hook=yes", "gussets=2"]

def gen_cable_clip():
    base = add_cube("adhesive_base", (0, 0, base_t/2), (w, d, base_t), mat_default, bevel)
    channel_w = max(w * 0.48, 18)
    wall_h = max(h-base_t, 10)
    add_cube("clip_left_finger", (-channel_w/2, 0, base_t+wall_h/2), (wall_t*1.5, d*0.75, wall_h), mat_default, bevel)
    add_cube("clip_right_finger", (channel_w/2, 0, base_t+wall_h/2), (wall_t*1.5, d*0.75, wall_h), mat_default, bevel)
    add_cube("clip_top_retainer_left", (-channel_w/2+wall_t*1.5, 0, base_t+wall_h-wall_t/2), (wall_t*2.3, d*0.65, wall_t), mat_default, bevel)
    add_cube("clip_top_retainer_right", (channel_w/2-wall_t*1.5, 0, base_t+wall_h-wall_t/2), (wall_t*2.3, d*0.65, wall_t), mat_default, bevel)
    add_cube("adhesive_pad_marker", (0, 0, base_t+0.18), (w*0.75, d*0.55, 0.3), mat_light, 0.5)
    add_text("label_cable", "CABLE", (0, -d*0.34, base_t+0.65), 4, mat_light)
    return ["u_clip_channel=yes", "adhesive_base=yes"]

def gen_label_holder():
    base = add_cube("label_backing_plate", (0, 0, base_t/2), (w, d, base_t), mat_default, bevel)
    rail_h = max(h*0.40, 5)
    add_cube("top_label_rail", (0, d*0.28, base_t+rail_h/2), (w*0.95, wall_t, rail_h), mat_default, bevel)
    add_cube("bottom_label_rail", (0, -d*0.28, base_t+rail_h/2), (w*0.95, wall_t, rail_h), mat_default, bevel)
    add_cube("label_insert_area", (0, 0, base_t+0.2), (w*0.80, d*0.32, 0.35), mat_light, 0.5)
    add_cube("left_end_stop", (-w/2+wall_t, 0, base_t+rail_h/2), (wall_t*1.2, d*0.75, rail_h), mat_default, bevel)
    add_cube("right_end_stop", (w/2-wall_t, 0, base_t+rail_h/2), (wall_t*1.2, d*0.75, rail_h), mat_default, bevel)
    add_text("label_text", "LABEL", (0, 0, base_t+0.8), 6, mat_cut)
    return ["label_rails=2", "insert_area=yes"]

def gen_battery_case():
    base = add_cube("battery_case_base", (0, 0, base_t/2), (w, d, base_t), mat_default, bevel)
    wall_h = max(h-base_t, 10)
    add_cube("battery_back_wall", (0, d/2-wall_t/2, base_t+wall_h/2), (w, wall_t, wall_h), mat_default, bevel)
    add_cube("battery_front_lip", (0, -d/2+wall_t/2, base_t+min(wall_h, 8)/2), (w, wall_t, min(wall_h, 8)), mat_default, bevel)
    add_cube("battery_left_wall", (-w/2+wall_t/2, 0, base_t+wall_h/2), (wall_t, d, wall_h), mat_default, bevel)
    add_cube("battery_right_wall", (w/2-wall_t/2, 0, base_t+wall_h/2), (wall_t, d, wall_h), mat_default, bevel)
    add_cube("battery_center_divider", (0, 0, base_t+wall_h*0.40), (wall_t, d*0.82, wall_h*0.8), mat_default, bevel)
    for i, x in enumerate([-w*0.23, w*0.23], start=1):
        add_cylinder("battery_seat_groove_" + str(i), (x, 0, base_t+1.0), min(d*0.22, 7), 2.0, mat_light, 64, rotation=(math.radians(90),0,0))
    add_text("label_2cell", "2 CELL", (0, -d*0.36, base_t+0.65), 5, mat_light)
    return ["battery_slots=2", "center_divider=yes"]

def gen_generic_box():
    add_cube("generic_box_base", (0, 0, base_t/2), (w, d, base_t), mat_default, bevel)
    wall_h = max(h-base_t, 10)
    add_cube("box_back_wall", (0, d/2-wall_t/2, base_t+wall_h/2), (w, wall_t, wall_h), mat_default, bevel)
    add_cube("box_front_lip", (0, -d/2+wall_t/2, base_t+min(wall_h, 10)/2), (w, wall_t, min(wall_h, 10)), mat_default, bevel)
    add_cube("box_left_wall", (-w/2+wall_t/2, 0, base_t+wall_h/2), (wall_t, d, wall_h), mat_default, bevel)
    add_cube("box_right_wall", (w/2-wall_t/2, 0, base_t+wall_h/2), (wall_t, d, wall_h), mat_default, bevel)
    return ["generic_box=yes"]

def gen_generic_holder():
    add_cube("generic_holder_base", (0, 0, base_t/2), (w, d, base_t), mat_default, bevel)
    rail_h = max(h*0.45, 10)
    add_cube("holder_left_rail", (-w/2+wall_t/2, 0, base_t+rail_h/2), (wall_t, d, rail_h), mat_default, bevel)
    add_cube("holder_right_rail", (w/2-wall_t/2, 0, base_t+rail_h/2), (wall_t, d, rail_h), mat_default, bevel)
    add_cube("holder_back_stop", (0, d/2-wall_t/2, base_t+rail_h/2), (w, wall_t, rail_h), mat_default, bevel)
    return ["generic_holder=yes"]

profile_map = {{
    "bambu_a1_nozzle_holder": gen_nozzle_holder,
    "bambu_scraper_holder": gen_scraper_holder,
    "m3_wall_hook": gen_wall_hook,
    "cable_clip_small": gen_cable_clip,
    "homelab_label_holder": gen_label_holder,
    "battery_case_2cell": gen_battery_case,
    "generic_box": gen_generic_box,
    "generic_holder": gen_generic_holder,
}}

extra_report = profile_map.get(profile, gen_generic_holder)()

if "grid" in PRODUCT["surface"].lower() or "격자" in PRODUCT["surface"].lower():
    add_surface_grid(w, d, base_t + 0.28)

metadata_lines = [
    "name=" + PRODUCT["name"],
    "category=" + PRODUCT["category"],
    "preset_id=" + PRODUCT["preset_id"],
    "shape=" + PRODUCT["shape"],
    "surface=" + PRODUCT["surface"],
    "color=" + PRODUCT["color"],
    "material=" + PRODUCT["material"],
    "mount_type=" + PRODUCT["mount_type"],
    "support_allowed=" + str(PRODUCT["support_allowed"]),
    "width_mm=" + str(PRODUCT["width"]),
    "depth_mm=" + str(PRODUCT["depth"]),
    "height_mm=" + str(PRODUCT["height"]),
    "base_thickness_mm=" + str(base_t),
    "wall_thickness_mm=" + str(wall_t),
    "bevel_mm=" + str(bevel),
    "design_profile=" + PRODUCT["design_profile"],
    "gpu_enabled=" + str(PRODUCT["gpu_enabled"]),
    "gpu_task=" + PRODUCT["gpu_task"],
    "boolean_holes=" + ("yes" if hole_report else "no"),
]
metadata_lines.extend(hole_report)
metadata_lines.extend(extra_report)

metadata_path = run_dir / "design_metadata.txt"
metadata_path.write_text("\\n".join(metadata_lines), encoding="utf-8")

bpy.ops.object.light_add(type="AREA", location=(0, -140, 170))
light = bpy.context.object
light.name = "preview_area_light"
light.data.energy = 550
light.data.size = 85

bpy.ops.object.camera_add(location=(w * 0.85, -max(d * 2.8, 95), max(h * 1.8, 65)), rotation=(1.1, 0, 0.42))
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
        for backend in ["OPTIX", "CUDA"]:
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

preview_status = "not_rendered"
try:
    bpy.context.scene.render.filepath = preview_path
    bpy.ops.render.render(write_still=True)
    preview_status = "rendered:" + render_mode
    print("[INFO] Preview rendered:", preview_path, "mode:", render_mode)
except Exception as e:
    preview_status = "failed:" + repr(e)
    print("[WARN] Preview render failed:", repr(e))

status_path = run_dir / "output_status.txt"
status_path.write_text("\\n".join([
    "stl_path=" + stl_path,
    "blend_path=" + blend_path,
    "preview_path=" + preview_path,
    "preview_status=" + preview_status,
    "render_mode=" + render_mode,
    "design_profile=" + PRODUCT["design_profile"],
    "boolean_holes=" + ("yes" if hole_report else "no"),
]), encoding="utf-8")

print("[INFO] Product:", PRODUCT["name"])
print("[INFO] Preset:", PRODUCT["preset_id"])
print("[INFO] Profile:", PRODUCT["design_profile"])
print("[INFO] Dimensions:", w, d, h)
print("[INFO] Boolean holes:", "yes" if hole_report else "no")
print("[INFO] Render mode:", render_mode)
print("[INFO] STL exported:", stl_path)
print("[INFO] BLEND saved:", blend_path)
'''

Path("/workspace/blender/generated_model.py").write_text(blender_script, encoding="utf-8")

print("[INFO] Blender script generated from product.md")
print(f"[INFO] name={name}")
print(f"[INFO] category={category}")
print(f"[INFO] preset_id={preset_id}")
print(f"[INFO] shape={shape}")
print(f"[INFO] material={material}")
print(f"[INFO] dimensions={width} x {depth} x {height} mm")
print(f"[INFO] gpu_enabled={gpu_enabled}")
print(f"[INFO] gpu_task={gpu_task}")
print(f"[INFO] design_profile={design_profile}")
print(f"[INFO] wants_m3={wants_m3}")
PY

python3 -m py_compile "${GEN}"

echo "[DONE] Shape-specific engine patch completed"
echo ""
echo "Next commands:"
echo "  cd ${ROOT}"
echo "  make build && make push"
echo ""
echo "Then create new products from different presets and compare preview.png/model.stl."
