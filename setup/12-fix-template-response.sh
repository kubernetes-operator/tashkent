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

main = Path("/ai/tashkent/3d-model-factory/portal/app/main.py")
text = main.read_text(encoding="utf-8")

replacements = {
'''templates.TemplateResponse("index.html", {"request": request, "products": safe_products})''':
'''templates.TemplateResponse(name="index.html", request=request, context={"products": safe_products})''',

'''templates.TemplateResponse("index.html", {"request": request, "products": products})''':
'''templates.TemplateResponse(name="index.html", request=request, context={"products": products})''',

'''templates.TemplateResponse("new_product.html", {"request": request})''':
'''templates.TemplateResponse(name="new_product.html", request=request, context={})''',

'''templates.TemplateResponse(
            "product_detail.html",
            {"request": request, "product": product, "files": files, "jobs": jobs},
        )''':
'''templates.TemplateResponse(
            name="product_detail.html",
            request=request,
            context={"product": product, "files": files, "jobs": jobs},
        )''',

'''templates.TemplateResponse(
            "product_detail.html",
            {"request": request, "product": product, "files": files, "jobs": jobs}
        )''':
'''templates.TemplateResponse(
            name="product_detail.html",
            request=request,
            context={"product": product, "files": files, "jobs": jobs}
        )''',
}

changed = False

for old, new in replacements.items():
    if old in text:
        text = text.replace(old, new)
        changed = True

if not changed:
    print("[WARN] Exact patterns were not found.")
    print("[INFO] Existing TemplateResponse lines:")
    for i, line in enumerate(text.splitlines(), start=1):
        if "TemplateResponse" in line:
            print(f"{i}: {line}")
    raise SystemExit(1)

main.write_text(text, encoding="utf-8")
print("[DONE] TemplateResponse calls patched")
PY

python3 -m py_compile "${MAIN}"

echo "[DONE] main.py syntax check passed"
