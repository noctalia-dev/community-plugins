#!/usr/bin/env python3
"""Self-test for the lyrics adapter and the plugin manifest.

Usage:  python3 bin/selftest.py [--verbose]
Returns 1 if anything fails.

Nothing here talks to the network: `urllib.request.urlopen` is replaced by a
double, and the cache lives in a temporary directory. No bytecode is written
next to the plugin.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import types

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.realpath(__file__))
PLUGIN_DIR = os.path.dirname(HERE)
FETCH = os.path.join(HERE, "lyrics-fetch.py")
MANIFEST = os.path.join(PLUGIN_DIR, "plugin.toml")
TRANSLATIONS = os.path.join(PLUGIN_DIR, "translations", "en.json")

results = []


def check(name: str, ok: bool, detail: str = ""):
    results.append((name, bool(ok), detail))
    return bool(ok)


def load_adapter():
    loader = importlib.machinery.SourceFileLoader("lyrics_fetch", FETCH)
    spec = importlib.util.spec_from_loader("lyrics_fetch", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def fake_open(responses):
    """Replace urlopen with a scripted responder.

    `responses` maps a URL prefix to a value: a dict (JSON body), an int (HTTP
    status), or an Exception instance. Every call is recorded.
    """
    import urllib.error

    calls = []

    def urlopen(request, timeout=None):
        url = request.full_url if hasattr(request, "full_url") else str(request)
        calls.append(url)
        for prefix, value in responses.items():
            if url.startswith(prefix):
                if isinstance(value, Exception):
                    raise value
                if isinstance(value, int):
                    raise urllib.error.HTTPError(url, value, "error", {}, None)
                return _Response(json.dumps(value).encode("utf-8"))
        raise urllib.error.HTTPError(url, 404, "not found", {}, None)

    return urlopen, calls


class _Response:
    def __init__(self, payload: bytes):
        self.payload = payload

    def read(self):
        return self.payload

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def run() -> int:
    module = load_adapter()

    # -- LRC parsing ------------------------------------------------------
    lines = module.parse_lrc("[00:12.34]hello")
    check("parse: one line", len(lines) == 1, str(lines))
    if lines:
        check("parse: start", abs(lines[0]["start"] - 12.34) < 1e-6, str(lines[0]))
        check("parse: text", lines[0]["text"] == "hello", str(lines[0]))
        check("parse: no word timings", lines[0].get("chars") is None, str(lines[0]))

    lines = module.parse_lrc("[00:12.34]\n[00:20.00]next")
    check("parse: empty line kept", len(lines) == 2, str(lines))
    check("parse: empty text", lines and lines[0]["text"] == "", str(lines))

    lines = module.parse_lrc("[00:30.00]b\n[00:10.00]a")
    check("parse: sorted", [item["text"] for item in lines] == ["a", "b"], str(lines))
    check(
        "parse: end is the next start",
        lines and abs(lines[0]["end"] - 30.0) < 1e-6,
        str(lines),
    )

    long_gap = module.parse_lrc("[00:10.00]a\n[01:40.00]b")
    check(
        "parse: no 10 second cap",
        long_gap and abs(long_gap[0]["end"] - 100.0) < 1e-6,
        str(long_gap),
    )

    # -- word timings -----------------------------------------------------
    lines = module.parse_lrc("[00:12.34]<00:12.34>hel<00:12.60>lo")
    chars = lines[0].get("chars") if lines else None
    check("chars: present", isinstance(chars, list), str(lines))
    check("chars: one per character", chars and len(chars) == 5, str(chars))
    check(
        "chars: values follow the tags",
        chars and abs(chars[0] - 12.34) < 1e-6 and abs(chars[-1] - 12.60) < 1e-6,
        str(chars),
    )

    # -- text hygiene -----------------------------------------------------
    check(
        "text: full-width punctuation folded",
        module.normalize_text("hola，mundo！") == "hola,mundo!",
        module.normalize_text("hola，mundo！"),
    )

    # -- plain lyrics -----------------------------------------------------
    plain = module.plain_lines("one\ntwo\nthree", 30.0)
    check("plain: three lines", len(plain) == 3, str(plain))
    check("plain: evenly spaced", abs(plain[1]["start"] - 10.0) < 1e-6, str(plain))
    check("plain: no chars", all("chars" not in item for item in plain), str(plain))

    # -- network ----------------------------------------------------------
    original = module.urllib.request.urlopen
    try:
        urlopen, calls = fake_open(
            {module.LRCLIB_GET: {"syncedLyrics": "[00:01.00]hi"}}
        )
        module.urllib.request.urlopen = urlopen
        result = module.fetch("song", "artist", 120.0)
        check("fetch: synced", result.get("ok") and result.get("synced"), str(result))
        check("fetch: one call", len(calls) == 1, str(calls))

        urlopen, calls = fake_open(
            {
                module.LRCLIB_GET: 404,
                module.LRCLIB_SEARCH: [{"syncedLyrics": "[00:05.00]found"}],
            }
        )
        module.urllib.request.urlopen = urlopen
        result = module.fetch("song", "artist", 120.0)
        check("fetch: falls back to search", result.get("ok"), str(result))
        check("fetch: two calls", len(calls) == 2, str(calls))

        # No artist (some MPRIS players report none): search with the title.
        urlopen, calls = fake_open(
            {module.LRCLIB_SEARCH: [{"syncedLyrics": "[00:05.00]no artist"}]}
        )
        module.urllib.request.urlopen = urlopen
        result = module.fetch("song", "", 120.0)
        check("fetch: without an artist it searches", result.get("ok"), str(result))
        check("fetch: without an artist one call", len(calls) == 1, str(calls))
        check("fetch: the call is a search", "/api/search" in calls[0], str(calls))

        # "Title - Artist" in the title with no artist reported: split it.
        urlopen, calls = fake_open(
            {module.LRCLIB_GET: {"syncedLyrics": "[00:02.00]split"}}
        )
        module.urllib.request.urlopen = urlopen
        result = module.fetch("Song - Band", "", 120.0)
        check("fetch: the title is split", result.get("ok"), str(result))
        check("fetch: split uses one get", len(calls) == 1, str(calls))
        check("fetch: split sends the artist", "artist_name=Band" in calls[0], str(calls))

        urlopen, calls = fake_open({})
        module.urllib.request.urlopen = urlopen
        check(
            "fetch: not found is data",
            module.fetch("song", "artist", 120.0).get("ok") is False,
            str(module.fetch("song", "artist", 120.0)),
        )

        urlopen, calls = fake_open({module.LRCLIB_GET: ValueError("bad json")})
        module.urllib.request.urlopen = urlopen
        result = module.fetch("song", "artist", 120.0)
        check("fetch: bad json does not raise", result.get("ok") is False, str(result))

        urlopen, calls = fake_open(
            {module.LRCLIB_GET: {"plainLyrics": "one\ntwo"}}
        )
        module.urllib.request.urlopen = urlopen
        result = module.fetch("song", "artist", 120.0)
        check(
            "fetch: plain lyrics are not synced",
            result.get("ok") and result.get("synced") is False,
            str(result),
        )

        # -- cache --------------------------------------------------------
        with tempfile.TemporaryDirectory(prefix="lyrics-carousel-cache-") as box:
            os.environ["XDG_CACHE_HOME"] = box
            urlopen, calls = fake_open(
                {module.LRCLIB_GET: {"syncedLyrics": "[00:01.00]cached"}}
            )
            module.urllib.request.urlopen = urlopen
            first = module.result_for("song", "artist", 120.0, False, 1.0)
            second = module.result_for("song", "artist", 120.0, False, 1.0)
            check("cache: first result ok", first.get("ok"), str(first))
            check("cache: second result ok", second.get("ok"), str(second))
            check("cache: second is cached", second.get("cached") is True, str(second))
            check("cache: one request", len(calls) == 1, str(calls))
            forced = module.result_for("song", "artist", 120.0, True, 1.0)
            check("cache: force refetches", forced.get("cached") is not True, str(forced))
    finally:
        module.urllib.request.urlopen = original
        os.environ.pop("XDG_CACHE_HOME", None)

    # -- manifest ---------------------------------------------------------
    try:
        import tomllib

        with open(MANIFEST, "rb") as handle:
            manifest = tomllib.load(handle)
    except Exception as error:  # noqa: BLE001
        check("manifest: readable", False, str(error))
        manifest = None

    if manifest is not None:
        check(
            "manifest: no kitty/hyprland/Pillow",
            all(
                name not in manifest.get("dependencies", [])
                for name in ("kitty", "hyprland", "hyprctl", "python-pillow", "fc-match")
            ),
            str(manifest.get("dependencies")),
        )
        check(
            "manifest: dependencies",
            manifest.get("dependencies") == ["playerctl", "python3"],
            str(manifest.get("dependencies")),
        )
        check("manifest: plugin_api", manifest.get("plugin_api") == 34, str(manifest.get("plugin_api")))

        entries = (
            ("widget", "widget.luau"),
            ("panel", "panel.luau"),
            ("desktop_widget", "desktop.luau"),
            ("service", "service.luau"),
            ("shortcut", "shortcut.luau"),
        )
        for key, entry in entries:
            block = manifest.get(key)
            found = bool(block) and block[0].get("entry") == entry
            check(f"manifest: {key} entry", found, str(block))
            check(
                f"manifest: {key} file exists",
                os.path.isfile(os.path.join(PLUGIN_DIR, entry)),
                entry,
            )

        settings = manifest.get("setting", [])
        declared = {item.get("key", "") for item in settings}
        expected = {
            "font_size", "direction", "marker", "marker_style", "karaoke", "ghost",
            "header", "footer", "spacing", "active_scale", "visible_above",
            "visible_below", "accent", "custom_color", "offset_ms", "instrumental",
            "instrumental_icon", "instrumental_text", "silence_threshold",
        }
        check(
            "manifest: settings declared",
            expected <= declared,
            str(sorted(expected - declared)),
        )
        keys = set()
        for item in settings:
            key = item.get("key", "")
            keys.add(key)
            check(f"manifest: {key} has label", bool(item.get("label_key")), str(item))
            if item.get("type") in ("int", "double"):
                default = item.get("default")
                low, high = item.get("min"), item.get("max")
                inside = (
                    isinstance(default, (int, float))
                    and (low is None or default >= low)
                    and (high is None or default <= high)
                )
                check(f"manifest: {key} default in range", inside, str(item))
            if item.get("type") == "select":
                values = [option.get("value") for option in item.get("options", [])]
                check(
                    f"manifest: {key} default is an option",
                    item.get("default") in values,
                    str(values),
                )
                for option in item.get("options", []):
                    check(
                        f"manifest: {key} option label",
                        bool(option.get("label_key")),
                        str(option),
                    )

        try:
            with open(TRANSLATIONS, encoding="utf-8") as handle:
                translations = json.load(handle)
        except (OSError, ValueError) as error:  # noqa: BLE001
            check("translations: readable", False, str(error))
            translations = {}

        def flatten(data, prefix=""):
            found = []
            for key, value in data.items():
                name = f"{prefix}{key}"
                if isinstance(value, dict):
                    found.extend(flatten(value, name + "."))
                else:
                    found.append(name)
            return found

        flat = set(flatten(translations))
        for key in sorted(keys):
            check(
                f"translations: {key} label",
                f"settings.{key}.label" in flat,
                "missing settings.%s.label" % key,
            )
            for item in settings:
                if item.get("key") == key and item.get("type") == "select":
                    for option in item.get("options", []):
                        label = option.get("label_key", "")
                        check(f"translations: {label}", label in flat, label)

    # -- readme -----------------------------------------------------------
    readme_path = os.path.join(PLUGIN_DIR, "README.md")
    readme = ""
    try:
        with open(readme_path, encoding="utf-8") as handle:
            readme = handle.read()
    except OSError as error:
        check("readme: present", False, str(error))
    if readme:
        check("readme: present", True)
        settings = manifest.get("settings") or []
        for key in sorted(key for item in settings for key in [item.get("key")]):
            if key is None:
                continue
            check(
                f"readme: {key} documented",
                f"`{key}`" in readme,
                "the settings table does not mention " + key,
            )
        for entry in ("widget", "panel", "desktop"):
            check(f"readme: {entry} entry", f"`{entry}.luau`" in readme or entry in readme)
        for banned in ("kitty", "Hyprland", "Pillow"):
            check(
                f"readme: no {banned} requirement",
                banned.lower() not in readme.lower(),
                "the readme still asks for " + banned,
            )

    # -- result -----------------------------------------------------------
    failures = [item for item in results if not item[1]]
    if "--verbose" in sys.argv:
        for name, ok, detail in results:
            print(("ok   " if ok else "FAIL ") + name + ("  " + detail if detail else ""))
    if failures:
        print(f"{len(failures)} of {len(results)} checks failed", file=sys.stderr)
        return 1
    print(f"{len(results)} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(run())
