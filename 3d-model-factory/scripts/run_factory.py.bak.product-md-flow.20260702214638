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
