#!/usr/bin/env python3
"""Print a lightweight structure report for the 3D Model Factory repo."""

from __future__ import annotations

import ast
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def read_ast(path: Path) -> ast.AST | None:
    try:
        return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except Exception as exc:
        print(f"[WARN] failed to parse {rel(path)}: {exc!r}")
        return None


def route_decorators(node: ast.FunctionDef) -> list[tuple[str, str]]:
    routes = []
    for decorator in node.decorator_list:
        if not isinstance(decorator, ast.Call):
            continue
        func = decorator.func
        if not (
            isinstance(func, ast.Attribute)
            and isinstance(func.value, ast.Name)
            and func.value.id == "app"
        ):
            continue
        if func.attr.upper() not in {"GET", "POST", "PUT", "PATCH", "DELETE"}:
            continue
        if not decorator.args or not isinstance(decorator.args[0], ast.Constant):
            continue
        routes.append((func.attr.upper(), str(decorator.args[0].value)))
    return routes


def analyze_main() -> None:
    path = ROOT / "portal" / "app" / "main.py"
    tree = read_ast(path)
    if tree is None:
        return

    print("== portal/app/main.py ==")
    classes = [node.name for node in tree.body if isinstance(node, ast.ClassDef)]
    funcs = [node for node in tree.body if isinstance(node, ast.FunctionDef)]
    routes = []
    plain_funcs = []
    for func in funcs:
        decorators = route_decorators(func)
        if decorators:
            for method, route_path in decorators:
                routes.append((method, route_path, func.name))
        else:
            plain_funcs.append(func.name)

    print("Models:")
    for name in classes:
        print(f"  - {name}")

    print("Routes:")
    for method, route_path, name in routes:
        print(f"  - {method:6} {route_path:45} {name}")

    print("Top-level helper functions:")
    for name in plain_funcs:
        print(f"  - {name}")


def analyze_python_file(path: Path) -> None:
    tree = read_ast(path)
    if tree is None:
        return
    funcs = [node.name for node in tree.body if isinstance(node, ast.FunctionDef)]
    classes = [node.name for node in tree.body if isinstance(node, ast.ClassDef)]
    print(f"== {rel(path)} ==")
    if classes:
        print("Classes:")
        for name in classes:
            print(f"  - {name}")
    print("Functions:")
    for name in funcs:
        print(f"  - {name}")


def list_files(title: str, pattern: str) -> None:
    print(f"== {title} ==")
    for path in sorted(ROOT.glob(pattern)):
        if path.is_file():
            print(f"  - {rel(path)}")


def main() -> None:
    analyze_main()
    print()

    for path in [
        ROOT / "scripts" / "run_factory.py",
        ROOT / "scripts" / "generate_blender_script.py",
        ROOT / "scripts" / "validate_stl.py",
        ROOT / "scripts" / "create_report.py",
        ROOT / "scripts" / "generate_3mf_from_stl.py",
    ]:
        analyze_python_file(path)
        print()

    list_files("Templates", "portal/app/templates/*.html")
    print()
    list_files("Scripts", "scripts/*.py")
    print()
    list_files("Kubernetes YAML", "k8s/*.yaml")
    print()

    makefile = ROOT / "Makefile"
    print("== Makefile ==")
    if makefile.exists():
        targets = []
        for line in makefile.read_text(encoding="utf-8", errors="ignore").splitlines():
            if not line or line.startswith(".") or line.startswith(">") or "=" in line:
                continue
            if line.endswith(":"):
                targets.append(line[:-1])
        for target in targets:
            print(f"  - {target}")
    else:
        print("  - missing")


if __name__ == "__main__":
    main()
