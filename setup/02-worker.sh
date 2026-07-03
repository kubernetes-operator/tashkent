#!/usr/bin/env bash
set -euo pipefail

source /ai/tashkent/3d-model-factory/.factory.env

mkdir -p "${ROOT}/docker/blender-worker"
mkdir -p "${ROOT}/scripts"
mkdir -p "${ROOT}/blender"

cat > "${ROOT}/docker/blender-worker/requirements.txt" <<'REQ'
pyyaml
trimesh
numpy
openai
REQ

cat > "${ROOT}/docker/blender-worker/Dockerfile" <<'DOCKERFILE'
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    blender \
    python3 \
    python3-pip \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY docker/blender-worker/requirements.txt /workspace/requirements.txt
RUN pip3 install --break-system-packages -r /workspace/requirements.txt

COPY scripts /workspace/scripts
COPY prompts /workspace/prompts
COPY blender /workspace/blender

CMD ["python3", "/workspace/scripts/run_factory.py"]
DOCKERFILE

cat > "${ROOT}/scripts/run_factory.py" <<'PY'
import os
import subprocess
from datetime import datetime
from pathlib import Path

output_dir = Path(os.environ.get("OUTPUT_DIR", "/data"))
run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
run_dir = output_dir / run_id

run_dir.mkdir(parents=True, exist_ok=True)

print(f"[INFO] RUN_ID={run_id}")
print(f"[INFO] OUTPUT_DIR={run_dir}")

subprocess.check_call([
    "python3",
    "/workspace/scripts/generate_blender_script.py",
    str(run_dir)
])

subprocess.check_call([
    "blender",
    "--background",
    "--python",
    "/workspace/blender/generated_model.py",
    "--",
    str(run_dir)
])

subprocess.check_call([
    "python3",
    "/workspace/scripts/validate_stl.py",
    str(run_dir / "model.stl")
])

subprocess.check_call([
    "python3",
    "/workspace/scripts/create_report.py",
    str(run_dir)
])

print("[INFO] Factory job completed")
PY

cat > "${ROOT}/scripts/generate_blender_script.py" <<'PY'
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])

script = r'''
import bpy
import sys
from pathlib import Path

argv = sys.argv
run_dir = Path(argv[argv.index("--") + 1])

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete()

def add_cube(name, location, dimensions):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = dimensions
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return obj

base = add_cube(
    "base_plate",
    location=(0, 0, 2),
    dimensions=(60, 22, 4)
)

left_wall = add_cube(
    "left_wall",
    location=(-18, 0, 11),
    dimensions=(6, 10, 18)
)

right_wall = add_cube(
    "right_wall",
    location=(18, 0, 11),
    dimensions=(6, 10, 18)
)

top_bridge = add_cube(
    "top_bridge",
    location=(0, 0, 21),
    dimensions=(42, 10, 4)
)

add_cube(
    "m3_marker_left",
    location=(-22, 0, 4.5),
    dimensions=(5, 5, 1)
)

add_cube(
    "m3_marker_right",
    location=(22, 0, 4.5),
    dimensions=(5, 5, 1)
)

bpy.ops.object.select_all(action="SELECT")

stl_path = str(run_dir / "model.stl")
blend_path = str(run_dir / "model.blend")

try:
    bpy.ops.wm.stl_export(filepath=stl_path)
except Exception:
    bpy.ops.export_mesh.stl(filepath=stl_path)

bpy.ops.wm.save_as_mainfile(filepath=blend_path)

print("[INFO] STL exported:", stl_path)
print("[INFO] BLEND saved:", blend_path)
'''

Path("/workspace/blender/generated_model.py").write_text(script, encoding="utf-8")

print("[INFO] Blender script generated")
print(f"[INFO] Target run dir: {run_dir}")
PY

cat > "${ROOT}/scripts/validate_stl.py" <<'PY'
import sys
from pathlib import Path
import trimesh

stl = Path(sys.argv[1])

if not stl.exists():
    raise FileNotFoundError(stl)

mesh = trimesh.load(str(stl), force="mesh")

report = []
report.append(f"file: {stl}")
report.append(f"vertices: {len(mesh.vertices)}")
report.append(f"faces: {len(mesh.faces)}")
report.append(f"is_watertight: {mesh.is_watertight}")
report.append(f"bounds: {mesh.bounds.tolist()}")
report.append(f"volume: {mesh.volume}")

report_path = stl.parent / "validation.txt"
report_path.write_text("\n".join(report), encoding="utf-8")

print("[INFO] STL validation report created")
print("\n".join(report))
PY

cat > "${ROOT}/scripts/create_report.py" <<'PY'
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])

validation_file = run_dir / "validation.txt"

if validation_file.exists():
    validation_text = validation_file.read_text(encoding="utf-8")
else:
    validation_text = "No validation result."

lines = [
    "# 3D Model Report",
    "",
    "## Product",
    "",
    "Bambu Cable Clip Test Model",
    "",
    "## Output Files",
    "",
    "| File | Description |",
    "|---|---|",
    "| model.stl | 3D printable STL |",
    "| model.blend | Blender source file |",
    "| validation.txt | Mesh validation report |",
    "| README.md | Product report |",
    "",
    "## Printer Compatibility",
    "",
    "| Printer | Target |",
    "|---|---|",
    "| Bambu Lab A1 | Yes |",
    "| Bambu Lab P1S | Yes |",
    "| Bambu Lab P2S | Yes |",
    "",
    "## Recommended Print Settings",
    "",
    "| Item | Value |",
    "|---|---|",
    "| Material | PLA / PETG |",
    "| Nozzle | 0.4mm |",
    "| Layer Height | 0.2mm |",
    "| Wall Loop | 3 |",
    "| Infill | 15% |",
    "| Support | No |",
    "",
    "## Validation",
    "",
    validation_text,
    "",
    "## Next Step",
    "",
    "Download model.stl and test slicing in Bambu Studio.",
    ""
]

readme_path = run_dir / "README.md"
readme_path.write_text("\n".join(lines), encoding="utf-8")

print("[INFO] README created:", readme_path)
PY

python3 -m py_compile "${ROOT}/scripts/run_factory.py"
python3 -m py_compile "${ROOT}/scripts/generate_blender_script.py"
python3 -m py_compile "${ROOT}/scripts/validate_stl.py"
python3 -m py_compile "${ROOT}/scripts/create_report.py"

echo "[DONE] 02-worker completed"
