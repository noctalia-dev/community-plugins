#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check the Noctalia plugin for the mistakes Noctalia would only tell you at runtime.

This is not a substitute for running the thing — it cannot tell you whether the
panel looks right. It catches the class of mistake that has actually cost time
here, all of which are invisible until Noctalia loads the plugin:

  * a script that is not valid Luau (a leading `#!` line is a shebang to Lua's
    loader but the length operator to Luau, so `luac -p` accepts what Noctalia
    rejects — checked explicitly because of that);
  * a call into an API member that does not exist, a `ui.*` control that is not
    one, or a `ui` prop nobody documented;
  * a `ui` callback naming a function the script never defines;
  * a translation key that does not resolve, either from a setting declared in the
    manifest or from `tr("...")` in a script — which would show up in the UI as
    the raw key;
  * a manifest that does not parse, or a plugin directory that does not match its
    id, which would stop the directory working as a plugin source;
  * a catalog.toml out of step with the manifest.

    python3 tests/plugin_check.py             # from the plugin directory

The API check downloads Noctalia's own type definitions and is skipped when there
is no network. It reads props out of literal tables only: a table assembled by a
helper (`ui.column(merge(CARD, extra), …)`) cannot be seen here, so keep the
shared styles somewhere a reviewer will look at them.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
API_URL = "https://raw.githubusercontent.com/noctalia-dev/official-plugins/main/noctalia.d.luau"

problems = []
notes = []


def fail(message):
    problems.append(message)


def load(path):
    with open(path, "rb") as handle:
        return tomllib.load(handle)


def flatten(node, prefix=""):
    """Dotted paths out of the nested translations, which is how they are looked up.

    The file is nested on purpose: the store's keys are single lowercase segments,
    and the i18n platform expands a dotted key into objects on the next sync.
    """
    out = {}
    if not isinstance(node, dict):
        return out
    for key, value in node.items():
        path = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            out.update(flatten(value, path))
        else:
            out[path] = value
    return out


# --------------------------------------------------------------- source text

def strip_comments(text):
    """Lua comments out, everything else as written.

    Comments matter here: these files discuss `ui.button` and `panel.render` in
    prose, and a comment about an API member the script does not call is not a
    problem to report.
    """
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("--[[", i) or text.startswith("--[=[", i):
            close = text.find("]]", i)
            i = n if close == -1 else close + 2
            continue
        if text.startswith("--", i):
            end = text.find("\n", i)
            i = n if end == -1 else end
            continue
        if text[i] in "\"'":
            quote, start = text[i], i
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            out.append(text[start:i])
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def strip_strings(text):
    """String literals out, so their contents are not read as code."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text[i] in "\"'":
            quote = text[i]
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            out.append('""')
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def balanced(text, start):
    """The {...} that begins at start, brace-balanced, plus its depth-1 keys.

    A key is an identifier that follows `{` or `,` and precedes a single `=` —
    which is what a props table looks like, and what keeps `x = 1` inside a
    closure body (no comma in front of it) out of the list. Brace depth alone
    cannot tell those apart, since a function body adds no braces.
    """
    depth, keys, i, n = 0, [], start, len(text)
    while i < n:
        char = text[i]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1], keys
        elif depth == 1 and char == "=" and i + 1 < n and text[i + 1] not in "=<>~":
            match = re.search(r"[{,}\s]\s*([A-Za-z_][A-Za-z0-9_]*)\s*$", text[start:i])
            if match:
                keys.append(match.group(1))
        i += 1
    return text[start:], keys


def api_surface(api):
    """Members of each namespace, the ui controls, and every documented ui prop."""

    def members(text):
        return set(re.findall(r"^\s*([a-zA-Z_][A-Za-z0-9_]*)\s*[:(]", text, re.M))

    def type_block(name):
        match = re.search(r"export type " + name + r" = \{", api)
        return balanced(api, match.end() - 1)[0] if match else ""

    def declare_block(name):
        match = re.search(r"declare " + name + r":\s*(\{)", api)
        if match:
            return balanced(api, match.end() - 1)[0]
        match = re.search(r"declare " + name + r":\s*(\w+)", api)
        return type_block(match.group(1)) if match else ""

    props = set()
    for name in re.findall(r"export type (Ui\w*Props) = \{", api):
        props |= members(type_block(name))

    return {
        "noctalia": members(declare_block("noctalia")) | {"state", "json", "string", "sound"},
        "barWidget": members(declare_block("barWidget")),
        "panel": members(declare_block("panel")),
        "ui": members(declare_block("ui")),
        "props": props,
        "nested": {
            "state": members(type_block("NoctaliaState")),
            "json": members(type_block("NoctaliaJson")),
            "string": members(type_block("NoctaliaString")),
        },
    }


# ------------------------------------------------------------------- manifest

def check_manifest(source_dir):
    manifest_path = os.path.join(source_dir, "plugin.toml")
    try:
        manifest = load(manifest_path)
    except (OSError, tomllib.TOMLDecodeError) as error:
        fail(f"plugin.toml: {error}")
        return None, {}

    for field in ("id", "name", "version", "plugin_api"):
        if field not in manifest:
            fail(f"plugin.toml: {field} is required")
    if not re.fullmatch(r"\d+\.\d+\.\d+", str(manifest.get("version", ""))):
        fail(f"plugin.toml: version {manifest.get('version')!r} is not MAJOR.MINOR.PATCH")
    if not isinstance(manifest.get("plugin_api"), int) or manifest["plugin_api"] <= 0:
        fail("plugin.toml: plugin_api must be a positive integer")

    plugin_id = manifest.get("id", "")
    if plugin_id:
        part = plugin_id.split("/")[-1]
        if part != os.path.basename(source_dir):
            fail(
                f"plugin.toml: id {plugin_id!r} means this directory must be named "
                f"{part!r}, not {os.path.basename(source_dir)!r} (a source repo, and a "
                "path source, hold each plugin under the part of its id after the slash)"
            )

    for kind in ("widget", "panel", "shortcut", "launcher_provider", "desktop_widget", "service"):
        for entry in manifest.get(kind, []):
            path = os.path.join(source_dir, entry.get("entry", ""))
            if not os.path.isfile(path):
                fail(f"plugin.toml: [[{kind}]] entry {entry.get('entry')!r} does not exist")

    translations = {}
    translations_path = os.path.join(source_dir, "translations", "en.json")
    if os.path.isfile(translations_path):
        try:
            translations = flatten(json.load(open(translations_path, encoding="utf-8")))
        except (OSError, json.JSONDecodeError) as error:
            fail(f"translations/en.json: {error}")
    else:
        fail("translations/en.json is missing")

    wanted = []
    blocks = list(manifest.get("setting", []))
    for kind in ("widget", "panel", "shortcut", "desktop_widget"):
        for entry in manifest.get(kind, []):
            blocks += entry.get("setting", [])
    for block in blocks:
        for key in ("label_key", "description_key"):
            if key in block:
                wanted.append(block[key])
        for option in block.get("options", []):
            wanted.append(option["label_key"])
    for key in wanted:
        if key not in translations:
            fail(f"translations/en.json: {key!r} is referenced by the manifest but missing")
    notes.append(f"{len(wanted)} translation keys referenced by the manifest, {len(translations)} defined")

    return manifest, translations


def check_catalog(source_dir, manifest):
    catalog_path = os.path.join(source_dir, "catalog.toml")
    if not os.path.isfile(catalog_path):
        notes.append("no catalog.toml next to the plugin: it can still be a path source")
        return
    if manifest is None:
        return
    rows = {row.get("id"): row for row in load(catalog_path).get("plugin", [])}
    row = rows.get(manifest.get("id"))
    if row is None:
        fail(f"catalog.toml: no row for {manifest.get('id')!r}")
        return
    for field in ("name", "version", "plugin_api", "author", "icon", "description", "tags"):
        if row.get(field) != manifest.get(field):
            fail(f"catalog.toml: {field} is {row.get(field)!r}, manifest says {manifest.get(field)!r}")


# -------------------------------------------------------------------- scripts

# "panel" is two things in these scripts: Noctalia's declarative surface, and the
# object the tool's own JSON document carries under that name (see the report
# contract in the project README). Only the first is an API namespace, so the
# second's fields are not looked up there.
JSON_PANEL_FIELDS = {"model", "short", "percent", "percentText", "level", "resetsIn", "text"}


def check_forward_references(name, code):
    """A `local function` called above its own definition is a nil global.

    The second bug of this kind in one session: the name is not yet a local where
    the call sits, so Lua compiles it as a global lookup, and there is no such
    global — every call raises. A `local name` above the calls (a forward
    declaration) is what makes it safe, which is why that counts as declared.
    """
    lines = code.split("\n")
    for match in re.finditer(r"^local function ([A-Za-z_][A-Za-z0-9_]*)", code, re.M):
        function = match.group(1)
        defined_at = code[:match.start()].count("\n") + 1
        if re.search(r"^local " + function + r"\s*$", code[:match.start()], re.M):
            continue
        for number, text in enumerate(lines[:defined_at - 1], start=1):
            if re.search(r"(?<![\w.])" + function + r"\s*\(", text):
                fail(
                    f"{name}: {function}() is called on line {number} but declared "
                    f"`local function` on line {defined_at}; a name that is not yet a local "
                    f"is a global lookup, which raises. Move the definition up, or add "
                    f"`local {function}` above its callers."
                )
                break


def check_scripts(source_dir, surface, translations):
    for name in sorted(os.listdir(source_dir)):
        if not name.endswith(".luau"):
            continue
        path = os.path.join(source_dir, name)
        original = open(path, encoding="utf-8").read()
        without_comments = strip_comments(original)
        code = strip_strings(without_comments)
        first = original.split("\n", 1)[0]

        # The one that bit: Lua tolerates a leading '#', Luau does not, so
        # `luac -p` passes a file Noctalia cannot load.
        if first.startswith("#"):
            fail(f"{name}: starts with {first!r}; Luau has no shebang handling, so this is a "
                 "syntax error (write a --! directive instead)")
        elif not first.startswith("--"):
            fail(f"{name}: first line {first!r} is not a comment")

        luac = shutil.which("luac") or shutil.which("luac5.4")
        if luac:
            result = subprocess.run([luac, "-p", path], capture_output=True, text=True)
            if result.returncode != 0:
                fail(f"{name}: {result.stderr.strip()}")
        else:
            notes.append("luac is not installed: syntax was not checked")

        for key in re.findall(r"\b(?:noctalia\.)?tr\(\s*\"([^\"]+)\"", without_comments):
            if key not in translations:
                fail(f"{name}: tr({key!r}) has no entry in translations/en.json")

        check_forward_references(name, code)

        if not surface:
            continue
        for namespace, member in re.findall(r"\b(noctalia|barWidget|panel)\.([A-Za-z_][A-Za-z0-9_]*)", code):
            if namespace == "panel" and member in JSON_PANEL_FIELDS:
                continue
            if member not in surface[namespace]:
                fail(f"{name}: {namespace}.{member} is not in Noctalia's API")
        for outer, member in re.findall(r"\bnoctalia\.(state|json|string)\.([A-Za-z_][A-Za-z0-9_]*)", code):
            if member not in surface["nested"][outer]:
                fail(f"{name}: noctalia.{outer}.{member} is not in Noctalia's API")
        for match in re.finditer(r"\bui\.([a-zA-Z_][A-Za-z0-9_]*)\(", code):
            control = match.group(1)
            if control not in surface["ui"]:
                fail(f"{name}: ui.{control} is not a control")
                continue
            opening = code.find("{", match.end())
            if opening == -1 or code[match.end():opening].strip():
                continue
            _, props = balanced(code, opening)
            for prop in props:
                if prop not in surface["props"]:
                    fail(f"{name}: ui.{control} prop {prop!r} is not documented")
        # A callback can be named as a string anywhere — `onClick = "x"`, or an
        # argument to a helper like iconButton(...) — and either way the global
        # has to exist or the click does nothing.
        for handler in set(re.findall(r'"([A-Za-z_][A-Za-z0-9_]*)"', without_comments)):
            if not re.fullmatch(r"on[A-Z][A-Za-z0-9]*", handler):
                continue
            if not re.search(r"^function " + handler + r"\(", without_comments, re.M):
                fail(f"{name}: {handler!r} is named as a callback but never defined")


def main():
    # The plugin is one level up: this file lives in its tests/ directory.
    source_dir = os.path.normpath(os.path.join(HERE, ".."))
    if not os.path.isdir(source_dir):
        print(f"no plugin directory at {source_dir}", file=sys.stderr)
        return 2

    manifest, translations = check_manifest(source_dir)
    check_catalog(source_dir, manifest)

    surface = None
    try:
        with urllib.request.urlopen(API_URL, timeout=20) as response:
            surface = api_surface(response.read().decode("utf-8"))
        if not surface["ui"] or not surface["props"]:
            fail("could not parse Noctalia's API definitions")
            surface = None
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        notes.append(f"API check skipped, no network ({error})")

    check_scripts(source_dir, surface, translations)

    for note in notes:
        print(f"note: {note}")
    if problems:
        print()
        for problem in problems:
            print(f"problem: {problem}")
        print(f"\n{len(problems)} problem(s)")
        return 1
    checked = "including the API surface" if surface else "manifest, translations and syntax only"
    print(f"ok: {os.path.basename(source_dir)} checks out ({checked})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
