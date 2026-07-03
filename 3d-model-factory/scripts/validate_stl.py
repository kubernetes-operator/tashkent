import sys
from pathlib import Path

import trimesh


BAMBU_A1_LIMIT_MM = 256.0
SMALL_STL_BYTES = 1024


def parse_metadata(path: Path) -> dict[str, str]:
    data = {}
    if not path.exists():
        return data

    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def as_float(metadata: dict[str, str], key: str) -> float | None:
    value = metadata.get(key, "").strip()
    if not value:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def as_int(metadata: dict[str, str], key: str) -> int | None:
    value = as_float(metadata, key)
    return int(value) if value is not None else None


def add_message(messages: list[tuple[str, str]], level: str, text: str):
    messages.append((level, text))


def status_from(messages: list[tuple[str, str]]) -> str:
    if any(level == "FAIL" for level, _ in messages):
        return "FAIL"
    if any(level == "WARN" for level, _ in messages):
        return "WARN"
    return "PASS"


def bullet_lines(messages: list[tuple[str, str]], levels: set[str]) -> list[str]:
    selected = [f"- {level}: {text}" for level, text in messages if level in levels]
    return selected or ["- none"]


def main():
    stl_path = Path(sys.argv[1])
    run_dir = stl_path.parent
    report_path = run_dir / "validation.txt"
    metadata_path = run_dir / "design_metadata.txt"

    messages: list[tuple[str, str]] = []
    metadata = parse_metadata(metadata_path)

    stl_exists = stl_path.exists()
    stl_size = stl_path.stat().st_size if stl_exists else 0

    if not stl_exists:
        add_message(messages, "FAIL", f"model.stl not found: {stl_path}")
    elif stl_size < SMALL_STL_BYTES:
        add_message(messages, "WARN", f"model.stl is very small ({stl_size} bytes); verify export quality")

    mesh = None
    mesh_error = ""
    if stl_exists:
        try:
            mesh = trimesh.load_mesh(stl_path)
        except Exception as e:
            mesh_error = repr(e)
            add_message(messages, "FAIL", f"failed to load model.stl: {mesh_error}")

    expected_files = ["model.blend", "model.3mf", "preview.png", "README.md"]
    file_status = {}
    for name in expected_files:
        path = run_dir / name
        file_status[name] = path.exists()
        if not path.exists():
            add_message(messages, "WARN", f"{name} is missing")

    design_profile = metadata.get("design_profile", "")
    material = metadata.get("material", "")
    width_mm = as_float(metadata, "width_mm")
    depth_mm = as_float(metadata, "depth_mm")
    height_mm = as_float(metadata, "height_mm")
    cable_channels = as_int(metadata, "cable_channels")
    cable_diameter_mm = as_float(metadata, "cable_diameter_mm")
    magnet_diameter_mm = as_float(metadata, "magnet_diameter_mm")
    magnet_thickness_mm = as_float(metadata, "magnet_thickness_mm")
    hinge_count = as_int(metadata, "hinge_count")
    clearance_mm = as_float(metadata, "clearance_mm")
    base_thickness_mm = as_float(metadata, "base_thickness_mm")
    wall_thickness_mm = as_float(metadata, "wall_thickness_mm")

    dims = [width_mm, depth_mm, height_mm]
    if any(value is None or value <= 0 for value in dims):
        add_message(messages, "WARN", "width_mm, depth_mm, or height_mm is missing or zero")
    elif any(value > BAMBU_A1_LIMIT_MM for value in dims):
        add_message(messages, "WARN", "model dimensions exceed Bambu A1 build volume 256 x 256 x 256mm")

    if base_thickness_mm is None:
        add_message(messages, "INFO", "base_thickness_mm not present in design_metadata.txt; using generator defaults")
    elif base_thickness_mm < 2.0:
        add_message(messages, "WARN", "base_thickness_mm is below 2.0mm")

    normalized_material = material.upper()
    if wall_thickness_mm is None:
        add_message(messages, "INFO", "wall_thickness_mm not present in design_metadata.txt; using generator defaults")
    elif wall_thickness_mm < 1.6:
        add_message(messages, "WARN", "wall_thickness_mm is below 1.6mm")

    if normalized_material == "PETG":
        add_message(messages, "INFO", "PETG recommended wall thickness is at least 1.6mm")
    elif normalized_material == "PLA":
        add_message(messages, "INFO", "PLA recommended wall thickness is at least 1.2mm")

    profile_text = design_profile.lower()
    if "cable" in profile_text:
        if cable_channels is None or cable_channels < 1:
            add_message(messages, "WARN", "cable_channels must be at least 1 for cable clip profiles")
        if cable_diameter_mm is None or cable_diameter_mm <= 0:
            add_message(messages, "WARN", "cable_diameter_mm is missing or zero for cable clip profiles")
        if clearance_mm is None:
            add_message(messages, "WARN", "clearance_mm is missing for cable clip profiles")
        elif clearance_mm < 0.2:
            add_message(messages, "WARN", "clearance_mm below 0.2mm may be too tight for cable insertion")
        elif clearance_mm > 1.0:
            add_message(messages, "WARN", "clearance_mm above 1.0mm may be too loose for cable retention")

    if "magnetic" in profile_text or "magnet" in profile_text:
        if magnet_diameter_mm is None or magnet_diameter_mm < 3.0:
            add_message(messages, "WARN", "magnet_diameter_mm below 3mm is likely too small")
        if magnet_thickness_mm is None or magnet_thickness_mm < 1.0:
            add_message(messages, "WARN", "magnet_thickness_mm below 1mm is likely too thin")
        if clearance_mm is None:
            add_message(messages, "WARN", "clearance_mm is missing for magnetic holder profiles")
        elif clearance_mm < 0.1:
            add_message(messages, "WARN", "clearance_mm below 0.1mm may make magnet insertion too tight")

    if "hinged" in profile_text:
        if hinge_count is None or hinge_count < 1:
            add_message(messages, "WARN", "hinge_count must be at least 1 for hinged profiles")
        elif hinge_count > 6:
            add_message(messages, "WARN", "hinge_count above 6 increases print and assembly difficulty")
        if width_mm and hinge_count and hinge_count > max(1, int(width_mm // 12)):
            add_message(messages, "WARN", "hinge_count may be too high for the product width")

    if mesh is not None:
        if mesh.is_empty:
            add_message(messages, "FAIL", "mesh is empty")
        if len(mesh.faces) < 12:
            add_message(messages, "WARN", "mesh has very few faces")
        if not mesh.is_watertight:
            add_message(messages, "WARN", "mesh is not watertight; slicer repair or manual review may be needed")

    final_status = status_from(messages)

    lines = [
        f"VALIDATION_STATUS={final_status}",
        "",
        "## Summary",
        "",
        f"- Status: {final_status}",
        f"- STL: {stl_path}",
        f"- Design Profile: {design_profile or 'unknown'}",
        f"- Material: {material or 'unknown'}",
        "",
        "## Files",
        "",
        f"- model.stl: {'present' if stl_exists else 'missing'} ({stl_size} bytes)",
    ]
    lines.extend([f"- {name}: {'present' if exists else 'missing'}" for name, exists in file_status.items()])

    lines.extend([
        "",
        "## Dimensions",
        "",
        f"- width_mm: {width_mm if width_mm is not None else 'missing'}",
        f"- depth_mm: {depth_mm if depth_mm is not None else 'missing'}",
        f"- height_mm: {height_mm if height_mm is not None else 'missing'}",
        f"- base_thickness_mm: {base_thickness_mm if base_thickness_mm is not None else 'missing'}",
        f"- wall_thickness_mm: {wall_thickness_mm if wall_thickness_mm is not None else 'missing'}",
    ])

    if mesh is not None:
        lines.extend([
            f"- mesh_vertices: {len(mesh.vertices)}",
            f"- mesh_faces: {len(mesh.faces)}",
            f"- mesh_is_empty: {mesh.is_empty}",
            f"- mesh_is_watertight: {mesh.is_watertight}",
            f"- mesh_is_winding_consistent: {mesh.is_winding_consistent}",
        ])
        try:
            extents = mesh.extents
            lines.extend([
                f"- mesh_size_x_mm: {extents[0]:.3f}",
                f"- mesh_size_y_mm: {extents[1]:.3f}",
                f"- mesh_size_z_mm: {extents[2]:.3f}",
            ])
        except Exception as e:
            add_message(messages, "WARN", f"failed to read mesh extents: {repr(e)}")
    elif mesh_error:
        lines.append(f"- mesh_load_error: {mesh_error}")

    lines.extend([
        "",
        "## Printability Checks",
        "",
        f"- Bambu A1 build volume limit: {BAMBU_A1_LIMIT_MM:.0f} x {BAMBU_A1_LIMIT_MM:.0f} x {BAMBU_A1_LIMIT_MM:.0f}mm",
        "- Minimum base thickness check: 2.0mm",
        "- Minimum wall thickness check: 1.6mm",
        "",
        "## Parameter Checks",
        "",
        f"- cable_channels: {cable_channels if cable_channels is not None else 'missing'}",
        f"- cable_diameter_mm: {cable_diameter_mm if cable_diameter_mm is not None else 'missing'}",
        f"- magnet_diameter_mm: {magnet_diameter_mm if magnet_diameter_mm is not None else 'missing'}",
        f"- magnet_thickness_mm: {magnet_thickness_mm if magnet_thickness_mm is not None else 'missing'}",
        f"- hinge_count: {hinge_count if hinge_count is not None else 'missing'}",
        f"- clearance_mm: {clearance_mm if clearance_mm is not None else 'missing'}",
        "",
        "## Warnings",
        "",
    ])
    lines.extend(bullet_lines(messages, {"FAIL", "WARN"}))

    lines.extend([
        "",
        "## Recommendations",
        "",
    ])
    lines.extend(bullet_lines(messages, {"INFO"}))
    if final_status == "PASS":
        lines.append("- No blocking printability issues detected by automated checks.")
    elif final_status == "WARN":
        lines.append("- Review warnings before slicing; generation output is still usable for inspection.")
    else:
        lines.append("- Fix failed checks before relying on this model for printing.")

    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))

    if final_status == "FAIL":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
