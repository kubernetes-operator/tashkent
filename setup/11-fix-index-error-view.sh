#!/usr/bin/env bash
set -euo pipefail

ROOT="/ai/tashkent/3d-model-factory"
MAIN="${ROOT}/portal/app/main.py"

if [ ! -f "${MAIN}" ]; then
  echo "[ERROR] main.py not found: ${MAIN}"
  exit 1
fi

cp "${MAIN}" "${MAIN}.bak.$(date +%Y%m%d%H%M%S)"

python3 - <<'PY'
from pathlib import Path
import re

main = Path("/ai/tashkent/3d-model-factory/portal/app/main.py")
text = main.read_text(encoding="utf-8")

pattern = r'''@app\.get\("/", response_class=HTMLResponse\)
def index\(request: Request\):
    db = get_db\(\)
    try:
        products = db\.query\(ProductRequest\)\.order_by\(ProductRequest\.created_at\.desc\(\)\)\.all\(\)
        for p in products:
            refresh_product_status\(db, p\)
        return templates\.TemplateResponse\("index\.html", \{"request": request, "products": products\}\)
    finally:
        db\.close\(\)
'''

replacement = '''@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    db = get_db()
    try:
        products = db.query(ProductRequest).order_by(ProductRequest.created_at.desc()).all()
        safe_products = []
        for p in products:
            try:
                refresh_product_status(db, p)
            except Exception as e:
                print("[WARN] refresh_product_status failed on index:", repr(e))
            safe_products.append(p)

        try:
            return templates.TemplateResponse("index.html", {"request": request, "products": safe_products})
        except Exception as e:
            return HTMLResponse(
                "<h1>Template Render Error</h1><pre>" + repr(e) + "</pre>",
                status_code=500
            )
    except Exception as e:
        return HTMLResponse(
            "<h1>Index DB Error</h1><pre>" + repr(e) + "</pre>",
            status_code=500
        )
    finally:
        db.close()
'''

if re.search(pattern, text):
    text = re.sub(pattern, replacement, text)
else:
    print("[WARN] Exact index function pattern not found. Appending safer fallback is not possible automatically.")
    print("[WARN] Please inspect current index function.")
    raise SystemExit(1)

main.write_text(text, encoding="utf-8")
print("[DONE] index function patched")
PY

python3 -m py_compile "${MAIN}"

echo "[DONE] main.py syntax check passed"
