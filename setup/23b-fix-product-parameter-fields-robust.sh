#!/usr/bin/env bash
set -euo pipefail

# 23b-fix-product-parameter-fields-robust.sh
# Fixes: [ERROR] create_product mount_type marker not found

ENV_FILE="/ai/tashkent/3d-model-factory/.factory.env"
[ -f "$ENV_FILE" ] || { echo "[ERROR] $ENV_FILE not found"; exit 1; }
source "$ENV_FILE"

MAIN="${ROOT}/portal/app/main.py"
NEW_TEMPLATE="${ROOT}/portal/app/templates/new_product.html"
GEN="${ROOT}/scripts/generate_blender_script.py"

[ -f "$MAIN" ] || { echo "[ERROR] $MAIN not found"; exit 1; }
[ -f "$NEW_TEMPLATE" ] || { echo "[ERROR] $NEW_TEMPLATE not found"; exit 1; }
[ -f "$GEN" ] || { echo "[ERROR] $GEN not found"; exit 1; }

cp "$MAIN" "${MAIN}.bak.params23b.$(date +%Y%m%d%H%M%S)"
cp "$NEW_TEMPLATE" "${NEW_TEMPLATE}.bak.params23b.$(date +%Y%m%d%H%M%S)"
cp "$GEN" "${GEN}.bak.params23b.$(date +%Y%m%d%H%M%S)"

echo "[INFO] Patch DB schema"
kubectl exec -n "${NAMESPACE}" postgresql-0 -- psql -U model_factory -d model_factory -c "
ALTER TABLE product_requests
  ADD COLUMN IF NOT EXISTS cable_channels INTEGER DEFAULT 1,
  ADD COLUMN IF NOT EXISTS cable_diameter_mm NUMERIC DEFAULT 6.0,
  ADD COLUMN IF NOT EXISTS magnet_diameter_mm NUMERIC DEFAULT 10.0,
  ADD COLUMN IF NOT EXISTS magnet_thickness_mm NUMERIC DEFAULT 2.0,
  ADD COLUMN IF NOT EXISTS hinge_count INTEGER DEFAULT 3,
  ADD COLUMN IF NOT EXISTS clearance_mm NUMERIC DEFAULT 0.3;
" || echo "[WARN] DB schema patch failed"

echo "[INFO] Patch main.py"
python3 - <<'PY'
from pathlib import Path

p = Path("/ai/tashkent/3d-model-factory/portal/app/main.py")
s = p.read_text(encoding="utf-8")

def add_after(s, markers, add, label):
    first = add.strip().splitlines()[0].strip()
    if first in s:
        return s
    for m in markers:
        if m in s:
            return s.replace(m, m + add, 1)
    raise SystemExit(f"[ERROR] insertion point not found: {label}")

model_add = (
"    cable_channels = Column(Integer, default=1)\n"
"    cable_diameter_mm = Column(Numeric, default=6.0)\n"
"    magnet_diameter_mm = Column(Numeric, default=10.0)\n"
"    magnet_thickness_mm = Column(Numeric, default=2.0)\n"
"    hinge_count = Column(Integer, default=3)\n"
"    clearance_mm = Column(Numeric, default=0.3)\n"
)
s = add_after(s, [
"    mount_type = Column(String)\n",
"    mount_type = Column(Text)\n",
"    support_allowed = Column(Boolean, default=False)\n",
"    material = Column(String)\n"
], model_add, "ProductRequest columns")

form_add = (
"    cable_channels: int = Form(1),\n"
"    cable_diameter_mm: float = Form(6.0),\n"
"    magnet_diameter_mm: float = Form(10.0),\n"
"    magnet_thickness_mm: float = Form(2.0),\n"
"    hinge_count: int = Form(3),\n"
"    clearance_mm: float = Form(0.3),\n"
)
if "cable_channels: int = Form(1)" not in s:
    done = False
    for m in [
        "    printer_targets: list[str] = Form([]),\n",
        "    printer_targets: List[str] = Form([]),\n",
        "    printer_targets: str = Form(None),\n",
    ]:
        if m in s:
            s = s.replace(m, form_add + m, 1)
            done = True
            break
    if not done:
        for m in [
            "    support_allowed: bool = Form(False),\n",
            "    support_allowed: str = Form(None),\n",
            "    use_gpu: bool = Form(False),\n",
            "    gpu_task: str = Form(\"none\"),\n",
            "    material: str = Form(None),\n",
            "    name: str = Form(...),\n",
        ]:
            if m in s:
                s = s.replace(m, m + form_add, 1)
                done = True
                break
    if not done:
        raise SystemExit("[ERROR] create_product form insertion point not found")

ctor_add = (
"            cable_channels=cable_channels,\n"
"            cable_diameter_mm=cable_diameter_mm,\n"
"            magnet_diameter_mm=magnet_diameter_mm,\n"
"            magnet_thickness_mm=magnet_thickness_mm,\n"
"            hinge_count=hinge_count,\n"
"            clearance_mm=clearance_mm,\n"
)
if "cable_channels=cable_channels" not in s:
    done = False
    for m in [
        "            mount_type=mount_type,\n",
        "            support_allowed=support_allowed,\n",
        "            material=material,\n",
        "            status=\"PENDING\",\n",
        "            id=product_id,\n",
    ]:
        if m in s:
            s = s.replace(m, m + ctor_add, 1)
            done = True
            break
    if not done:
        raise SystemExit("[ERROR] ProductRequest constructor insertion point not found")

md_add = (
"        f\"- Cable Channels: {product.cable_channels or 1}\",\n"
"        f\"- Cable Diameter: {product.cable_diameter_mm or 6.0}mm\",\n"
"        f\"- Magnet Diameter: {product.magnet_diameter_mm or 10.0}mm\",\n"
"        f\"- Magnet Thickness: {product.magnet_thickness_mm or 2.0}mm\",\n"
"        f\"- Hinge Count: {product.hinge_count or 3}\",\n"
"        f\"- Clearance: {product.clearance_mm or 0.3}mm\",\n"
)
if "Cable Channels:" not in s:
    done = False
    for m in [
        "        f\"- Mount Type: {product.mount_type}\",\n",
        "        f\"- Material: {product.material}\",\n",
        "        f\"- Support Allowed: {product.support_allowed}\",\n",
        "        f\"- Shape: {product.shape}\",\n",
    ]:
        if m in s:
            s = s.replace(m, m + md_add, 1)
            done = True
            break
    if not done:
        raise SystemExit("[ERROR] product.md writer insertion point not found")

p.write_text(s, encoding="utf-8")
print("[DONE] main.py patched")
PY

python3 -m py_compile "$MAIN"

echo "[INFO] Patch new_product.html"
python3 - <<'PY'
from pathlib import Path

p = Path("/ai/tashkent/3d-model-factory/portal/app/templates/new_product.html")
s = p.read_text(encoding="utf-8")

block = '''
    <h3>세부 파라미터</h3>
    <p class="hint">직접 입력 모델의 세부 치수입니다. 프리셋을 선택한 뒤에도 수정할 수 있습니다.</p>

    <div class="grid3">
      <div>
        <label>케이블 구 수</label>
        <input name="cable_channels" type="number" min="1" max="6" value="1">
      </div>
      <div>
        <label>케이블 직경 mm</label>
        <input name="cable_diameter_mm" type="number" step="0.1" value="6.0">
      </div>
      <div>
        <label>여유 공차 mm</label>
        <input name="clearance_mm" type="number" step="0.1" value="0.3">
      </div>
    </div>

    <div class="grid3">
      <div>
        <label>자석 직경 mm</label>
        <input name="magnet_diameter_mm" type="number" step="0.1" value="10.0">
      </div>
      <div>
        <label>자석 두께 mm</label>
        <input name="magnet_thickness_mm" type="number" step="0.1" value="2.0">
      </div>
      <div>
        <label>힌지 개수</label>
        <input name="hinge_count" type="number" min="1" max="8" value="3">
      </div>
    </div>
'''

if 'name="cable_channels"' not in s:
    if "    <label>대상 프린터</label>" in s:
        s = s.replace("    <label>대상 프린터</label>", block + "\n    <label>대상 프린터</label>", 1)
    elif "    <button" in s:
        s = s.replace("    <button", block + "\n    <button", 1)
    else:
        s = s.replace("</form>", block + "\n  </form>", 1)

if 'setField("cable_channels"' not in s:
    marker = '  setField("gpu_task", p.gpu_task || "none");'
    js = '''
  setField("cable_channels", p.cable_channels || 1);
  setField("cable_diameter_mm", p.cable_diameter_mm || 6.0);
  setField("magnet_diameter_mm", p.magnet_diameter_mm || 10.0);
  setField("magnet_thickness_mm", p.magnet_thickness_mm || 2.0);
  setField("hinge_count", p.hinge_count || 3);
  setField("clearance_mm", p.clearance_mm || 0.3);'''
    if marker in s:
        s = s.replace(marker, marker + js, 1)

p.write_text(s, encoding="utf-8")
print("[DONE] new_product.html patched")
PY

echo "[INFO] Patch generate_blender_script.py"
python3 - <<'PY'
from pathlib import Path

p = Path("/ai/tashkent/3d-model-factory/scripts/generate_blender_script.py")
s = p.read_text(encoding="utf-8")

if "cable_channels_explicit" not in s:
    marker = 'h = max(8, min(find_number(md, "Height", 25), 150))\n'
    add = (
'h = max(8, min(find_number(md, "Height", 25), 150))\n\n'
'cable_channels_explicit = int(max(1, min(find_number(md, "Cable Channels", 1), 6)))\n'
'cable_diameter_mm = max(1.0, min(find_number(md, "Cable Diameter", 6.0), 30.0))\n'
'magnet_diameter_mm = max(3.0, min(find_number(md, "Magnet Diameter", 10.0), 40.0))\n'
'magnet_thickness_mm = max(1.0, min(find_number(md, "Magnet Thickness", 2.0), 12.0))\n'
'hinge_count_explicit = int(max(1, min(find_number(md, "Hinge Count", 3), 8)))\n'
'clearance_mm = max(0.0, min(find_number(md, "Clearance", 0.3), 2.0))\n'
)
    if marker not in s:
        raise SystemExit("[ERROR] height marker not found in generate_blender_script.py")
    s = s.replace(marker, add, 1)

s = s.replace('chan = channels(blob)', 'chan = cable_channels_explicit')

if '"cable_diameter":' not in s:
    old = '"channels": {chan!r}, "grid": {grid_flag!r}, "label": {label_flag!r},'
    new = '"channels": {chan!r}, "cable_diameter": {cable_diameter_mm!r}, "magnet_diameter": {magnet_diameter_mm!r}, "magnet_thickness": {magnet_thickness_mm!r}, "hinge_count": {hinge_count_explicit!r}, "clearance": {clearance_mm!r}, "grid": {grid_flag!r}, "label": {label_flag!r},'
    if old in s:
        s = s.replace(old, new, 1)
    else:
        print("[WARN] P dict marker not found")

s = s.replace(
    'cw=max(min(pitch*.45,14),8); wh=max(h-base_t,10)',
    'cw=max(P.get("cable_diameter",6.0)+P.get("clearance",0.3)*2, min(pitch*.55,18)); wh=max(h-base_t,10)'
)
s = s.replace(
    '5.2,2.2,None,72',
    'P.get("magnet_diameter",10.0)/2 + P.get("clearance",0.3), P.get("magnet_thickness",2.0)+0.4, None,72'
)
s = s.replace(
    '5.6,.3,acc,72',
    'P.get("magnet_diameter",10.0)/2 + P.get("clearance",0.3)+0.4, .3,acc,72'
)

if 'hinge_count = int(P.get("hinge_count", 3))' not in s:
    old = 'for i,x in enumerate([-w*.32,0,w*.32],1): cyl("HINGE_BARREL_"+str(i),(x,d/2+2,h*.72),2.6,w*.16,acc,48,(0,math.radians(90),0))'
    new = (
'hinge_count = int(P.get("hinge_count", 3))\n'
'    if hinge_count <= 1:\n'
'        hinge_positions = [0]\n'
'    else:\n'
'        hinge_positions = [(-w*0.38) + i*((w*0.76)/(hinge_count-1)) for i in range(hinge_count)]\n'
'    for i,x in enumerate(hinge_positions,1): cyl("HINGE_BARREL_"+str(i),(x,d/2+2,h*.72),2.6,max(w*.10,8),acc,48,(0,math.radians(90),0))'
)
    if old in s:
        s = s.replace(old, new, 1)

if '"cable_diameter_mm="+str(P.get("cable_diameter"' not in s:
    old = '"cable_channels="+str(P["channels"]),"wants_grid="+str(P["grid"])'
    new = '"cable_channels="+str(P["channels"]),"cable_diameter_mm="+str(P.get("cable_diameter", "")),"magnet_diameter_mm="+str(P.get("magnet_diameter", "")),"magnet_thickness_mm="+str(P.get("magnet_thickness", "")),"hinge_count="+str(P.get("hinge_count", "")),"clearance_mm="+str(P.get("clearance", "")),"wants_grid="+str(P["grid"])'
    if old in s:
        s = s.replace(old, new, 1)

p.write_text(s, encoding="utf-8")
print("[DONE] generate_blender_script.py patched")
PY

python3 -m py_compile "$GEN"

cat > "${ROOT}/scripts/verify_parameter_fields.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
source /ai/tashkent/3d-model-factory/.factory.env

echo "[INFO] Portal DB columns"
kubectl exec -n "${NAMESPACE}" postgresql-0 -- psql -U model_factory -d model_factory -c "
select column_name, data_type
from information_schema.columns
where table_name='product_requests'
and column_name in ('cable_channels','cable_diameter_mm','magnet_diameter_mm','magnet_thickness_mm','hinge_count','clearance_mm')
order by column_name;
"

echo ""
echo "[INFO] Local generator parser marker"
grep -n "Cable Channels\\|cable_diameter\\|magnet_diameter\\|hinge_count" "${ROOT}/scripts/generate_blender_script.py" | head -20 || true

echo ""
echo "[INFO] Worker image parser marker"
docker run --rm "${IMAGE}" sh -lc 'grep -n "Cable Channels\\|cable_diameter\\|magnet_diameter\\|hinge_count" /workspace/scripts/generate_blender_script.py | head -20 || true'
CHECK

chmod +x "${ROOT}/scripts/verify_parameter_fields.sh"

echo "[DONE] Product parameter fields robust patch applied"
echo ""
echo "Next:"
echo "  cd ${ROOT}"
echo "  make portal-build && make portal-push && make portal-restart"
echo "  source .factory.env"
echo "  docker build --no-cache -t \"${IMAGE}\" -f docker/blender-worker/Dockerfile ."
echo "  docker push \"${IMAGE}\""
echo "  ./scripts/verify_parameter_fields.sh"
