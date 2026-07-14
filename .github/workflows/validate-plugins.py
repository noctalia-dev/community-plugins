#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path(__file__).resolve().parents[2]
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")
LAUNCHER_PREFIX_RE = re.compile(r"^[a-z]+$")
ALLOWED_TAGS = {
    "ai",
    "animation",
    "arch",
    "audio",
    "bar",
    "clock",
    "countdown",
    "demo",
    "debian",
    "desktop",
    "development",
    "emoticon",
    "fedora",
    "fun",
    "gaming",
    "gentoo",
    "hardware",
    "hyprland",
    "indicator",
    "labwc",
    "language",
    "launcher",
    "mangowc",
    "media",
    "music",
    "network",
    "niri",
    "nixos",
    "opensuse",
    "panel",
    "privacy",
    "productivity",
    "recording",
    "service",
    "shortcut",
    "sway",
    "system",
    "theming",
    "time",
    "utility",
    "video",
    "void",
    "wallpaper",
}

# An id segment must be a lowercase flat identifier: the part after the "/" is also the
# plugin's directory here, its export directory on disk, and its slug on the website.
ID_SEGMENT_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
# Names the website reserves for its own routes; a plugin folder cannot take one.
RESERVED_NAMES = {"license", "readme", "index", "api", "admin", "static", "assets"}

# Files every published plugin ships: the site renders the README as the plugin page and
# the thumbnail as its card, and the English catalog backs every label_key.
REQUIRED_PLUGIN_FILES = ("README.md", "thumbnail.webp", "translations/en.json")
THUMBNAIL_MAX_BYTES = 512 * 1024
# The store and the website lay out plugin cards on a fixed 16:9 grid, so the thumbnail
# generator exports exactly this.
THUMBNAIL_SIZE = (960, 540)
THUMBNAIL_GENERATOR_URL = "https://assets.noctalia.dev/plugins/thumbnail-generator.html"
WEBP_MAGIC_PREFIX = b"RIFF"
WEBP_MAGIC_FORMAT = b"WEBP"
# Enough of the file to cover the RIFF header plus the first chunk header and the widest
# dimension field of any WebP variant.
WEBP_HEADER_BYTES = 32

ROOT_STRING_FIELDS = (
    "id",
    "name",
    "version",
    "min_noctalia",
    "author",
    "license",
    "icon",
    "description",
)
ROOT_ARRAY_FIELDS = ("dependencies", "tags")
ENTRY_TYPES = ("widget", "panel", "shortcut", "desktop_widget", "launcher_provider", "service")
SETTING_OWNER_TYPES = ("widget", "panel", "desktop_widget", "launcher_provider")
SETTING_TYPES = {"string", "string_list", "bool", "glyph", "select", "folder", "file", "int", "color"}
PANEL_PLACEMENTS = {"attached", "floating"}
PANEL_POSITIONS = {
    "auto",
    "center",
    "top_left",
    "top_center",
    "top_right",
    "center_left",
    "center_right",
    "bottom_left",
    "bottom_center",
    "bottom_right",
}

ROOT_FIELDS = set(ROOT_STRING_FIELDS) | set(ROOT_ARRAY_FIELDS) | set(ENTRY_TYPES) | {
    "setting",
    "deprecated",
}
BASE_ENTRY_FIELDS = {"id", "entry"}
ENTRY_FIELDS = {
    "widget": BASE_ENTRY_FIELDS | {"setting"},
    "panel": BASE_ENTRY_FIELDS | {"setting", "width", "height", "placement", "position", "open_near_click"},
    "desktop_widget": BASE_ENTRY_FIELDS | {"setting"},
    "service": BASE_ENTRY_FIELDS,
    "shortcut": BASE_ENTRY_FIELDS,
    "launcher_provider": BASE_ENTRY_FIELDS
    | {"prefix", "glyph", "include_in_global_search", "debounce_ms", "setting", "category"},
}
CATEGORY_FIELDS = {"label", "glyph"}
SETTING_FIELDS = {
    "key",
    "type",
    "label_key",
    "description_key",
    "default",
    "options",
    "min",
    "max",
    "step",
    "visible_when",
    "advanced",
}
OPTION_FIELDS = {"value", "label_key"}
VISIBLE_WHEN_FIELDS = {"key", "values"}

# Raw HTML is not supported on plugin pages. Markdown autolinks such as
# <https://example.com> do not match this expression.
HTML_RE = re.compile(
    r"<!--|<\?|<!\[CDATA\[|<![A-Z]|"
    r"</[A-Za-z][A-Za-z0-9-]*\s*>|"
    r"<[A-Za-z][A-Za-z0-9-]*"
    r"(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*"
    r"(?:\s*=\s*(?:[^\s\"'=<>`]+|'[^']*'|\"[^\"]*\"))?)*\s*/?>",
    re.DOTALL,
)
INLINE_CODE_RE = re.compile(r"(?<!`)(`+)(?!`)(.*?)(?<!`)\1(?!`)", re.DOTALL)
FENCE_OPEN_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
OBSOLETE_CONFIG_ACCESSOR_RE = re.compile(
    r"\b(barWidget|desktopWidget|panel|launcher)\s*\.\s*getConfig\b"
)


def is_non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and value.strip() != ""


def is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value: Any) -> bool:
    return isinstance(value, int | float) and not isinstance(value, bool)


def rel(root: Path, path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def raw_html_line(markdown: str) -> int | None:
    """Return the first line containing raw HTML outside Markdown code, if any."""
    visible: list[str] = []
    fence_char = ""
    fence_length = 0

    for line in markdown.splitlines(keepends=True):
        if fence_char:
            closing = rf"^ {{0,3}}{re.escape(fence_char)}{{{fence_length},}}\s*$"
            if re.match(closing, line.rstrip("\r\n")):
                fence_char = ""
                fence_length = 0
            visible.append("\n" if line.endswith(("\n", "\r")) else "")
            continue

        opening = FENCE_OPEN_RE.match(line)
        if opening:
            fence = opening.group(1)
            fence_char = fence[0]
            fence_length = len(fence)
            visible.append("\n" if line.endswith(("\n", "\r")) else "")
            continue

        visible.append(line)

    text = "".join(visible)
    text = INLINE_CODE_RE.sub(
        lambda match: "".join("\n" if char == "\n" else " " for char in match.group(0)),
        text,
    )
    match = HTML_RE.search(text)
    if match is None:
        return None
    return text.count("\n", 0, match.start()) + 1


def obsolete_config_accessors(source: str) -> list[tuple[str, int]]:
    """Find removed entry-specific getConfig aliases outside Luau comments and strings."""
    visible = list(source)
    length = len(source)
    index = 0

    def mask(start: int, end: int) -> None:
        for offset in range(start, end):
            if visible[offset] not in "\r\n":
                visible[offset] = " "

    while index < length:
        if source.startswith("--[[", index):
            end = source.find("]]", index + 4)
            end = length if end == -1 else end + 2
            mask(index, end)
            index = end
            continue

        if source.startswith("--", index):
            end = source.find("\n", index + 2)
            end = length if end == -1 else end
            mask(index, end)
            index = end
            continue

        if source.startswith("[[", index):
            end = source.find("]]", index + 2)
            end = length if end == -1 else end + 2
            mask(index, end)
            index = end
            continue

        if source[index] in "\"'":
            quote = source[index]
            end = index + 1
            while end < length:
                if source[end] == "\\" and end + 1 < length:
                    end += 2
                    continue
                end += 1
                if source[end - 1] == quote:
                    break
            mask(index, end)
            index = end
            continue

        index += 1

    code = "".join(visible)
    return [
        (f"{match.group(1)}.getConfig", code.count("\n", 0, match.start()) + 1)
        for match in OBSOLETE_CONFIG_ACCESSOR_RE.finditer(code)
    ]


def webp_dimensions(header: bytes) -> tuple[int, int] | None:
    """Width and height from a WebP header, or None if it is not one we can read.

    The three container variants each store the size differently, and the generator's
    output is only one of them, so all three are handled.
    """
    if len(header) < 16 or header[:4] != WEBP_MAGIC_PREFIX or header[8:12] != WEBP_MAGIC_FORMAT:
        return None

    fourcc = header[12:16]
    payload = header[20:]

    if fourcc == b"VP8X":
        # Extended: 4 bytes of flags, then canvas width and height as 24-bit values,
        # each stored as size minus one.
        if len(payload) < 10:
            return None
        width = int.from_bytes(payload[4:7], "little") + 1
        height = int.from_bytes(payload[7:10], "little") + 1
        return width, height

    if fourcc == b"VP8 ":
        # Lossy: a 3-byte frame tag, the start code, then two 14-bit dimensions.
        if len(payload) < 10 or payload[3:6] != b"\x9d\x01\x2a":
            return None
        width = int.from_bytes(payload[6:8], "little") & 0x3FFF
        height = int.from_bytes(payload[8:10], "little") & 0x3FFF
        return width, height

    if fourcc == b"VP8L":
        # Lossless: a signature byte, then both dimensions minus one packed into 28 bits.
        if len(payload) < 5 or payload[0] != 0x2F:
            return None
        bits = int.from_bytes(payload[1:5], "little")
        width = (bits & 0x3FFF) + 1
        height = ((bits >> 14) & 0x3FFF) + 1
        return width, height

    return None


def has_key_path(data: Any, dotted_key: str) -> bool:
    if isinstance(data, dict) and dotted_key in data:
        return True

    current = data
    for part in dotted_key.split("."):
        if not isinstance(current, dict) or part not in current:
            return False
        current = current[part]
    return True


class Validator:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self.errors: list[str] = []

    def add_error(self, path: Path, message: str) -> None:
        self.errors.append(f"{rel(self.root, path)}: {message}")

    def add_context_error(self, path: Path, context: str, message: str) -> None:
        self.add_error(path, f"{context}: {message}")

    def load_manifest(self, path: Path) -> dict[str, Any] | None:
        try:
            with path.open("rb") as handle:
                manifest = tomllib.load(handle)
        except tomllib.TOMLDecodeError as error:
            self.add_error(path, f"invalid TOML: {error}")
            return None

        if not isinstance(manifest, dict):
            self.add_error(path, "expected a TOML table")
            return None
        return manifest

    def load_english_translations(self, plugin_dir: Path) -> Any | None:
        path = plugin_dir / "translations" / "en.json"
        if not path.exists():
            return None

        try:
            with path.open("r", encoding="utf-8") as handle:
                translations = json.load(handle)
        except json.JSONDecodeError as error:
            self.add_error(path, f"invalid JSON: {error}")
            return None

        if not isinstance(translations, dict):
            self.add_error(path, "expected a JSON object")
            return None
        return translations

    def validate_translation_key(
        self,
        manifest_path: Path,
        translations: Any | None,
        context: str,
        field: str,
        value: Any,
    ) -> None:
        if not is_non_empty_string(value):
            self.add_context_error(manifest_path, context, f"{field} must be a non-empty string")
            return

        if translations is None:
            self.add_context_error(
                manifest_path,
                context,
                f"{field} references '{value}', but translations/en.json is missing or invalid",
            )
            return

        if not has_key_path(translations, value):
            self.add_context_error(
                manifest_path,
                context,
                f"{field} references missing translations/en.json key '{value}'",
            )

    def validate_string_list(
        self,
        manifest_path: Path,
        context: str,
        field: str,
        value: Any,
        *,
        allow_empty: bool,
    ) -> None:
        if not isinstance(value, list):
            self.add_context_error(manifest_path, context, f"{field} must be a list of strings")
            return

        if not allow_empty and not value:
            self.add_context_error(manifest_path, context, f"{field} must not be empty")

        seen: set[str] = set()
        for index, item in enumerate(value):
            if not is_non_empty_string(item):
                self.add_context_error(
                    manifest_path,
                    context,
                    f"{field}[{index}] must be a non-empty string",
                )
                continue
            if item in seen:
                self.add_context_error(manifest_path, context, f"{field} contains duplicate '{item}'")
            seen.add(item)

    def validate_tags(self, manifest_path: Path, value: Any) -> None:
        self.validate_string_list(manifest_path, "root", "tags", value, allow_empty=False)
        if not isinstance(value, list):
            return

        for index, tag in enumerate(value):
            if is_non_empty_string(tag) and tag not in ALLOWED_TAGS:
                self.add_context_error(
                    manifest_path,
                    "root",
                    f"tags[{index}] '{tag}' is not an allowed tag",
                )

    def validate_root_fields(self, manifest_path: Path, manifest: dict[str, Any]) -> None:
        unknown = sorted(set(manifest) - ROOT_FIELDS)
        for field in unknown:
            self.add_error(manifest_path, f"unknown root field '{field}'")

        for field in ROOT_STRING_FIELDS:
            if field not in manifest:
                self.add_error(manifest_path, f"missing required root field '{field}'")
            elif not is_non_empty_string(manifest[field]):
                self.add_error(manifest_path, f"root field '{field}' must be a non-empty string")

        for field in ROOT_ARRAY_FIELDS:
            if field not in manifest:
                self.add_error(manifest_path, f"missing required root field '{field}'")

        if "dependencies" in manifest:
            self.validate_string_list(
                manifest_path,
                "root",
                "dependencies",
                manifest["dependencies"],
                allow_empty=True,
            )

        if "tags" in manifest:
            self.validate_tags(manifest_path, manifest["tags"])

        if "deprecated" in manifest and not isinstance(manifest["deprecated"], bool):
            self.add_error(manifest_path, "root field 'deprecated' must be a bool")

        # A plugin id is "<author>/<plugin>", and the part after the "/" is the directory
        # it lives in - so a folder name is taken once for the whole repo.
        folder = manifest_path.parent.name
        plugin_id = manifest.get("id")
        if is_non_empty_string(plugin_id):
            author, _, name = plugin_id.partition("/")
            if name != folder:
                self.add_error(manifest_path, f"id must be '<author>/{folder}', matching the directory name")
            for label, segment in (("author", author), ("plugin", name)):
                if not ID_SEGMENT_RE.fullmatch(segment):
                    self.add_error(
                        manifest_path,
                        f"id {label} '{segment}' must be lowercase and match {ID_SEGMENT_RE.pattern}",
                    )

        if folder in RESERVED_NAMES:
            self.add_error(manifest_path, f"'{folder}' is a reserved name and cannot be a plugin directory")

        for field in ("version", "min_noctalia"):
            value = manifest.get(field)
            if is_non_empty_string(value) and not SEMVER_RE.fullmatch(value):
                self.add_error(manifest_path, f"root field '{field}' must use MAJOR.MINOR.PATCH")

    def validate_entry_path(self, manifest_path: Path, context: str, plugin_dir: Path, value: Any) -> None:
        if not is_non_empty_string(value):
            self.add_context_error(manifest_path, context, "entry must be a non-empty string")
            return

        raw_path = Path(value)
        if raw_path.is_absolute() or ".." in raw_path.parts:
            self.add_context_error(manifest_path, context, "entry must stay inside the plugin directory")
            return

        entry_path = plugin_dir / raw_path
        try:
            entry_path.resolve().relative_to(plugin_dir.resolve())
        except ValueError:
            self.add_context_error(manifest_path, context, "entry must stay inside the plugin directory")
            return

        if not entry_path.is_file():
            self.add_context_error(
                manifest_path,
                context,
                f"entry file '{value}' does not exist",
            )

    def validate_launcher_fields(self, manifest_path: Path, context: str, entry: dict[str, Any]) -> None:
        for field in ("prefix", "glyph"):
            if field in entry and not is_non_empty_string(entry[field]):
                self.add_context_error(manifest_path, context, f"{field} must be a non-empty string")

        prefix = entry.get("prefix")
        if is_non_empty_string(prefix) and not LAUNCHER_PREFIX_RE.fullmatch(prefix):
            self.add_context_error(
                manifest_path,
                context,
                "prefix must contain only lowercase letters (a-z), without a leading symbol",
            )

        if "include_in_global_search" in entry and not isinstance(entry["include_in_global_search"], bool):
            self.add_context_error(
                manifest_path,
                context,
                "include_in_global_search must be a bool",
            )

        if "debounce_ms" in entry:
            debounce_ms = entry["debounce_ms"]
            if not is_int(debounce_ms) or debounce_ms < 0:
                self.add_context_error(
                    manifest_path,
                    context,
                    "debounce_ms must be a non-negative integer",
                )

        if "category" in entry:
            self.validate_launcher_categories(manifest_path, f"{context}.category", entry["category"])

    def validate_launcher_categories(self, manifest_path: Path, context: str, categories: Any) -> None:
        if not isinstance(categories, list):
            self.add_context_error(manifest_path, context, "must be an array of tables")
            return

        if not categories:
            self.add_context_error(manifest_path, context, "must not be empty")

        seen_labels: set[str] = set()
        for index, category in enumerate(categories):
            category_context = f"{context}[{index}]"
            if not isinstance(category, dict):
                self.add_context_error(manifest_path, category_context, "must be a table")
                continue

            unknown = sorted(set(category) - CATEGORY_FIELDS)
            for field in unknown:
                self.add_context_error(manifest_path, category_context, f"unknown field '{field}'")

            label = category.get("label")
            if not is_non_empty_string(label):
                self.add_context_error(manifest_path, category_context, "label must be a non-empty string")
            elif label in seen_labels:
                self.add_context_error(manifest_path, category_context, f"duplicate category label '{label}'")
            else:
                seen_labels.add(label)

            if not is_non_empty_string(category.get("glyph")):
                self.add_context_error(manifest_path, category_context, "glyph must be a non-empty string")

    def validate_panel_fields(self, manifest_path: Path, context: str, entry: dict[str, Any]) -> None:
        # Mirrors the shell parser: a positive number (logical px) or the
        # literal string "fill" (span the output's available extent; requires
        # floating placement).
        uses_fill = False
        for field in ("width", "height"):
            if field not in entry:
                continue

            value = entry[field]
            if isinstance(value, str):
                if value != "fill":
                    self.add_context_error(manifest_path, context, f'{field} must be a positive number or "fill"')
                else:
                    uses_fill = True
            elif not is_number(value) or value <= 0:
                self.add_context_error(manifest_path, context, f'{field} must be a positive number or "fill"')

        if uses_fill and entry.get("placement", "floating") != "floating":
            self.add_context_error(manifest_path, context, 'width/height "fill" requires placement = "floating"')

        if "placement" in entry:
            placement = entry["placement"]
            if not is_non_empty_string(placement):
                self.add_context_error(manifest_path, context, "placement must be a non-empty string")
            elif placement not in PANEL_PLACEMENTS:
                valid = ", ".join(sorted(PANEL_PLACEMENTS))
                self.add_context_error(manifest_path, context, f"placement must be one of: {valid}")

        if "position" in entry:
            position = entry["position"]
            if not is_non_empty_string(position):
                self.add_context_error(manifest_path, context, "position must be a non-empty string")
            elif position not in PANEL_POSITIONS:
                valid = ", ".join(sorted(PANEL_POSITIONS))
                self.add_context_error(manifest_path, context, f"position must be one of: {valid}")

        if "open_near_click" in entry and not isinstance(entry["open_near_click"], bool):
            self.add_context_error(manifest_path, context, "open_near_click must be a bool")

    def validate_entries(
        self,
        manifest_path: Path,
        manifest: dict[str, Any],
        translations: Any | None,
    ) -> None:
        plugin_dir = manifest_path.parent
        entry_count = 0
        seen_ids: dict[str, str] = {}

        for entry_type in ENTRY_TYPES:
            entries = manifest.get(entry_type, [])
            if not isinstance(entries, list):
                self.add_error(manifest_path, f"'{entry_type}' must be an array of tables")
                continue

            for index, entry in enumerate(entries):
                entry_count += 1
                context = f"{entry_type}[{index}]"
                if not isinstance(entry, dict):
                    self.add_context_error(manifest_path, context, "must be a table")
                    continue

                unknown = sorted(set(entry) - ENTRY_FIELDS[entry_type])
                for field in unknown:
                    self.add_context_error(manifest_path, context, f"unknown field '{field}'")

                entry_id = entry.get("id")
                if not is_non_empty_string(entry_id):
                    self.add_context_error(manifest_path, context, "id must be a non-empty string")
                elif entry_id in seen_ids:
                    self.add_context_error(
                        manifest_path,
                        context,
                        f"id '{entry_id}' is already used by {seen_ids[entry_id]}",
                    )
                else:
                    seen_ids[entry_id] = context

                self.validate_entry_path(manifest_path, context, plugin_dir, entry.get("entry"))

                if entry_type == "launcher_provider":
                    self.validate_launcher_fields(manifest_path, context, entry)

                if entry_type == "panel":
                    self.validate_panel_fields(manifest_path, context, entry)

                if entry_type in SETTING_OWNER_TYPES and "setting" in entry:
                    self.validate_settings(
                        manifest_path,
                        translations,
                        entry["setting"],
                        f"{context}.setting",
                    )

        if entry_count == 0:
            self.add_error(
                manifest_path,
                "must define at least one entry: widget, panel, shortcut, desktop_widget, launcher_provider, or service",
            )

    def validate_default(
        self,
        manifest_path: Path,
        context: str,
        setting_type: str,
        setting: dict[str, Any],
        option_values: list[str],
    ) -> None:
        if "default" not in setting:
            if setting_type not in {"folder", "file"}:
                self.add_context_error(manifest_path, context, "default is required")
            return

        default = setting["default"]
        if setting_type in {"string", "folder", "file"} and not isinstance(default, str):
            self.add_context_error(manifest_path, context, "default must be a string")
        elif setting_type in {"glyph", "color"} and not is_non_empty_string(default):
            self.add_context_error(manifest_path, context, "default must be a non-empty string")
        elif setting_type == "string_list":
            self.validate_string_list(manifest_path, context, "default", default, allow_empty=True)
        elif setting_type == "bool" and not isinstance(default, bool):
            self.add_context_error(manifest_path, context, "default must be a bool")
        elif setting_type == "int" and not is_int(default):
            self.add_context_error(manifest_path, context, "default must be an integer")
        elif setting_type == "select":
            if not is_non_empty_string(default):
                self.add_context_error(manifest_path, context, "default must be a non-empty string")
            elif default not in option_values:
                self.add_context_error(manifest_path, context, "default must match one of the option values")

    def validate_options(
        self,
        manifest_path: Path,
        translations: Any | None,
        context: str,
        setting: dict[str, Any],
    ) -> list[str]:
        options = setting.get("options")
        setting_type = setting.get("type")

        if options is None:
            if setting_type == "select":
                self.add_context_error(manifest_path, context, "select settings require options")
            return []

        if setting_type != "select":
            self.add_context_error(manifest_path, context, "options is only valid for select settings")

        if not isinstance(options, list):
            self.add_context_error(manifest_path, context, "options must be a list of tables")
            return []

        if not options:
            self.add_context_error(manifest_path, context, "options must not be empty")

        values: list[str] = []
        seen: set[str] = set()
        for index, option in enumerate(options):
            option_context = f"{context}.options[{index}]"
            if not isinstance(option, dict):
                self.add_context_error(manifest_path, option_context, "must be a table")
                continue

            unknown = sorted(set(option) - OPTION_FIELDS)
            for field in unknown:
                self.add_context_error(manifest_path, option_context, f"unknown field '{field}'")

            value = option.get("value")
            if not is_non_empty_string(value):
                self.add_context_error(manifest_path, option_context, "value must be a non-empty string")
            else:
                values.append(value)
                if value in seen:
                    self.add_context_error(
                        manifest_path,
                        option_context,
                        f"duplicate option value '{value}'",
                    )
                seen.add(value)

            self.validate_translation_key(
                manifest_path,
                translations,
                option_context,
                "label_key",
                option.get("label_key"),
            )

        return values

    def validate_int_bounds(self, manifest_path: Path, context: str, setting: dict[str, Any]) -> None:
        setting_type = setting.get("type")
        bound_values: dict[str, int] = {}

        for field in ("min", "max", "step"):
            if field not in setting:
                continue
            value = setting[field]
            if setting_type != "int":
                self.add_context_error(manifest_path, context, f"{field} is only valid for int settings")
            elif not is_int(value):
                self.add_context_error(manifest_path, context, f"{field} must be an integer")
            else:
                bound_values[field] = value

        if "min" in bound_values and "max" in bound_values and bound_values["min"] > bound_values["max"]:
            self.add_context_error(manifest_path, context, "min must be less than or equal to max")

        if "step" in bound_values and bound_values["step"] <= 0:
            self.add_context_error(manifest_path, context, "step must be greater than zero")

        default = setting.get("default")
        if setting_type == "int" and is_int(default):
            if "min" in bound_values and default < bound_values["min"]:
                self.add_context_error(manifest_path, context, "default must be greater than or equal to min")
            if "max" in bound_values and default > bound_values["max"]:
                self.add_context_error(manifest_path, context, "default must be less than or equal to max")

    def validate_visible_when(self, manifest_path: Path, context: str, value: Any) -> None:
        if value is None:
            return

        if not isinstance(value, dict):
            self.add_context_error(manifest_path, context, "visible_when must be a table")
            return

        unknown = sorted(set(value) - VISIBLE_WHEN_FIELDS)
        for field in unknown:
            self.add_context_error(manifest_path, context, f"visible_when has unknown field '{field}'")

        if not is_non_empty_string(value.get("key")):
            self.add_context_error(manifest_path, context, "visible_when.key must be a non-empty string")

        values = value.get("values")
        if not isinstance(values, list) or not values:
            self.add_context_error(
                manifest_path,
                context,
                "visible_when.values must be a non-empty list of strings",
            )
            return

        for index, item in enumerate(values):
            if not is_non_empty_string(item):
                self.add_context_error(
                    manifest_path,
                    context,
                    f"visible_when.values[{index}] must be a non-empty string",
                )

    def validate_settings(
        self,
        manifest_path: Path,
        translations: Any | None,
        settings: Any,
        context_prefix: str,
    ) -> None:
        if not isinstance(settings, list):
            self.add_context_error(manifest_path, context_prefix, "must be an array of tables")
            return

        seen_keys: set[str] = set()
        for index, setting in enumerate(settings):
            context = f"{context_prefix}[{index}]"
            if not isinstance(setting, dict):
                self.add_context_error(manifest_path, context, "must be a table")
                continue

            unknown = sorted(set(setting) - SETTING_FIELDS)
            for field in unknown:
                self.add_context_error(manifest_path, context, f"unknown field '{field}'")

            key = setting.get("key")
            if not is_non_empty_string(key):
                self.add_context_error(manifest_path, context, "key must be a non-empty string")
            elif key in seen_keys:
                self.add_context_error(manifest_path, context, f"duplicate setting key '{key}'")
            else:
                seen_keys.add(key)

            setting_type = setting.get("type")
            if not is_non_empty_string(setting_type):
                self.add_context_error(manifest_path, context, "type must be a non-empty string")
                setting_type = ""
            elif setting_type not in SETTING_TYPES:
                self.add_context_error(manifest_path, context, f"unsupported setting type '{setting_type}'")

            self.validate_translation_key(
                manifest_path,
                translations,
                context,
                "label_key",
                setting.get("label_key"),
            )

            if "description_key" in setting:
                self.validate_translation_key(
                    manifest_path,
                    translations,
                    context,
                    "description_key",
                    setting.get("description_key"),
                )

            option_values = self.validate_options(manifest_path, translations, context, setting)
            if setting_type in SETTING_TYPES:
                self.validate_default(manifest_path, context, setting_type, setting, option_values)

            self.validate_int_bounds(manifest_path, context, setting)
            self.validate_visible_when(manifest_path, context, setting.get("visible_when"))

            if "advanced" in setting and not isinstance(setting["advanced"], bool):
                self.add_context_error(manifest_path, context, "advanced must be a bool")

    def validate_required_files(self, manifest_path: Path, plugin_dir: Path) -> None:
        for required in REQUIRED_PLUGIN_FILES:
            if not (plugin_dir / required).is_file():
                self.add_error(manifest_path, f"missing required file '{required}'")

    def validate_thumbnail(self, manifest_path: Path, plugin_dir: Path) -> None:
        thumbnail = plugin_dir / "thumbnail.webp"
        if not thumbnail.is_file():
            return

        size = thumbnail.stat().st_size
        if size > THUMBNAIL_MAX_BYTES:
            self.add_error(
                manifest_path,
                f"thumbnail.webp is {size} bytes; keep it under {THUMBNAIL_MAX_BYTES}",
            )

        with thumbnail.open("rb") as handle:
            header = handle.read(WEBP_HEADER_BYTES)
        if header[:4] != WEBP_MAGIC_PREFIX or header[8:12] != WEBP_MAGIC_FORMAT:
            self.add_error(manifest_path, "thumbnail.webp is not a WebP image")
            return

        dimensions = webp_dimensions(header)
        expected = f"{THUMBNAIL_SIZE[0]}x{THUMBNAIL_SIZE[1]}"
        if dimensions is None:
            self.add_error(
                manifest_path,
                f"thumbnail.webp dimensions could not be read; export a {expected} WebP "
                f"with {THUMBNAIL_GENERATOR_URL}",
            )
            return

        if dimensions != THUMBNAIL_SIZE:
            self.add_error(
                manifest_path,
                f"thumbnail.webp is {dimensions[0]}x{dimensions[1]}; it must be {expected}. "
                f"Export one with {THUMBNAIL_GENERATOR_URL}",
            )

    def validate_readme(self, plugin_dir: Path) -> None:
        readme = plugin_dir / "README.md"
        if not readme.is_file():
            return

        try:
            contents = readme.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            self.add_error(readme, "must be UTF-8 text")
            return

        line = raw_html_line(contents)
        if line is not None:
            self.add_error(readme, f"raw HTML on line {line} is not allowed; use Markdown instead")

    def validate_luau_api(self, plugin_dir: Path) -> None:
        for source_path in sorted(plugin_dir.rglob("*.luau")):
            try:
                source = source_path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                self.add_error(source_path, "must be UTF-8 text")
                continue

            for accessor, line in obsolete_config_accessors(source):
                self.add_error(
                    source_path,
                    f"'{accessor}' on line {line} was removed; use noctalia.getConfig",
                )

    def validate_no_symlinks(self, manifest_path: Path, plugin_dir: Path) -> None:
        for path in plugin_dir.rglob("*"):
            if path.is_symlink():
                self.add_error(manifest_path, f"'{rel(self.root, path)}' is a symlink; plugins ship real files")

    def validate_manifest(self, manifest_path: Path) -> None:
        manifest = self.load_manifest(manifest_path)
        if manifest is None:
            return

        plugin_dir = manifest_path.parent
        translations = self.load_english_translations(plugin_dir)

        self.validate_root_fields(manifest_path, manifest)
        self.validate_required_files(manifest_path, plugin_dir)
        self.validate_thumbnail(manifest_path, plugin_dir)
        self.validate_readme(plugin_dir)
        self.validate_luau_api(plugin_dir)
        self.validate_no_symlinks(manifest_path, plugin_dir)

        if "setting" in manifest:
            self.validate_settings(manifest_path, translations, manifest["setting"], "setting")

        self.validate_entries(manifest_path, manifest, translations)

    def validate_layout(self) -> None:
        # Every plugin is one top-level directory. A manifest anywhere else (repo root, or
        # nested deeper) is never loaded by the shell, so fail loudly.
        for manifest_path in self.root.rglob("plugin.toml"):
            if ".git" in manifest_path.parts:
                continue
            depth = len(manifest_path.relative_to(self.root).parts)
            if depth != 2:
                self.add_error(manifest_path, "plugins live at <plugin>/plugin.toml, one directory per plugin")

    def validate(self) -> int:
        self.validate_layout()
        manifests = sorted(self.root.glob("*/plugin.toml"))
        for manifest_path in manifests:
            self.validate_manifest(manifest_path)

        if self.errors:
            for error in self.errors:
                print(f"error: {error}", file=sys.stderr)
            return 1

        print(f"Validated {len(manifests)} plugin manifest(s).")
        return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate community Noctalia plugin manifests.")
    parser.add_argument(
        "--root",
        type=Path,
        default=DEFAULT_ROOT,
        help="Repository root to validate. Defaults to the current repository.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    return Validator(args.root).validate()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
