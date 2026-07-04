import shutil
from datetime import datetime
from pathlib import Path


DEFAULT_DATA_ROOT = Path("/data/products")
RUN_FILES = ["preview.png", "validation.txt", "model.stl", "model.3mf"]


def _safe_product_id(product_id: str) -> str:
    value = str(product_id or "").strip()
    if not value or value in {".", ".."} or value != Path(value).name or "/" in value or "\\" in value:
        raise ValueError("Invalid product_id")
    return value


def _safe_run_number(run_number: int) -> int:
    if isinstance(run_number, bool) or not isinstance(run_number, int) or run_number < 1:
        raise ValueError("Invalid run_number")
    return run_number


def get_product_base_dir(product_id: str, data_root: Path = DEFAULT_DATA_ROOT) -> Path:
    return data_root / _safe_product_id(product_id)


def get_runs_dir(product_id: str, data_root: Path = DEFAULT_DATA_ROOT) -> Path:
    return get_product_base_dir(product_id, data_root) / "runs"


def list_run_numbers(product_id: str, data_root: Path = DEFAULT_DATA_ROOT) -> list[int]:
    runs_dir = get_runs_dir(product_id, data_root)
    run_numbers = []
    if not runs_dir.exists():
        return run_numbers

    for child in runs_dir.iterdir():
        if child.is_dir() and child.name.isdigit():
            run_numbers.append(int(child.name))
    return sorted(run_numbers)


def get_latest_run_number(product_id: str, data_root: Path = DEFAULT_DATA_ROOT) -> int | None:
    run_numbers = list_run_numbers(product_id, data_root)
    return max(run_numbers) if run_numbers else None


def get_next_run_number(product_id: str, data_root: Path = DEFAULT_DATA_ROOT) -> int:
    latest = get_latest_run_number(product_id, data_root)
    return latest + 1 if latest else 1


def get_run_dir(product_id: str, run_number: int, data_root: Path = DEFAULT_DATA_ROOT) -> Path:
    return get_runs_dir(product_id, data_root) / str(_safe_run_number(run_number))


def get_latest_output_dir(product_id: str, data_root: Path = DEFAULT_DATA_ROOT) -> Path:
    return get_product_base_dir(product_id, data_root) / "output"


def copy_run_to_output(product_id: str, run_number: int, data_root: Path = DEFAULT_DATA_ROOT) -> None:
    run_dir = get_run_dir(product_id, run_number, data_root)
    output_dir = get_latest_output_dir(product_id, data_root)

    if output_dir.is_symlink() or output_dir.is_file():
        output_dir.unlink()
    elif output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    if not run_dir.exists() or not run_dir.is_dir():
        return

    for source in run_dir.iterdir():
        if source.is_symlink():
            continue
        target = output_dir / source.name
        if source.is_dir():
            shutil.copytree(source, target, symlinks=False)
        elif source.is_file():
            shutil.copy2(source, target, follow_symlinks=True)


def write_run_metadata(
    product_id: str,
    run_number: int,
    output_dir: Path,
    product_md_path: Path,
    image: str,
    use_gpu: bool,
    gpu_task: str,
    trigger: str = "create",
) -> Path:
    safe_product_id = _safe_product_id(product_id)
    safe_run_number = _safe_run_number(run_number)
    safe_trigger = trigger if trigger in {"create", "rerun", "edit"} else "create"

    output_dir.mkdir(parents=True, exist_ok=True)
    metadata_output_dir = product_md_path.parent.parent / "runs" / str(safe_run_number)
    lines = [
        f"product_id={safe_product_id}",
        f"trigger={safe_trigger}",
        f"run_number={safe_run_number}",
        f"created_at={datetime.utcnow().isoformat()}Z",
        f"product_md_path={product_md_path}",
        f"output_dir={metadata_output_dir}",
        f"image={image}",
        f"use_gpu={'true' if use_gpu else 'false'}",
        f"gpu_task={gpu_task or 'none'}",
    ]
    path = output_dir / "run_metadata.txt"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def build_run_summary(
    product_id: str,
    run_number: int,
    data_root: Path = DEFAULT_DATA_ROOT,
) -> dict:
    safe_run_number = _safe_run_number(run_number)
    run_dir = get_run_dir(product_id, safe_run_number, data_root)
    latest_run_number = get_latest_run_number(product_id, data_root)
    files = []

    for name in RUN_FILES:
        path = run_dir / name
        exists = path.exists() and path.is_file()
        try:
            size = path.stat().st_size if exists else None
        except OSError:
            exists = False
            size = None
        files.append({
            "name": name,
            "exists": exists,
            "size": size,
            "download_url": f"/products/{_safe_product_id(product_id)}/download/runs/{safe_run_number}/{name}",
        })

    return {
        "number": safe_run_number,
        "is_latest": safe_run_number == latest_run_number,
        "files": files,
    }


def build_run_summaries(
    product_id: str,
    run_numbers: list[int] | None = None,
    limit: int | None = None,
    data_root: Path = DEFAULT_DATA_ROOT,
) -> list[dict]:
    selected_numbers = list_run_numbers(product_id, data_root) if run_numbers is None else run_numbers
    if limit is not None:
        selected_numbers = list(reversed(selected_numbers))[:limit]
        selected_numbers = sorted(selected_numbers)
    return [
        build_run_summary(product_id, run_number, data_root)
        for run_number in selected_numbers
    ]
