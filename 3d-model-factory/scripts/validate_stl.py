import sys
from pathlib import Path

import trimesh

stl_path = Path(sys.argv[1])
report_path = stl_path.parent / "validation.txt"

lines = []

if not stl_path.exists():
    lines.append("status=FAIL")
    lines.append(f"error=STL not found: {stl_path}")
    report_path.write_text("\n".join(lines), encoding="utf-8")
    print("\n".join(lines))
    raise SystemExit(1)

mesh = trimesh.load_mesh(stl_path)

lines.append("status=OK")
lines.append(f"file={stl_path}")
lines.append(f"vertices={len(mesh.vertices)}")
lines.append(f"faces={len(mesh.faces)}")
lines.append(f"is_empty={mesh.is_empty}")
lines.append(f"is_watertight={mesh.is_watertight}")
lines.append(f"is_winding_consistent={mesh.is_winding_consistent}")

try:
    extents = mesh.extents
    lines.append(f"size_x_mm={extents[0]:.3f}")
    lines.append(f"size_y_mm={extents[1]:.3f}")
    lines.append(f"size_z_mm={extents[2]:.3f}")
except Exception as e:
    lines.append(f"size_error={repr(e)}")

try:
    volume = mesh.volume
    area = mesh.area
    lines.append(f"volume_mm3={volume:.3f}")
    lines.append(f"surface_area_mm2={area:.3f}")
except Exception as e:
    lines.append(f"mass_property_error={repr(e)}")

warnings = []

if mesh.is_empty:
    warnings.append("mesh is empty")

if len(mesh.faces) < 12:
    warnings.append("mesh has very few faces")

if not mesh.is_watertight:
    warnings.append("mesh is not watertight; slicer may repair it automatically, but manual review is recommended")

if warnings:
    lines.append("warnings=" + " | ".join(warnings))
else:
    lines.append("warnings=none")

report_path.write_text("\n".join(lines), encoding="utf-8")
print("\n".join(lines))
