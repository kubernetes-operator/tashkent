from pathlib import Path


def build_product_md(product) -> str:
    content = [
        "# Product Design Request",
        "",
        "## Basic",
        "",
        f"- Product ID: {product.id}",
        f"- Name: {product.name}",
        f"- Category: {product.category}",
        f"- Preset ID: {product.preset_id or 'custom'}",
        f"- Description: {product.description or ''}",
        "",
        "## Dimensions",
        "",
        f"- Width: {product.width_mm or ''}mm",
        f"- Depth: {product.depth_mm or ''}mm",
        f"- Height: {product.height_mm or ''}mm",
        "",
        "## Design",
        "",
        f"- Shape: {product.shape or ''}",
        f"- Surface: {product.surface or ''}",
        f"- Color: {product.color or ''}",
        f"- Material: {product.material or ''}",
        f"- Mount Type: {product.mount_type or ''}",
        f"- Support Allowed: {product.support_allowed}",
        f"- Cable Channels: {product.cable_channels or 1}",
        f"- Cable Diameter: {product.cable_diameter_mm or 6.0}mm",
        f"- Magnet Diameter: {product.magnet_diameter_mm or 10.0}mm",
        f"- Magnet Thickness: {product.magnet_thickness_mm or 2.0}mm",
        f"- Hinge Count: {product.hinge_count or 3}",
        f"- Clearance: {product.clearance_mm or 0.3}mm",
        f"- GPU Enabled: {product.use_gpu}",
        f"- GPU Task: {product.gpu_task or 'none'}",
        "",
        "## Printer Targets",
        "",
        product.printer_targets or "",
        "",
        "## Output Requirements",
        "",
        "- Generate STL",
        "- Generate BLEND",
        "- Generate README",
        "- Validate mesh",
        "",
    ]
    return "\n".join(content)


def write_product_md(product, base_dir: Path) -> Path:
    input_dir = base_dir / "input"
    output_dir = base_dir / "output"
    logs_dir = base_dir / "logs"

    input_dir.mkdir(parents=True, exist_ok=True)
    output_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)

    path = input_dir / "product.md"
    path.write_text(build_product_md(product), encoding="utf-8")
    return path
