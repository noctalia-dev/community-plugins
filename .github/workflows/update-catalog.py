#!/usr/bin/env python3

from __future__ import annotations

import re
import subprocess
import sys
import tomllib
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[2]
CATALOG_PATH = ROOT_DIR / "catalog.toml"
REQUIRED_FIELDS = ("id", "name", "version", "author", "plugin_api", "tags")
OPTIONAL_STRING_FIELDS = ("license", "icon", "description")
OPTIONAL_BOOL_FIELDS = ("deprecated",)

# Oldest plugin API any supported Noctalia accepts (kOldestSupportedPluginApiVersion in the
# shell's src/scripting/plugin_api.h). Release rows below it can never be installed, so the
# history walk stops there.
OLDEST_SUPPORTED_PLUGIN_API = 3


def git_commit_time(path: Path, *extra_args: str) -> int | None:
    """Commit time in Unix seconds, or None when `path` has no matching commit.

    An uncommitted plugin has no history, so `git log` prints nothing.
    """
    stdout = subprocess.run(
        ["git", "log", "-1", *extra_args, "--format=%ct", "--", path],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    return int(stdout) if stdout else None


def git_output(*args: str) -> str:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout


def release_history(subdir: str, tip_api: int) -> list[dict]:
    """Older revisions of a plugin, one per API level below the tip's, newest first.

    A Noctalia below the tip's `plugin_api` has nothing to install unless the catalog names
    a revision it can run. Walking `<subdir>/plugin.toml` newest-first and keeping only the
    revisions that lower the API level yields a strictly decreasing sequence, so each row is
    the newest revision at or below its own level -- exactly what the host resolves against.
    """
    releases = []
    lowest_api = tip_api
    revisions = git_output(
        "log", "--format=%H", "--", f"{subdir}/plugin.toml"
    ).split()

    for revision in revisions:
        if lowest_api <= OLDEST_SUPPORTED_PLUGIN_API:
            break
        try:
            manifest = tomllib.loads(
                git_output("show", f"{revision}:{subdir}/plugin.toml")
            )
        except (subprocess.CalledProcessError, tomllib.TOMLDecodeError):
            continue  # unreadable or pre-`plugin_api` history

        plugin_api = manifest.get("plugin_api")
        version = manifest.get("version")
        if not isinstance(plugin_api, int) or isinstance(plugin_api, bool):
            continue
        if not isinstance(version, str) or not version:
            continue
        if plugin_api >= lowest_api or plugin_api < OLDEST_SUPPORTED_PLUGIN_API:
            continue

        releases.append({"plugin_api": plugin_api, "version": version, "rev": revision})
        lowest_api = plugin_api

    return releases


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

    # Git dates a committed plugin, and is stable across checkouts. Anything git cannot date
    # falls back to the file's mtime: an uncommitted plugin still gets a sensible entry so the
    # catalog can be generated mid-development. (A rename also breaks the link to the commit
    # that first added the file, which is why added_at falls back too.)
    mtime = int(path.stat().st_mtime)
    out["updated_at"] = git_commit_time(path) or mtime
    out["added_at"] = git_commit_time(path, "--diff-filter=A") or out["updated_at"]

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
        manifest["releases"] = release_history(directory, manifest["plugin_api"])
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
        "# A [[plugin.release]] row names an older revision for a Noctalia below the tip's",
        "# plugin_api, so an older release stays installable instead of the plugin vanishing.",
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
                f"updated_at = {plugin['updated_at']}",
                f"added_at = {plugin['added_at']}",
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
        for release in plugin["releases"]:
            lines.extend(
                [
                    "",
                    "[[plugin.release]]",
                    f"plugin_api = {release['plugin_api']}",
                    f"version = {toml_string(release['version'])}",
                    f"rev = {toml_string(release['rev'])}",
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
