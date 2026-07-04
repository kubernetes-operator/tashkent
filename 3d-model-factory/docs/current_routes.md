# Current Portal Routes

This document reflects the current FastAPI routes in `portal/app/main.py`.

| Method | Path | Function | Purpose | Template | Related Paths |
|---|---|---|---|---|---|
| GET | `/api/presets` | `api_presets` | Return active presets as `{"presets": [...]}` for product forms. Includes synthetic `custom`. | none | `product_presets` table |
| GET | `/healthz` | `healthz` | Basic health check. | none | none |
| GET | `/debug` | `debug` | Print runtime config and path diagnostics. | none | `APP_DIR`, `TEMPLATE_DIR`, `STATIC_DIR`, `OUTPUT_DIR` |
| GET | `/dbcheck` | `dbcheck` | Check DB connectivity and product count. | none | `product_requests` table |
| GET | `/` | `index` | Product list. Refreshes latest Kubernetes job status opportunistically. | `index.html` | `product_requests`, `generation_jobs` |
| GET | `/presets` | `presets_index` | Preset management list. | `presets.html` | `product_presets` table |
| GET | `/presets/new` | `new_preset` | Preset creation form. | `preset_form.html` | `product_presets` table |
| POST | `/presets` | `create_preset` | Create a new active preset. | redirect | `product_presets` table |
| GET | `/presets/{preset_id}/edit` | `edit_preset_form` | Preset edit form. | `preset_form.html` | `product_presets` table |
| POST | `/presets/{preset_id}/edit` | `edit_preset` | Update preset and reactivate it. | redirect | `product_presets` table |
| POST | `/presets/{preset_id}/delete` | `delete_preset` | Soft delete preset by setting `is_active=false`. | redirect | `product_presets` table |
| GET | `/products/new` | `new_product` | Product creation form with DB-backed presets. | `new_product.html` | `/api/presets`, `product_presets` |
| POST | `/products` | `create_product` | Create product, write `product.md`, create run 1 metadata, launch Kubernetes Job. | redirect | `/data/products/<product_id>/input/product.md`, `/data/products/<product_id>/runs/1/` |
| GET | `/products/{product_id}/edit` | `edit_product_form` | Product edit form with existing product values. | `edit_product.html` | `product_requests`, `product_presets` |
| POST | `/products/{product_id}/edit` | `edit_product` | Update DB product values, rewrite `product.md`, create new run, launch Kubernetes Job. | redirect | `/data/products/<product_id>/input/product.md`, `/data/products/<product_id>/runs/<run_number>/` |
| GET | `/products/{product_id}/compare` | `compare_product_runs` | Compare selected runs or latest 3 runs. | `product_compare.html` | `/data/products/<product_id>/runs/<run_number>/` |
| GET | `/products/{product_id}` | `product_detail` | Product detail, files, jobs, run history, validation/debug text, preview. | `product_detail.html` | `/data/products/<product_id>/input/`, `/output/`, `/logs/`, `/runs/` |
| GET | `/products/{product_id}/download/{subdir}/{filename}` | `download_file` | Download current compatibility files from `input`, `output`, or `logs`. | none | `/data/products/<product_id>/<subdir>/<filename>` |
| GET | `/products/{product_id}/download/runs/{run_number}/{filename}` | `download_run_file` | Download run-specific file. | none | `/data/products/<product_id>/runs/<run_number>/<filename>` |
| POST | `/products/{product_id}/rerun` | `rerun_product` | Create a new run from the current `product.md` without changing DB product fields. | redirect | `/data/products/<product_id>/runs/<run_number>/` |

## Route Ordering Notes

- `/products/{product_id}/edit` and `/products/{product_id}/compare` must stay before `/products/{product_id}` so static suffixes are not interpreted as product IDs.
- Download routes validate `subdir`, `filename`, and run number. Keep path traversal protections when moving these routes.
- `/api/presets` response shape must remain compatible with existing JavaScript:

```json
{
  "presets": [
    {
      "id": "custom",
      "label": "직접 입력",
      "category": "",
      "description": "",
      "width_mm": "",
      "depth_mm": "",
      "height_mm": "",
      "shape": "",
      "color": "",
      "surface": "",
      "material": "PETG",
      "mount_type": "",
      "support_allowed": false,
      "printer_targets": "",
      "use_gpu": false,
      "gpu_task": "none",
      "cable_channels": 1,
      "cable_diameter_mm": 6.0,
      "magnet_diameter_mm": 10.0,
      "magnet_thickness_mm": 2.0,
      "hinge_count": 3,
      "clearance_mm": 0.3
    }
  ]
}
```
