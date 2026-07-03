#!/usr/bin/env bash
set -euo pipefail

# 18-product-presets.sh
# Adds product presets/templates to the 3D Model Factory portal.

ENV_FILE="/ai/tashkent/3d-model-factory/.factory.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "[ERROR] ${ENV_FILE} not found."
  exit 1
fi

source "${ENV_FILE}"

MAIN="${ROOT}/portal/app/main.py"
NEW_TEMPLATE="${ROOT}/portal/app/templates/new_product.html"
DETAIL_TEMPLATE="${ROOT}/portal/app/templates/product_detail.html"

if [ ! -f "${MAIN}" ]; then
  echo "[ERROR] main.py not found: ${MAIN}"
  exit 1
fi

mkdir -p "${ROOT}/portal/app/templates"

cp "${MAIN}" "${MAIN}.bak.presets.$(date +%Y%m%d%H%M%S)"
cp "${NEW_TEMPLATE}" "${NEW_TEMPLATE}.bak.presets.$(date +%Y%m%d%H%M%S)" || true
cp "${DETAIL_TEMPLATE}" "${DETAIL_TEMPLATE}.bak.presets.$(date +%Y%m%d%H%M%S)" || true

echo "[INFO] Patch DB schema"

kubectl exec -n "${NAMESPACE}" postgresql-0 -- \
  psql -U model_factory -d model_factory -c "
ALTER TABLE product_requests
  ADD COLUMN IF NOT EXISTS preset_id VARCHAR DEFAULT 'custom';
" || echo "[WARN] DB schema patch failed. Check postgresql-0 status."

echo "[INFO] Patch main.py"

python3 - <<'PY'
from pathlib import Path

main = Path("/ai/tashkent/3d-model-factory/portal/app/main.py")
text = main.read_text(encoding="utf-8")

if "JSONResponse" not in text:
    text = text.replace(
        "from fastapi.responses import HTMLResponse, RedirectResponse, FileResponse, PlainTextResponse",
        "from fastapi.responses import HTMLResponse, RedirectResponse, FileResponse, PlainTextResponse, JSONResponse",
    )

if "preset_id = Column" not in text:
    marker = "    category = Column(String, nullable=False)\n"
    if marker not in text:
        raise SystemExit("[ERROR] ProductRequest category marker not found")
    text = text.replace(marker, marker + '    preset_id = Column(String, default="custom")\n')

if 'preset_id: str = Form("custom")' not in text:
    marker = "    name: str = Form(...),\n"
    if marker not in text:
        raise SystemExit("[ERROR] create_product name marker not found")
    text = text.replace(marker, '    preset_id: str = Form("custom"),\n' + marker)

if "preset_id=preset_id" not in text:
    marker = "            id=product_id,\n"
    if marker not in text:
        raise SystemExit("[ERROR] ProductRequest constructor marker not found")
    text = text.replace(marker, marker + "            preset_id=preset_id,\n")

if "Preset ID:" not in text:
    marker = '        f"- Category: {product.category}",\n'
    if marker not in text:
        raise SystemExit("[ERROR] write_product_md category marker not found")
    text = text.replace(marker, marker + '        f"- Preset ID: {product.preset_id or \'custom\'}",\n')

if "PRODUCT_PRESETS =" not in text:
    app_marker = 'app = FastAPI(title="3D Model Factory Portal")\n'
    if app_marker not in text:
        raise SystemExit("[ERROR] FastAPI app marker not found")

    catalog = """
PRODUCT_PRESETS = [
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
        "use_gpu": False,
        "gpu_task": "none",
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
"""
    text = text.replace(app_marker, app_marker + catalog + "\n")

if '@app.get("/api/presets")' not in text:
    endpoint = """
@app.get("/api/presets")
def api_presets():
    return {"presets": PRODUCT_PRESETS}

"""
    marker = '@app.get("/healthz")\n'
    if marker in text:
        text = text.replace(marker, endpoint + marker)
    else:
        text += "\n" + endpoint + "\n"

main.write_text(text, encoding="utf-8")
print("[DONE] main.py patched for presets")
PY

python3 -m py_compile "${MAIN}"

echo "[INFO] Rewrite new_product.html"

cat > "${NEW_TEMPLATE}" <<'HTML'
{% extends "base.html" %}
{% block content %}
<section class="card">
  <h2>새 제품 요청</h2>

  <form method="post" action="/products">
    <label>제품 프리셋</label>
    <select id="preset_selector" name="preset_id">
      <option value="custom">직접 입력</option>
      <option value="bambu_a1_nozzle_holder">Bambu A1 노즐 홀더</option>
      <option value="bambu_scraper_holder">Bambu 스크래퍼 거치대</option>
      <option value="m3_wall_hook">M3 벽걸이 후크</option>
      <option value="cable_clip_small">소형 케이블 클립</option>
      <option value="homelab_label_holder">홈랩/랙 라벨 홀더</option>
      <option value="battery_case_2cell">2셀 배터리 케이스</option>
    </select>

    <p class="hint">프리셋을 선택하면 아래 입력값이 자동으로 채워집니다. 이후 자유롭게 수정할 수 있습니다.</p>

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

<script>
const PRESETS = {
  "custom": { label: "직접 입력", category: "", description: "", width_mm: "", depth_mm: "", height_mm: "", shape: "", color: "", surface: "", material: "PETG", mount_type: "", support_allowed: false, use_gpu: false, gpu_task: "none" },
  "bambu_a1_nozzle_holder": { label: "Bambu A1 노즐 홀더", category: "bambu_accessory", description: "Bambu Lab A1 주변에 둘 수 있는 소형 노즐/소모품 홀더", width_mm: 95, depth_mm: 45, height_mm: 28, shape: "box tray", color: "black", surface: "grid matte", material: "PETG", mount_type: "desktop", support_allowed: false, use_gpu: true, gpu_task: "preview" },
  "bambu_scraper_holder": { label: "Bambu 스크래퍼 거치대", category: "bambu_accessory", description: "스크래퍼 또는 얇은 공구를 세워 보관하는 거치대", width_mm: 110, depth_mm: 38, height_mm: 42, shape: "hook holder", color: "black", surface: "matte", material: "PETG", mount_type: "M3 bolt", support_allowed: false, use_gpu: true, gpu_task: "preview" },
  "m3_wall_hook": { label: "M3 벽걸이 후크", category: "desk_organizer", description: "M3 볼트 2개로 고정하는 범용 벽걸이 후크", width_mm: 80, depth_mm: 42, height_mm: 35, shape: "hook holder", color: "black", surface: "matte", material: "PETG", mount_type: "M3 bolt", support_allowed: false, use_gpu: true, gpu_task: "preview" },
  "cable_clip_small": { label: "소형 케이블 클립", category: "cable_management", description: "USB-C, 전원선 등 얇은 케이블을 정리하는 클립", width_mm: 55, depth_mm: 24, height_mm: 18, shape: "clip", color: "black", surface: "matte", material: "PETG", mount_type: "adhesive", support_allowed: false, use_gpu: false, gpu_task: "none" },
  "homelab_label_holder": { label: "홈랩/랙 라벨 홀더", category: "homelab_accessory", description: "서버, 스위치, 케이블 앞단에 붙이는 라벨 홀더", width_mm: 120, depth_mm: 22, height_mm: 16, shape: "rounded rectangular holder", color: "white", surface: "matte", material: "PLA", mount_type: "adhesive", support_allowed: false, use_gpu: false, gpu_task: "none" },
  "battery_case_2cell": { label: "2셀 배터리 케이스", category: "battery_case", description: "소형 배터리 2개를 보관하는 단순 오픈 트레이 케이스", width_mm: 72, depth_mm: 38, height_mm: 18, shape: "box case", color: "black", surface: "grid matte", material: "PETG", mount_type: "none", support_allowed: false, use_gpu: true, gpu_task: "preview" }
};

function setField(name, value) {
  const el = document.querySelector(`[name="${name}"]`);
  if (!el) return;
  if (el.type === "checkbox") {
    el.checked = Boolean(value);
  } else {
    el.value = value ?? "";
  }
}

function applyPreset(id) {
  const p = PRESETS[id] || PRESETS["custom"];
  if (id !== "custom") setField("name", p.label);
  setField("category", p.category || "bambu_accessory");
  setField("description", p.description);
  setField("width_mm", p.width_mm);
  setField("depth_mm", p.depth_mm);
  setField("height_mm", p.height_mm);
  setField("shape", p.shape);
  setField("color", p.color);
  setField("surface", p.surface);
  setField("material", p.material || "PETG");
  setField("mount_type", p.mount_type);
  setField("support_allowed", p.support_allowed);
  setField("use_gpu", p.use_gpu);
  setField("gpu_task", p.gpu_task || "none");
}

document.getElementById("preset_selector").addEventListener("change", function(e) {
  applyPreset(e.target.value);
});
</script>
{% endblock %}
HTML

echo "[INFO] Patch product detail page"

python3 - <<'PY'
from pathlib import Path

detail = Path("/ai/tashkent/3d-model-factory/portal/app/templates/product_detail.html")
text = detail.read_text(encoding="utf-8")

if "프리셋" not in text:
    marker = "    <tr><th>카테고리</th><td>{{ product.category }}</td></tr>\n"
    if marker in text:
        text = text.replace(marker, marker + "    <tr><th>프리셋</th><td>{{ product.preset_id }}</td></tr>\n")
    else:
        print("[WARN] category row not found in product_detail.html")

detail.write_text(text, encoding="utf-8")
print("[DONE] product_detail.html patched")
PY

python3 -m py_compile "${MAIN}"

echo "[DONE] Product presets patch completed"
echo ""
echo "Next commands:"
echo "  cd ${ROOT}"
echo "  make portal-build && make portal-push && make portal-restart"
echo ""
echo "Check:"
echo "  http://<NODE_IP>:30083/products/new"
echo "  http://<NODE_IP>:30083/api/presets"
