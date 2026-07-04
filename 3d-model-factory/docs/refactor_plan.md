# Refactor Plan

This is a preparation document only. Do not move runtime code until each step has a focused verification pass.

## Current Structure Summary

### Portal

`portal/app/main.py` currently contains:

- FastAPI app construction.
- SQLAlchemy setup and models.
- Startup DB creation/column migration/seed logic.
- Product creation, edit, detail, rerun, run compare, download routes.
- Preset API and management routes.
- `product.md` writer.
- Kubernetes Job builder.
- Run directory helpers and run metadata writer.
- Debug/validation text readers.
- Product status refresh from Kubernetes.

SQLAlchemy models:

- `ProductRequest`
- `ProductPreset`
- `ProductFile`
- `GenerationJob`

Route groups:

- Health/debug: `/healthz`, `/debug`, `/dbcheck`
- Index: `/`
- Presets: `/api/presets`, `/presets`, `/presets/new`, `/presets`, `/presets/{preset_id}/edit`, `/presets/{preset_id}/delete`
- Products: `/products/new`, `/products`, `/products/{product_id}`, `/products/{product_id}/edit`, `/products/{product_id}/rerun`
- Runs: `/products/{product_id}/compare`
- Downloads: `/products/{product_id}/download/{subdir}/{filename}`, `/products/{product_id}/download/runs/{run_number}/{filename}`

Product.md generation:

- `write_product_md`
- `product_base_dir`
- `product_container_base_dir`

Kubernetes Job generation:

- `create_blender_job`
- env contract: `PRODUCT_ID`, `PRODUCT_MD`, `OUTPUT_DIR`, `RUN_NUMBER`, `WORKER_IMAGE`, `USE_GPU`, `GPU_TASK`
- PVC mount contract: `/data`

Preset functions:

- `preset_custom_dict`
- `number_or_empty`
- `preset_to_dict`
- `active_preset_dicts`
- `seed_default_presets_if_empty`
- `update_preset_from_form`

Run history functions:

- `run_dir_for`
- `run_container_dir_for`
- `next_run_number`
- `write_run_metadata`
- `collect_runs`
- `available_run_numbers`
- `parse_run_selection`
- `collect_compare_runs`

Debug/validation file readers:

- `read_limited_text`
- `parse_key_value_text`
- `validation_status_from_text`
- `collect_debug_texts`

Download routes:

- `download_file`
- `download_run_file`

Templates:

- `base.html`
- `index.html`
- `new_product.html`
- `edit_product.html`
- `product_detail.html`
- `product_compare.html`
- `presets.html`
- `preset_form.html`

### Worker

`scripts/run_factory.py`:

- Reads Worker env vars.
- Resolves run directory and product.md path.
- Writes `run_metadata.txt`.
- Copies `product.md` to run-local debug files.
- Refuses portal-mode generation if `PRODUCT_MD` is missing.
- Runs `generate_blender_script.py`.
- Runs Blender with generated Python.
- Runs validation, 3MF export, report generation.
- Copies run files to latest compatibility `output/`.

`scripts/generate_blender_script.py`:

- Parses `product.md`.
- Selects design profile from known preset IDs and keyword intent.
- Emits Blender Python to `/workspace/blender/generated_model.py`.
- The emitted script defines primitive helpers and profile branches.
- Writes `design_metadata.txt`, `shape_intent_debug.txt`, `output_status.txt`.

`scripts/validate_stl.py`:

- Reads `design_metadata.txt`.
- Loads `model.stl` via `trimesh`.
- Checks output file presence, dimensions, build volume, thickness, profile parameters, and mesh quality.
- Writes `validation.txt`.

`scripts/create_report.py`:

- Reads `validation.txt`, `design_metadata.txt`, `output_status.txt`, and optional product.md.
- Writes `README.md` and `slicer_notes.md`.

`scripts/generate_3mf_from_stl.py`:

- Converts STL to minimal 3MF using `trimesh` and `zipfile`.
- Appends 3MF status lines to `output_status.txt`.

### Kubernetes and Makefile

`k8s/*.yaml` contains:

- `namespace.yaml`: namespace.
- `pvc.yaml`: shared model storage PVC.
- `job-template.yaml`: manual worker job template.
- `gpu-test.yaml`: GPU smoke test pod.
- `secret-openai.example.yaml`: example secret.
- `harness-delegate-rbac.yaml`: delegate permissions for jobs and related resources.

`Makefile` contains:

- worker image build/push/apply/run/logs/clean targets.
- portal image build/push/apply/restart/url targets.

## Problems

- `main.py` mixes persistence, routing, filesystem IO, Kubernetes API calls, template context assembly, and form mapping.
- Route handlers contain repeated form signatures and job creation error handling.
- Preset serialization and product form behavior are tightly coupled to templates.
- Run comparison, debug file reading, and latest-output compatibility logic are spread across route helpers.
- Worker script generation uses one large embedded Python string, making profile changes risky.
- Shape intent selection is coupled to Blender emission.
- Metadata keys are implicit strings repeated across Portal compare/debug and Worker generation/validation.
- There is no stable service boundary for testing product.md generation, run discovery, preset CRUD, or job launch behavior independently.

## Refactoring Goals

- Keep current behavior and storage contracts stable.
- Separate DB models/session setup from route handlers.
- Move filesystem and run helpers behind small service modules.
- Move Kubernetes Job construction into one job runner module.
- Keep product.md generation deterministic and testable.
- Split Worker parser, intent selection, profile generation, and output writing.
- Make metadata/output key contracts explicit.
- Enable small unit tests around parser/profile selection and Portal service helpers before deeper changes.

## Proposed Target Structure

Portal:

```text
portal/app/main.py
portal/app/db.py
portal/app/models.py
portal/app/product_md.py
portal/app/job_runner.py
portal/app/preset_service.py
portal/app/run_service.py
portal/app/file_reader.py
portal/app/routes/products.py
portal/app/routes/presets.py
portal/app/routes/health.py
portal/app/routes/downloads.py
```

Worker:

```text
scripts/run_factory.py
scripts/worker_io.py
scripts/product_parser.py
scripts/shape_intent.py
scripts/blender_profiles.py
scripts/blender_emit.py
scripts/validate_stl.py
scripts/generate_3mf_from_stl.py
scripts/create_report.py
```

## Step-by-Step Separation Plan

### Step 1: Add Non-Behavioral Tests and Snapshots

Scope:

- Add tests or smoke scripts for route extraction, preset API shape, product.md shape, and run directory discovery.
- Capture example output of `/api/presets` and a representative `product.md`.

Risk: low.

Verification:

```bash
python3 -m py_compile portal/app/main.py
python3 -m py_compile scripts/analyze_project_structure.py
python3 scripts/analyze_project_structure.py
```

Rollback:

- Remove added tests/scripts only.

### Step 2: Extract DB Setup and Models

Move:

- `engine`, `SessionLocal`, `Base`, `get_db` to `portal/app/db.py`.
- SQLAlchemy models to `portal/app/models.py`.
- Startup column ensure/seed calls remain invoked by `main.py`.

Risk: medium. SQLAlchemy import order and metadata registration can break table creation.

Verification:

```bash
python3 -m py_compile portal/app/main.py portal/app/db.py portal/app/models.py
python3 scripts/analyze_project_structure.py
```

Rollback:

- Revert model/db extraction commit.
- Confirm `Base.metadata.create_all(bind=engine)` again sees all models.

### Step 3: Extract File and Run Services

Move:

- `product_base_dir`, `run_dir_for`, `next_run_number`, `collect_runs`, `available_run_numbers`, `parse_run_selection`, `collect_compare_runs` to `run_service.py`.
- `read_limited_text`, `parse_key_value_text`, `validation_status_from_text`, `collect_debug_texts` to `file_reader.py`.

Risk: medium. Path contracts and missing-file behavior must remain identical.

Verification:

```bash
python3 -m py_compile portal/app/main.py portal/app/run_service.py portal/app/file_reader.py
python3 scripts/analyze_project_structure.py
```

Manual checks:

- Product detail loads while output files are missing.
- Run compare with no `runs` param.
- Run compare with `?runs=1,missing,abc`.

Rollback:

- Revert extraction commit.

### Step 4: Extract Product.md Writer

Move:

- `write_product_md` to `product_md.py`.
- Keep exact output headings and field names.

Risk: medium. Worker parser depends on exact key labels.

Verification:

```bash
python3 -m py_compile portal/app/main.py portal/app/product_md.py
```

Manual checks:

- Create/edit product.
- Confirm `/data/products/<product_id>/input/product.md` still exists.
- Confirm Worker still parses dimensions and parameters.

Rollback:

- Revert product_md extraction.

### Step 5: Extract Kubernetes Job Runner

Move:

- `create_blender_job` and Kubernetes-specific constants into `job_runner.py`.
- Keep env var names and PVC mount path unchanged.

Risk: high. Job creation failures affect generation.

Verification:

```bash
python3 -m py_compile portal/app/main.py portal/app/job_runner.py
```

Manual checks:

- Create product.
- Edit product.
- Rerun product.
- Inspect Job env vars: `PRODUCT_ID`, `PRODUCT_MD`, `OUTPUT_DIR`, `RUN_NUMBER`.

Rollback:

- Revert job_runner extraction.

### Step 6: Extract Preset Service and Routes

Move:

- Preset serialization, seed, form mapper to `preset_service.py`.
- Preset route handlers to `routes/presets.py`.

Risk: medium. `/api/presets` JSON compatibility and new/edit form contexts can regress.

Verification:

```bash
python3 -m py_compile portal/app/main.py portal/app/preset_service.py portal/app/routes/presets.py
```

Manual checks:

- `/api/presets` shape.
- `/presets`, create/edit/deactivate.
- New product preset auto-fill.
- Edit product preset auto-fill.

Rollback:

- Revert preset service/routes extraction.

### Step 7: Extract Product Routes

Move:

- Product routes to `routes/products.py`.
- Download routes may move to `routes/downloads.py`.
- Keep route registration order explicit.

Risk: high. Dynamic route ordering can break `/products/{product_id}/edit` and `/compare`.

Verification:

```bash
python3 -m py_compile portal/app/main.py portal/app/routes/products.py portal/app/routes/downloads.py
python3 scripts/analyze_project_structure.py
```

Manual checks:

- `/products/new`
- create product
- product detail
- edit product
- rerun
- compare
- both download route families

Rollback:

- Revert route extraction commit.

### Step 8: Worker Parser and Intent Split

Move:

- `read_md`, `find_value`, `find_number`, `bval`, `has`, `channels` to `product_parser.py`.
- Intent selection to `shape_intent.py`.
- Keep generated metadata keys unchanged.

Risk: high. Product-to-profile selection changes can silently alter geometry.

Verification:

```bash
python3 -m py_compile scripts/generate_blender_script.py scripts/product_parser.py scripts/shape_intent.py
```

Manual checks:

- Run sample product.md for each profile.
- Compare selected `design_profile` before/after.
- Confirm `shape_intent_debug.txt` still exists.

Rollback:

- Revert worker parser/intent extraction.

### Step 9: Worker Blender Emit/Profile Split

Move:

- Primitive helper string to `blender_emit.py`.
- Profile branches to `blender_profiles.py`.
- Keep `generate_blender_script.py` as orchestrator.

Risk: high. Embedded Blender Python is sensitive to quoting, indentation, and runtime-only Blender APIs.

Verification:

```bash
python3 -m py_compile scripts/generate_blender_script.py scripts/blender_emit.py scripts/blender_profiles.py
```

Manual checks:

- Full Worker run in Kubernetes.
- Confirm `model.stl`, `model.blend`, `preview.png`, `design_metadata.txt`, `output_status.txt`.

Rollback:

- Revert Blender split commit.

## Absolute Compatibility Requirements

Do not break:

- `product.md` path: `/data/products/<product_id>/input/product.md`
- run output path: `/data/products/<product_id>/runs/<run_number>/`
- latest compatibility path: `/data/products/<product_id>/output/`
- download route: `/products/{product_id}/download/{subdir}/{filename}`
- run download route: `/products/{product_id}/download/runs/{run_number}/{filename}`
- `/api/presets` response structure: `{"presets": [...]}` with fields used by product form JavaScript
- existing product detail page behavior
- Kubernetes Job env vars:
  - `PRODUCT_ID`
  - `PRODUCT_MD`
  - `OUTPUT_DIR`
  - `RUN_NUMBER`
  - `WORKER_IMAGE`
  - `USE_GPU`
  - `GPU_TASK`
- Worker run metadata file name: `run_metadata.txt`
- Worker generated files used by Portal:
  - `preview.png`
  - `validation.txt`
  - `design_metadata.txt`
  - `output_status.txt`
  - `model.stl`
  - `model.3mf`

## General Rollback Method

- Keep each extraction as a separate commit.
- If behavior changes, revert only the latest extraction commit.
- Prefer moving code without changing function bodies in the first pass.
- After each move, run py_compile and route analysis.
- For high-risk Worker changes, compare `design_metadata.txt`, `output_status.txt`, and `validation.txt` from before/after runs.
