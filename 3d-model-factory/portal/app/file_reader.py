from pathlib import Path


DEFAULT_MAX_CHARS = 20000
TRUNCATED_MARKER = "\n... truncated ..."


def safe_read_text(path: Path, max_chars: int = DEFAULT_MAX_CHARS) -> str | None:
    if not path.exists() or not path.is_file():
        return None

    try:
        text_value = path.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        return f"파일 읽기 실패: {repr(e)}"

    if len(text_value) > max_chars:
        return text_value[:max_chars] + TRUNCATED_MARKER
    return text_value


def parse_key_value_text(text: str | None) -> dict:
    parsed = {}
    if not text:
        return parsed

    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        separator = "=" if "=" in stripped else (":" if ":" in stripped else None)
        if not separator:
            continue

        key, value = stripped.split(separator, 1)
        key = key.strip().lstrip("-").strip()
        if key:
            parsed[key] = value.strip()
    return parsed


def parse_validation_status(text: str) -> str:
    values = parse_key_value_text(text)
    status = values.get("VALIDATION_STATUS", "UNKNOWN").strip().upper()
    if status in {"PASS", "WARN", "FAIL"}:
        return status
    return "UNKNOWN"


def read_product_debug_files(product_base_dir: Path) -> dict:
    targets = [
        ("validation.txt", product_base_dir / "output" / "validation.txt"),
        ("product.md", product_base_dir / "input" / "product.md"),
        ("output_status.txt", product_base_dir / "output" / "output_status.txt"),
        ("design_metadata.txt", product_base_dir / "output" / "design_metadata.txt"),
        ("worker_flow_debug.txt", product_base_dir / "output" / "worker_flow_debug.txt"),
        ("worker_error.txt", product_base_dir / "output" / "worker_error.txt"),
        ("shape_intent_debug.txt", product_base_dir / "output" / "shape_intent_debug.txt"),
        ("job.log", product_base_dir / "logs" / "job.log"),
    ]

    debug_texts = []
    validation_status = "UNKNOWN"
    for label, path in targets:
        content = safe_read_text(path)
        truncated = content.endswith(TRUNCATED_MARKER) if content else False

        if label == "validation.txt" and content:
            validation_status = parse_validation_status(content)

        debug_texts.append({
            "label": label,
            "content": content,
            "truncated": truncated,
            "exists": content is not None,
        })

    return {
        "debug_texts": debug_texts,
        "validation_status": validation_status,
    }


def read_run_debug_files(run_dir: Path) -> dict:
    text_files = ["run_metadata.txt", "validation.txt", "design_metadata.txt", "output_status.txt"]
    texts = {}
    for filename in text_files:
        content = safe_read_text(run_dir / filename)
        texts[filename] = {
            "content": content,
            "truncated": content.endswith(TRUNCATED_MARKER) if content else False,
            "exists": content is not None,
        }
    return texts
