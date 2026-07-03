#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/ai/tashkent/3d-model-factory/.factory.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "[ERROR] ${ENV_FILE} not found."
  exit 1
fi

source "${ENV_FILE}"

RUN_FACTORY="${ROOT}/scripts/run_factory.py"
GEN_3MF="${ROOT}/scripts/generate_3mf_from_stl.py"

if [ ! -f "${RUN_FACTORY}" ]; then
  echo "[ERROR] run_factory.py not found: ${RUN_FACTORY}"
  exit 1
fi

mkdir -p "${ROOT}/scripts"

cp "${RUN_FACTORY}" "${RUN_FACTORY}.bak.3mf-runner.$(date +%Y%m%d%H%M%S)" || true

echo "[INFO] Create fallback 3MF exporter"

cat > "${GEN_3MF}" <<'PY'
import sys
import zipfile
from pathlib import Path

import trimesh


def fmt_num(value):
    return f"{float(value):.6f}".rstrip("0").rstrip(".")


def build_model_xml(mesh):
    if isinstance(mesh, trimesh.Scene):
        mesh = trimesh.util.concatenate(tuple(mesh.dump()))

    if not isinstance(mesh, trimesh.Trimesh):
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

    return mesh


def main():
    if len(sys.argv) < 2:
        print("Usage: generate_3mf_from_stl.py <output_dir_or_stl_path>")
        raise SystemExit(2)

    arg = Path(sys.argv[1])

    if arg.is_dir():
        run_dir = arg
        stl_path = run_dir / "model.stl"
        out_path = run_dir / "model.3mf"
        status_path = run_dir / "output_status.txt"
    else:
        stl_path = arg
        out_path = arg.with_suffix(".3mf")
        status_path = arg.parent / "output_status.txt"

    try:
        if not stl_path.exists():
            raise FileNotFoundError(f"STL not found: {stl_path}")

        mesh = write_3mf(stl_path, out_path)

        lines = [
            "",
            "three_mf_status=exported:fallback_trimesh_xml",
            f"three_mf_path={out_path}",
            f"three_mf_vertices={len(mesh.vertices)}",
            f"three_mf_faces={len(mesh.faces)}",
            f"three_mf_watertight={bool(mesh.is_watertight)}",
        ]

        with status_path.open("a", encoding="utf-8") as f:
            f.write("\n".join(lines))
            f.write("\n")

        print("[INFO] 3MF fallback export OK")
        print("[INFO] three_mf_status=exported:fallback_trimesh_xml")
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
        # 3MF 실패가 전체 STL 생성 실패가 되면 안 되므로 0으로 종료
        raise SystemExit(0)


if __name__ == "__main__":
    main()
PY

python3 -m py_compile "${GEN_3MF}"

echo "[INFO] Patch run_factory.py safely"

python3 - <<'PY'
from pathlib import Path

path = Path("/ai/tashkent/3d-model-factory/scripts/run_factory.py")
text = path.read_text(encoding="utf-8")

if "generate_3mf_from_stl.py" in text:
    print("[INFO] run_factory.py already contains generate_3mf_from_stl.py")
    raise SystemExit(0)

fallback_block = '''
# 3MF fallback export.
# Blender builds often do not include a 3MF exporter.
# This reads model.stl and writes a basic standard model.3mf.
# Failure here must not fail the whole Worker job.
subprocess.call([
    "python3",
    "/workspace/scripts/generate_3mf_from_stl.py",
    str(run_dir)
])

'''

# 가장 안정적인 삽입 위치:
# create_report.py 실행 직전에 넣는다.
marker = '''cmd_report = [
    "python3",
    "/workspace/scripts/create_report.py",
    str(run_dir),
]
'''

if marker in text:
    text = text.replace(marker, fallback_block + marker)
else:
    # 다른 run_factory 구조를 위한 fallback:
    # Factory completed 출력 직전에 넣는다.
    marker2 = 'print("[INFO] Factory job completed")'
    if marker2 in text:
        text = text.replace(marker2, fallback_block + marker2)
    else:
        # 마지막 fallback: 파일 맨 끝에 추가
        text = text.rstrip() + "\n\n" + fallback_block + "\n"

path.write_text(text, encoding="utf-8")
print("[DONE] run_factory.py patched safely")
PY

python3 -m py_compile "${RUN_FACTORY}"

echo "[DONE] 3MF fallback runner patch completed"
echo ""
echo "Next:"
echo "  cd ${ROOT}"
echo "  make build"
echo "  make push"
