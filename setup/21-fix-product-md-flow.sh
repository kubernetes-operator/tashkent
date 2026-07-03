#!/usr/bin/env bash
set -euo pipefail

# 21-fix-product-md-flow.sh
#
# Fix identical design_metadata/model issue.
#
# Root cause:
#   Worker is generating from default values because PRODUCT_MD is not being passed
#   to generate_blender_script.py, or product.md is missing inside the output flow.
#
# This patch rewrites run_factory.py so that:
#   - Portal mode requires PRODUCT_ID.
#   - PRODUCT_MD defaults to /data/products/${PRODUCT_ID}/input/product.md.
#   - OUTPUT_DIR defaults to /data/products/${PRODUCT_ID}/output.
#   - product.md is copied into output/input_product.md.
#   - generate_blender_script.py is called with run_dir and product_md path.
#   - worker_flow_debug.txt records exactly what happened.

ENV_FILE="/ai/tashkent/3d-model-factory/.factory.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "[ERROR] ${ENV_FILE} not found."
  exit 1
fi

source "${ENV_FILE}"

RUN_FACTORY="${ROOT}/scripts/run_factory.py"

if [ ! -f "${RUN_FACTORY}" ]; then
  echo "[ERROR] run_factory.py not found: ${RUN_FACTORY}"
  exit 1
fi

cp "${RUN_FACTORY}" "${RUN_FACTORY}.bak.product-md-flow.$(date +%Y%m%d%H%M%S)"

cat > "${RUN_FACTORY}" <<'PY'
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

FLOW_VERSION = "run_factory-v21-product-md-flow"


def log(message: str):
    print(message, flush=True)


def check_call(cmd, label: str):
    log("[INFO] RUN " + label + ": " + " ".join(str(x) for x in cmd))
    subprocess.check_call(cmd)


def optional_call(cmd, label: str):
    log("[INFO] RUN optional " + label + ": " + " ".join(str(x) for x in cmd))
    rc = subprocess.call(cmd)
    log(f"[INFO] optional {label} exit_code={rc}")
    return rc


def main():
    product_id = os.environ.get("PRODUCT_ID", "").strip()
    product_md_env = os.environ.get("PRODUCT_MD", "").strip()
    output_dir_env = os.environ.get("OUTPUT_DIR", "").strip()
    use_gpu = os.environ.get("USE_GPU", "false").strip()
    gpu_task = os.environ.get("GPU_TASK", "none").strip()

    if product_id:
        run_dir = Path(output_dir_env or f"/data/products/{product_id}/output")
        product_md = Path(product_md_env or f"/data/products/{product_id}/input/product.md")
    else:
        run_id = os.environ.get("RUN_ID", time.strftime("%Y%m%d%H%M%S"))
        run_dir = Path(output_dir_env or f"/data/{run_id}")
        product_md = Path(product_md_env) if product_md_env else None

    run_dir.mkdir(parents=True, exist_ok=True)

    debug_lines = [
        f"worker_flow_version={FLOW_VERSION}",
        f"PRODUCT_ID={product_id}",
        f"PRODUCT_MD={product_md}",
        f"OUTPUT_DIR={run_dir}",
        f"USE_GPU={use_gpu}",
        f"GPU_TASK={gpu_task}",
        f"python={sys.executable}",
    ]

    product_text = ""
    if product_md:
        debug_lines.append(f"product_md_exists={product_md.exists()}")
        if product_md.exists():
            product_text = product_md.read_text(encoding="utf-8", errors="ignore")
            debug_lines.append(f"product_md_size={len(product_text)}")
            (run_dir / "input_product.md").write_text(product_text, encoding="utf-8")
            (run_dir / "input_debug.txt").write_text(product_text, encoding="utf-8")
        else:
            debug_lines.append("product_md_missing=true")
    else:
        debug_lines.append("product_md_configured=false")

    (run_dir / "worker_flow_debug.txt").write_text("\n".join(debug_lines) + "\n", encoding="utf-8")

    for line in debug_lines:
        log("[INFO] " + line)

    # In portal mode, product.md must exist.
    # Otherwise every product becomes the default model, which is the exact bug we are fixing.
    if product_id and (not product_md or not product_md.exists()):
        msg = f"PRODUCT_MD missing. Refusing to generate default model. path={product_md}"
        (run_dir / "worker_error.txt").write_text(msg + "\n", encoding="utf-8")
        log("[ERROR] " + msg)
        raise SystemExit(10)

    gen_cmd = [
        "python3",
        "/workspace/scripts/generate_blender_script.py",
        str(run_dir),
    ]

    if product_md and product_md.exists():
        gen_cmd.append(str(product_md))

    check_call(gen_cmd, "generate_blender_script")

    generated = Path("/workspace/blender/generated_model.py")
    if not generated.exists():
        raise FileNotFoundError("/workspace/blender/generated_model.py not found")

    try:
        shutil.copyfile(generated, run_dir / "generated_model.py")
    except Exception as e:
        log("[WARN] failed to copy generated_model.py: " + repr(e))

    check_call([
        "blender",
        "--background",
        "--python",
        str(generated),
        "--",
        str(run_dir),
    ], "blender")

    stl_path = run_dir / "model.stl"
    if not stl_path.exists():
        raise FileNotFoundError(f"model.stl not found: {stl_path}")

    validate_script = Path("/workspace/scripts/validate_stl.py")
    if validate_script.exists():
        optional_call([
            "python3",
            str(validate_script),
            str(stl_path),
        ], "validate_stl")

    three_mf_script = Path("/workspace/scripts/generate_3mf_from_stl.py")
    if three_mf_script.exists():
        optional_call([
            "python3",
            str(three_mf_script),
            str(run_dir),
        ], "generate_3mf_from_stl")

    report_script = Path("/workspace/scripts/create_report.py")
    if report_script.exists():
        report_cmd = [
            "python3",
            str(report_script),
            str(run_dir),
        ]
        if product_md and product_md.exists():
            report_cmd.append(str(product_md))
        optional_call(report_cmd, "create_report")

    with (run_dir / "worker_flow_debug.txt").open("a", encoding="utf-8") as f:
        f.write("worker_completed=true\n")
        f.write(f"input_product_md_copy_exists={(run_dir / 'input_product.md').exists()}\n")
        f.write(f"design_metadata_exists={(run_dir / 'design_metadata.txt').exists()}\n")
        f.write(f"model_stl_exists={stl_path.exists()}\n")

    log("[INFO] Factory job completed")
    log(f"[INFO] Output: {run_dir}")


if __name__ == "__main__":
    main()
PY

python3 -m py_compile "${RUN_FACTORY}"

cat > "${ROOT}/scripts/verify_product_md_flow.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail

source /ai/tashkent/3d-model-factory/.factory.env

echo "[INFO] Latest products"
kubectl exec -n "${NAMESPACE}" postgresql-0 -- \
  psql -U model_factory -d model_factory -c "
select id, name, preset_id, category, shape, mount_type, status, created_at
from product_requests
order by created_at desc
limit 5;
"

echo ""
echo "[INFO] Worker image run_factory marker"
docker run --rm "${IMAGE}" sh -lc 'grep -n "run_factory-v21-product-md-flow" /workspace/scripts/run_factory.py || true'

echo ""
echo "[INFO] Worker image shape profiles"
docker run --rm "${IMAGE}" sh -lc 'grep -n "bambu_a1_nozzle_holder\|m3_wall_hook\|cable_clip_small\|battery_case_2cell" /workspace/scripts/generate_blender_script.py | head -20 || true'
CHECK

chmod +x "${ROOT}/scripts/verify_product_md_flow.sh"

echo "[DONE] Product MD flow fix applied"
echo ""
echo "Required rebuild:"
echo "  cd ${ROOT}"
echo "  source .factory.env"
echo "  docker build --no-cache -t \"${IMAGE}\" -f docker/blender-worker/Dockerfile ."
echo "  docker push \"${IMAGE}\""
echo "  ./scripts/verify_product_md_flow.sh"
