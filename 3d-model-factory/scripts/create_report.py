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
