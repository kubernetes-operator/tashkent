# Worker Shape Engine

This document summarizes the current worker-side shape generation flow.

## Main Files

| File | Role |
|---|---|
| `scripts/run_factory.py` | Worker entrypoint. Reads env vars, prepares run dir, invokes script generation, runs Blender, validation, 3MF export, report generation, and copies latest output. |
| `scripts/generate_blender_script.py` | Reads `product.md`, selects design profile, emits `/workspace/blender/generated_model.py`. |
| `scripts/validate_stl.py` | Validates `model.stl` and writes `validation.txt`. |
| `scripts/generate_3mf_from_stl.py` | Fallback 3MF exporter using `trimesh` and appends 3MF status to `output_status.txt`. |
| `scripts/create_report.py` | Writes `README.md` and `slicer_notes.md` from metadata, validation, output status, and optional product request. |

## Environment Inputs

`run_factory.py` uses:

- `PRODUCT_ID`
- `PRODUCT_MD`
- `OUTPUT_DIR`
- `RUN_NUMBER`
- `WORKER_IMAGE`
- `USE_GPU`
- `GPU_TASK`

These names are part of the Portal/Worker contract and must not be renamed during refactoring.

## product.md Fields

`generate_blender_script.py` currently parses bullet or table-style values with `find_value`.

Parsed fields:

- `Name`
- `Category`
- `Preset ID`
- `Description`
- `Shape`
- `Surface`
- `Material`
- `Mount Type`
- `Support Allowed`
- `Width`
- `Depth`
- `Height`
- `Cable Channels`
- `Cable Diameter`
- `Magnet Diameter`
- `Magnet Thickness`
- `Hinge Count`
- `Clearance`

Numeric clamps:

- `width_mm`: 30 to 260
- `depth_mm`: 15 to 190
- `height_mm`: 8 to 150
- `cable_channels`: 1 to 6
- `cable_diameter_mm`: 1.0 to 30.0
- `magnet_diameter_mm`: 3.0 to 40.0
- `magnet_thickness_mm`: 1.0 to 12.0
- `hinge_count`: 1 to 8
- `clearance_mm`: 0.0 to 2.0

## Shape Intent Selection

Known preset IDs map directly:

- `bambu_a1_nozzle_holder`
- `bambu_scraper_holder`
- `m3_wall_hook`
- `cable_clip_small`
- `homelab_label_holder`
- `battery_case_2cell`

If the preset ID is not known, the combined text from name, category, preset ID, description, shape, and mount type is matched by keywords:

| Match | Selected `design_profile` |
|---|---|
| hinge, hinged, 힌지, 경첩, 접히, fold | `custom_hinged_case` |
| lid, cover, 뚜껑, 커버, 덮개 | `custom_lidded_case` |
| magnet, magnetic, 자석, 마그넷 | `custom_magnetic_holder` |
| cable, clip, 케이블, 클립 | `custom_cable_clip` |
| bracket, 브라켓, wall mount, 벽걸이, m3, bolt, 볼트, 나사 | `custom_screw_bracket` |
| tray, box, case, 트레이, 박스, 케이스, 수납 | `custom_open_tray` |
| fallback | `custom_parametric_holder` |

## Supported design_profile Values

| Profile | Current generation behavior |
|---|---|
| `custom_hinged_case` | Bottom shell, open lid, hinge barrels, hinge pin. Uses `hinge_count`. |
| `custom_lidded_case` | Box walls plus separate lid and inner rim. |
| `custom_magnetic_holder` | Base/back/side rails plus magnet socket cuts and rings. Uses magnet diameter/thickness/clearance. |
| `custom_cable_clip` | Multi-channel cable clip. Uses cable channels, cable diameter, clearance. |
| `cable_clip_small` | Same branch as `custom_cable_clip`. |
| `custom_screw_bracket` | Wall bracket with M3 cuts, rings, shelf, front lip. |
| `m3_wall_hook` | Same branch as `custom_screw_bracket`. |
| `custom_open_tray` | Open tray with walls and low front. |
| `bambu_a1_nozzle_holder` | Open tray plus six nozzle wells. |
| `battery_case_2cell` | Open tray plus center divider. |
| `custom_parametric_holder` | Generic holder with base, left/right rails, and back rail. |

`bambu_scraper_holder` and `homelab_label_holder` are known preset IDs, but currently do not have dedicated generation branches. They fall through to the generic holder branch unless later matched by custom profile logic before direct known-preset selection changes.

## Blender Primitive Helpers

The emitted Blender script defines:

- `mat(name, rgba)`: create material.
- `cube(name, loc, dim, material=None, bevel=0)`: add cube, apply dimensions, optional bevel/weighted normals.
- `cyl(name, loc, radius, depth, material=None, vertices=64, rotation=(0,0,0))`: add cylinder with optional material.
- `txt(name, bodytxt, loc, size, material=None, rotation=(0,0,0))`: add extruded text.
- `cut(target, cutter)`: Boolean difference and remove cutter.

## Generated Output Files

Worker run directory outputs:

- `run_metadata.txt`
- `worker_flow_debug.txt`
- `input_product.md`
- `input_debug.txt`
- `generated_model.py`
- `model.stl`
- `model.blend`
- `preview.png`
- `design_metadata.txt`
- `shape_intent_debug.txt`
- `output_status.txt`
- `validation.txt`
- `model.3mf`
- `README.md`
- `slicer_notes.md`
- `worker_error.txt` only on worker-level errors

`run_factory.py` also copies run output into `/data/products/<product_id>/output/` for latest-output compatibility.

## validation.txt Structure

Top key:

- `VALIDATION_STATUS=PASS|WARN|FAIL`

Sections:

- `## Summary`
- `## Files`
- `## Dimensions`
- `## Printability Checks`
- `## Parameter Checks`
- `## Warnings`
- `## Recommendations`

Important values emitted in text:

- STL path
- design profile
- material
- file presence for `model.blend`, `model.3mf`, `preview.png`, `README.md`
- width/depth/height
- base and wall thickness
- mesh vertex/face counts
- mesh watertight/winding status
- cable/magnet/hinge/clearance parameter checks

## design_metadata.txt Keys

Primary keys:

- `engine_version`
- `name`
- `category`
- `preset_id`
- `shape`
- `surface`
- `material`
- `mount_type`
- `width_mm`
- `depth_mm`
- `height_mm`
- `base_thickness_mm`
- `wall_thickness_mm`
- `design_profile`
- `cable_channels`
- `cable_diameter_mm`
- `magnet_diameter_mm`
- `magnet_thickness_mm`
- `hinge_count`
- `clearance_mm`
- `wants_grid`
- `wants_label`
- `wants_magnet`

Profile notes may append keys such as:

- `intent`
- `hinge_barrels`
- `separate_lid`
- `magnet_sockets`
- `channels`
- `m3_holes`
- `nozzle_wells`
- `slots`

## output_status.txt Keys

Written by `generate_blender_script.py`:

- `engine_version`
- `stl_path`
- `blend_path`
- `preview_path`
- `preview_status`
- `render_mode`
- `design_profile`

Appended by `generate_3mf_from_stl.py`:

- `three_mf_status`
- `three_mf_path`
- `three_mf_vertices`
- `three_mf_faces`
- `three_mf_watertight`
