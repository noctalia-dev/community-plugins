#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
import tomllib
import subprocess
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[2]
CATALOG_PATH = ROOT_DIR / "catalog.toml"
REQUIRED_FIELDS = ("id", "name", "version", "author", "plugin_api", "tags")
OPTIONAL_STRING_FIELDS = ("license", "icon", "description")
OPTIONAL_BOOL_FIELDS = ("deprecated",)


def load_plugin_manifest(path: Path) -> dict:
    with path.open("rb") as handle:
        manifest = tomllib.load(handle)

    missing = [field for field in REQUIRED_FIELDS if field not in manifest]
    if missing:
        missing_fields = ", ".join(missing)
        raise ValueError(f"{path.relative_to(ROOT_DIR)} is missing: {missing_fields}")

    plugin_api = manifest["plugin_api"]
    if not isinstance(plugin_api, int) or isinstance(plugin_api, bool) or plugin_api <= 0:
        raise ValueError(
            f"{path.relative_to(ROOT_DIR)} has invalid plugin_api; expected a positive integer"
        )

    if not isinstance(manifest["tags"], list) or not all(
        isinstance(tag, str) for tag in manifest["tags"]
    ):
        raise ValueError(f"{path.relative_to(ROOT_DIR)} has invalid tags; expected strings")

    out = {field: manifest[field] for field in REQUIRED_FIELDS}
    for field in OPTIONAL_STRING_FIELDS:
        if field in manifest:
            if not isinstance(manifest[field], str):
                raise ValueError(f"{path.relative_to(ROOT_DIR)} has invalid {field}; expected string")
            out[field] = manifest[field]
    for field in OPTIONAL_BOOL_FIELDS:
        if field in manifest:
            if not isinstance(manifest[field], bool):
                raise ValueError(f"{path.relative_to(ROOT_DIR)} has invalid {field}; expected bool")
            out[field] = manifest[field]

    out["last_modified"] = int(subprocess.run(
        ["git", "log", "-1", "--format=%ct", "--", path],
        capture_output=True,
        text=True,
        check=True,
      ).stdout.strip())

    out["date_added"] = int(subprocess.run(
        ["git", "log", "-1", "--diff-filter=A", "--format=%ct", "--", path],
        capture_output=True,
        text=True,
        check=True
      ).stdout.strip())

    return out


def existing_catalog_order() -> dict[str, int]:
    if not CATALOG_PATH.exists():
        return {}

    content = CATALOG_PATH.read_text(encoding="utf-8")
    ids = re.findall(r'(?m)^id\s*=\s*"([^"]+)"', content)
    return {plugin_id: index for index, plugin_id in enumerate(ids)}


def discover_plugins() -> list[dict]:
    order = existing_catalog_order()
    plugins = []

    for manifest_path in sorted(ROOT_DIR.glob("*/plugin.toml")):
        manifest = load_plugin_manifest(manifest_path)
        directory = manifest_path.parent.name
        manifest["_directory"] = directory
        manifest["_order"] = order.get(manifest["id"], len(order))
        plugins.append(manifest)

    plugins.sort(key=lambda plugin: (plugin["_order"], plugin["_directory"]))
    return plugins


def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def toml_bool(value: bool) -> str:
    return "true" if value else "false"


def render_catalog(plugins: list[dict]) -> str:
    lines = [
        "# This file is auto-generated. Do not edit manually.",
        "# Do not include it in your commit.",
        "# Community Noctalia plugins catalog.",
        "# Index of every plugin this source ships: the minimum needed to render, search,",
        "# and compat-check the list. The per-plugin plugin.toml stays authoritative; the",
        "# host re-reads it on enable. Keep one [[plugin]] row per plugin subdirectory.",
        "",
    ]

    for index, plugin in enumerate(plugins):
        if index:
            lines.append("")

        lines.extend(
            [
                "[[plugin]]",
                f"id = {toml_string(plugin['id'])}",
                f"name = {toml_string(plugin['name'])}",
                f"version = {toml_string(plugin['version'])}",
                f"last_modified = {str(plugin['last_modified'])}",
                f"date_added = {str(plugin['date_added'])}",
                f"author = {toml_string(plugin['author'])}",
            ]
        )
        if "license" in plugin:
            lines.append(f"license = {toml_string(plugin['license'])}")
        if "icon" in plugin:
            lines.append(f"icon = {toml_string(plugin['icon'])}")
        if "description" in plugin:
            lines.append(f"description = {toml_string(plugin['description'])}")
        if "deprecated" in plugin:
            lines.append(f"deprecated = {toml_bool(plugin['deprecated'])}")
        lines.extend(
            [
                f"plugin_api = {plugin['plugin_api']}",
                "tags = ["
                + ", ".join(toml_string(tag) for tag in plugin["tags"])
                + "]",
            ]
        )

    return "\n".join(lines) + "\n"


def main() -> int:
    plugins = discover_plugins()
    CATALOG_PATH.write_text(render_catalog(plugins), encoding="utf-8")
    print(f"Updated {CATALOG_PATH.relative_to(ROOT_DIR)} with {len(plugins)} plugin(s).")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
