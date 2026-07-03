#!/usr/bin/env bash
set -euo pipefail

# 17b-fix-3mf-fallback-exporter.sh
#
# Fixes 3MF generation when Blender does not provide bpy.ops.wm.export_3mf.
#
# Why:
#   Many Blender builds do not include a working 3MF export operator.
#   The previous patch attempted bpy.ops.wm.export_3mf and may log:
#     AttributeError('Calling operator "bpy.ops.wm.export_3mf" error, could not be found')
#
# Solution:
#   - Keep Blender STL/BLEND/Preview flow.
#   - Add scripts/generate_3mf_from_stl.py.
#   - Patch run_factory.py to run the fallback exporter after validate_stl.py.
#   - The fallback writes a basic but valid 3MF package:
#       model.3mf
#       [Content_Types].xml
#       _rels/.rels
#       3D/3dmodel.model
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

RUN_FACTORY="${ROOT}/scripts/run_factory.py"
GEN_3MF="${ROOT}/scripts/generate_3mf_from_stl.py"

if [ ! -f "${RUN_FACTORY}" ]; then
  echo "[ERROR] run_factory.py not found: ${RUN_FACTORY}"
  exit 1
fi

cp "${RUN_FACTORY}" "${RUN_FACTORY}.bak.3mf-fallback.$(date +%Y%m%d%H%M%S)" || true

echo "[INFO] Create fallback 3MF exporter"

cat > "${GEN_3MF}" <<'PY'
import sys
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

import trimesh


def fmt_num(value):
    # 3MF accepts decimal values. Keep compact but precise enough for mm units.
    return f"{float(value):.6f}".rstrip("0").rstrip(".")


def build_model_xml(mesh):
    # Ensure the mesh is a single Trimesh.
    if isinstance(mesh, trimesh.Scene):
        mesh = trimesh.util.concatenate(tuple(mesh.dump()))
    elif not isinstance(mesh, trimesh.Trimesh):
        raise TypeError(f"Unsupported mesh type: {type(mesh)}")

    if mesh.is_empty:
        raise ValueError("Mesh is empty")

    vertices = mesh.vertices
    faces = mesh.faces

    lines = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append('<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">')
    lines.append('  <metadata name="Title">3D Model Factory Export</metadata>')
    lines.append('  <resources>')
    lines.append('    <object id="1" type="model">')
    lines.append('      <mesh>')
    lines.append('        <vertices>')

    for v in vertices:
        lines.append(
            f'          <vertex x="{fmt_num(v[0])}" y="{fmt_num(v[1])}" z="{fmt_num(v[2])}" />'
        )

    lines.append('        </vertices>')
    lines.append('        <triangles>')

    for f in faces:
        lines.append(
            f'          <triangle v1="{int(f[0])}" v2="{int(f[1])}" v3="{int(f[2])}" />'
        )

    lines.append('        </triangles>')
    lines.append('      </mesh>')
    lines.append('    </object>')
    lines.append('  </resources>')
    lines.append('  <build>')
    lines.append('    <item objectid="1" />')
    lines.append('  </build>')
    lines.append('</model>')

    return "\n".join(lines)


def write_3mf(stl_path: Path, out_path: Path):
    mesh = trimesh.load_mesh(stl_path, force="mesh")

    model_xml = build_model_xml(mesh)

    content_types = '''<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml" />
  <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml" />
</Types>
'''

    rels = '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel" />
</Relationships>
'''

    out_path.parent.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", content_types)
        zf.writestr("_rels/.rels", rels)
        zf.writestr("3D/3dmodel.model", model_xml)

    return {
        "vertices": len(mesh.vertices),
        "faces": len(mesh.faces),
        "watertight": bool(mesh.is_watertight),
        "path": str(out_path),
    }


def main():
    if len(sys.argv) < 2:
        print("Usage: generate_3mf_from_stl.py <output_dir_or_stl_path>")
        raise SystemExit(2)

    arg = Path(sys.argv[1])

    if arg.is_dir():
        stl_path = arg / "model.stl"
        out_path = arg / "model.3mf"
        status_path = arg / "output_status.txt"
    else:
        stl_path = arg
        out_path = arg.with_suffix(".3mf")
        status_path = arg.parent / "output_status.txt"

    try:
        if not stl_path.exists():
            raise FileNotFoundError(f"STL not found: {stl_path}")

        result = write_3mf(stl_path, out_path)

        line = "three_mf_status=exported:fallback_trimesh_xml"
        append_lines = [
            line,
            f"three_mf_path={out_path}",
            f"three_mf_vertices={result['vertices']}",
            f"three_mf_faces={result['faces']}",
            f"three_mf_watertight={result['watertight']}",
        ]

        with status_path.open("a", encoding="utf-8") as f:
            f.write("\n")
            f.write("\n".join(append_lines))
            f.write("\n")

        print("[INFO] 3MF fallback export OK")
        print("[INFO]", line)
        print("[INFO] three_mf_path=", out_path)

    except Exception as e:
        fail_line = f"three_mf_status=failed:fallback:{repr(e)}"
        try:
            with status_path.open("a", encoding="utf-8") as f:
                f.write("\n")
                f.write(fail_line)
                f.write("\n")
        except Exception:
            pass

        print("[WARN] 3MF fallback export failed:", repr(e))
        # Do not fail the whole Worker. STL/BLEND are still valid outputs.
        raise SystemExit(0)


if __name__ == "__main__":
    main()
PY

python3 -m py_compile "${GEN_3MF}"

echo "[INFO] Patch run_factory.py to call fallback exporter"

python3 - <<'PY'
from pathlib import Path

path = Path("/ai/tashkent/3d-model-factory/scripts/run_factory.py")
text = path.read_text(encoding="utf-8")

if "generate_3mf_from_stl.py" in text:
    print("[INFO] run_factory.py already calls generate_3mf_from_stl.py")
else:
    marker = '''subprocess.check_call([
    "python3",
    "/workspace/scripts/validate_stl.py",
    str(run_dir / "model.stl")
])

'''
    insert = marker + '''# 3MF fallback export.
# This does not fail the whole job if 3MF generation is unsupported or fails.
subprocess.call([
    "python3",
    "/workspace/scripts/generate_3mf_from_stl.py",
    str(run_dir)
])

'''

    if marker not in text:
        raise SystemExit("[ERROR] validate_stl block not found in run_factory.py")

    text = text.replace(marker, insert)

path.write_text(text, encoding="utf-8")
print("[DONE] run_factory.py patched")
PY

python3 -m py_compile "${RUN_FACTORY}"

echo "[INFO] Patch create_report.py to recognize fallback 3MF"

CREATE_REPORT="${ROOT}/scripts/create_report.py"

if [ -f "${CREATE_REPORT}" ]; then
  cp "${CREATE_REPORT}" "${CREATE_REPORT}.bak.3mf-fallback.$(date +%Y%m%d%H%M%S)" || true

  python3 - <<'PY'
from pathlib import Path

path = Path("/ai/tashkent/3d-model-factory/scripts/create_report.py")
text = path.read_text(encoding="utf-8")

# The current create_report usually checks model.3mf existence already.
# This patch only ensures slicer_notes.md and README naturally include model.3mf.
if "model.3mf" not in text:
    print("[WARN] create_report.py does not mention model.3mf. Leaving as-is.")
else:
    print("[INFO] create_report.py already references model.3mf")

path.write_text(text, encoding="utf-8")
PY

  python3 -m py_compile "${CREATE_REPORT}"
fi

echo "[DONE] 3MF fallback exporter patch completed"
echo ""
echo "Next commands:"
echo "  cd ${ROOT}"
echo "  make build && make push"
echo ""
echo "Then create a new product and check output_status.txt:"
echo "  three_mf_status=exported:fallback_trimesh_xml"
