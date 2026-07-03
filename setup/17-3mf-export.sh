#!/usr/bin/env bash
set -euo pipefail

# 17-3mf-export.sh
#
# Adds 3MF export support to 3D Model Factory.
#
# Goals:
#   - Export model.3mf from Blender if supported by installed Blender version.
#   - Keep STL/BLEND/preview flow intact even if 3MF export fails.
#   - Add slicer_notes.md with Bambu Studio oriented guidance.
#   - Show 3MF availability in README and output_status.txt.
#
# Applies to:
#   /ai/tashkent/3d-model-factory

ENV_FILE="/ai/tashkent/3d-model-factory/.factory.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "[ERROR] ${ENV_FILE} not found."
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

mkdir -p "${ROOT}/scripts"

cp "${ROOT}/scripts/generate_blender_script.py" "${ROOT}/scripts/generate_blender_script.py.bak.3mf.$(date +%Y%m%d%H%M%S)" || true
cp "${ROOT}/scripts/create_report.py" "${ROOT}/scripts/create_report.py.bak.3mf.$(date +%Y%m%d%H%M%S)" || true

echo "[INFO] Patch generate_blender_script.py to add 3MF export"

python3 - <<'PY'
from pathlib import Path

path = Path("/ai/tashkent/3d-model-factory/scripts/generate_blender_script.py")
text = path.read_text(encoding="utf-8")

if 'three_mf_path = str(run_dir / "model.3mf")' in text:
    print("[INFO] 3MF export already appears to be patched")
else:
    # Insert 3MF path after preview_path.
    text = text.replace(
        'preview_path = str(run_dir / "preview.png")\n',
        'preview_path = str(run_dir / "preview.png")\nthree_mf_path = str(run_dir / "model.3mf")\n'
    )

    # Insert 3MF export after BLEND save.
    old = 'bpy.ops.wm.save_as_mainfile(filepath=blend_path)\n\npreview_status = "not_rendered"\n'
    new = '''bpy.ops.wm.save_as_mainfile(filepath=blend_path)

three_mf_status = "not_exported"
try:
    if hasattr(bpy.ops.wm, "usd_export"):
        # Not used for final output, but checking modern exporter availability helps diagnostics.
        pass

    if hasattr(bpy.ops.wm, "export_3mf"):
        bpy.ops.wm.export_3mf(filepath=three_mf_path)
        three_mf_status = "exported:wm.export_3mf"
    elif hasattr(bpy.ops.export_mesh, "threemf"):
        bpy.ops.export_mesh.threemf(filepath=three_mf_path)
        three_mf_status = "exported:export_mesh.threemf"
    elif hasattr(bpy.ops.export_scene, "threemf"):
        bpy.ops.export_scene.threemf(filepath=three_mf_path)
        three_mf_status = "exported:export_scene.threemf"
    else:
        three_mf_status = "unsupported:blender_3mf_operator_not_found"
except Exception as e:
    three_mf_status = "failed:" + repr(e)
    print("[WARN] 3MF export failed:", repr(e))

preview_status = "not_rendered"
'''
    if old not in text:
        raise SystemExit("[ERROR] Could not find BLEND save marker. Please inspect generate_blender_script.py.")
    text = text.replace(old, new)

    # Add 3MF status to output_status.
    text = text.replace(
        '    "preview_status=" + preview_status,\n',
        '    "preview_status=" + preview_status,\n    "three_mf_path=" + three_mf_path,\n    "three_mf_status=" + three_mf_status,\n'
    )

    # Add log line.
    text = text.replace(
        'print("[INFO] BLEND saved:", blend_path)\n',
        'print("[INFO] BLEND saved:", blend_path)\nprint("[INFO] 3MF status:", three_mf_status)\n'
    )

path.write_text(text, encoding="utf-8")
print("[DONE] generate_blender_script.py patched for 3MF")
PY

echo "[INFO] Patch create_report.py to include 3MF and slicer notes"

cat > "${ROOT}/scripts/create_report.py" <<'PY'
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
product_md = Path(sys.argv[2]) if len(sys.argv) >= 3 and sys.argv[2] else None

validation_file = run_dir / "validation.txt"
metadata_file = run_dir / "design_metadata.txt"
status_file = run_dir / "output_status.txt"

validation_text = validation_file.read_text(encoding="utf-8") if validation_file.exists() else "No validation result."
metadata_text = metadata_file.read_text(encoding="utf-8") if metadata_file.exists() else "No design metadata."
status_text = status_file.read_text(encoding="utf-8") if status_file.exists() else "No output status."

product_md_text = ""
if product_md and product_md.exists():
    product_md_text = product_md.read_text(encoding="utf-8", errors="ignore")

preview_exists = (run_dir / "preview.png").exists()
three_mf_exists = (run_dir / "model.3mf").exists()

# Bambu Studio oriented slicer notes.
material = "PETG"
for line in metadata_text.splitlines():
    if line.startswith("material="):
        material = line.split("=", 1)[1].strip() or material

slicer_lines = [
    "# Slicer Notes",
    "",
    "## Recommended Import Order",
    "",
    "1. Open `model.3mf` in Bambu Studio if it exists.",
    "2. If `model.3mf` is not available, import `model.stl`.",
    "3. Check orientation and scale in millimeters.",
    "4. Slice with the material profile matching the selected filament.",
    "",
    "## Suggested Bambu Studio Settings",
    "",
    "| Item | Value |",
    "|---|---|",
    f"| Material | {material} |",
    "| Nozzle | 0.4mm |",
    "| Layer Height | 0.20mm |",
    "| Wall Loops | 3 |",
    "| Top Shell Layers | 4 |",
    "| Bottom Shell Layers | 4 |",
    "| Infill | 15% Gyroid or Grid |",
    "| Support | Off by default; enable only when overhangs require it |",
    "| Brim | Optional for narrow/tall models |",
    "",
    "## Fit / Tolerance Notes",
    "",
    "- M3 clearance holes are generated as approximately 3.4mm holes.",
    "- For tight printers/materials, drill or ream holes after print if needed.",
    "- PETG may need slightly more clearance than PLA.",
    "",
]
(run_dir / "slicer_notes.md").write_text("\n".join(slicer_lines), encoding="utf-8")

lines = [
    "# 3D Model Report",
    "",
    "## Generation Result",
    "",
    "| File | Description |",
    "|---|---|",
    "| model.stl | 3D printable STL |",
    "| model.blend | Blender source file |",
    "| model.3mf | 3MF model for Bambu Studio |" if three_mf_exists else "| model.3mf | Not generated or unsupported by current Blender |",
    "| preview.png | Rendered preview image |" if preview_exists else "| preview.png | Not generated |",
    "| validation.txt | Mesh validation report |",
    "| design_metadata.txt | Parsed design metadata |",
    "| output_status.txt | Export/render diagnostic status |",
    "| slicer_notes.md | Bambu Studio slicing guidance |",
    "| README.md | Product report |",
    "",
    "## Output Status",
    "",
    status_text,
    "",
    "## Design Metadata",
    "",
    metadata_text,
    "",
    "## Recommended Print Settings",
    "",
    "| Item | Value |",
    "|---|---|",
    f"| Material | {material} |",
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
    "Open `model.3mf` in Bambu Studio if it exists.",
    "If 3MF is not generated, open `model.stl` instead.",
    "Use `preview.png` for quick visual inspection.",
    "",
])

readme_path = run_dir / "README.md"
readme_path.write_text("\n".join(lines), encoding="utf-8")

print("[INFO] README created:", readme_path)
print("[INFO] slicer_notes.md created:", run_dir / "slicer_notes.md")
PY

python3 -m py_compile "${ROOT}/scripts/generate_blender_script.py"
python3 -m py_compile "${ROOT}/scripts/create_report.py"

echo "[DONE] 3MF export patch completed"
echo ""
echo "Next commands:"
echo "  cd ${ROOT}"
echo "  make build && make push"
echo ""
echo "Then create a new product and check:"
echo "  model.3mf"
echo "  slicer_notes.md"
echo "  output_status.txt"
