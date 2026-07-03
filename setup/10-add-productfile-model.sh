#!/usr/bin/env bash
set -euo pipefail

ROOT="/ai/tashkent/3d-model-factory"
MAIN="${ROOT}/portal/app/main.py"

if [ ! -f "${MAIN}" ]; then
  echo "[ERROR] main.py not found: ${MAIN}"
  exit 1
fi

if grep -q "class ProductFile" "${MAIN}"; then
  echo "[INFO] ProductFile already exists in main.py"
  exit 0
fi

python3 - <<'PY'
from pathlib import Path

main = Path("/ai/tashkent/3d-model-factory/portal/app/main.py")
text = main.read_text(encoding="utf-8")

insert = r'''

class ProductFile(Base):
    __tablename__ = "product_files"

    id = Column(String, primary_key=True)
    product_id = Column(String, ForeignKey("product_requests.id"))
    file_type = Column(String, nullable=False)
    file_name = Column(String, nullable=False)
    file_path = Column(Text, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)
'''

# GenerationJob 클래스 앞에 삽입
marker = "\n\nclass GenerationJob(Base):"

if marker not in text:
    raise SystemExit("[ERROR] marker not found: class GenerationJob(Base)")

text = text.replace(marker, insert + marker)

main.write_text(text, encoding="utf-8")
print("[DONE] ProductFile model inserted")
PY

python3 -m py_compile "${MAIN}"

echo "[DONE] main.py syntax check passed"
