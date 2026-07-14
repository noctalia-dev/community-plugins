#!/usr/bin/env python3
"""Structural regression checks for Keymap's source-backed command catalog."""

import json
import re
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
catalog = json.loads((ROOT / "command_library.json").read_text(encoding="utf-8"))
translations = json.loads((ROOT / "translations" / "en.json").read_text(encoding="utf-8"))
panel = (ROOT / "panel.luau").read_text(encoding="utf-8")

assert catalog["schema"] == 1
assert set(catalog["sources"]) == {"noctalia", "hyprland", "niri", "mangowc"}
assert all(catalog["sources"][source]["revision"] for source in catalog["sources"])

entries = catalog["entries"]
counts = Counter(entry["source"] for entry in entries)
assert counts == {"noctalia": 98, "hyprland": 51, "niri": 135, "mangowc": 78}, counts

ids = [entry["id"] for entry in entries]
assert len(ids) == len(set(ids)), "command-library ids must be unique"
assert ids == sorted(ids, key=lambda entry_id: next(
    (item["source"], item["category"], item["id"])
    for item in entries if item["id"] == entry_id
)), "catalog ordering must remain deterministic"

category_translations = translations["panel"]["command_library"]["categories"]
for entry in entries:
    assert set(entry) == {"id", "source", "category", "kind", "template", "usage"}
    assert entry["id"].startswith(entry["source"] + "/")
    assert entry["category"] in category_translations
    assert entry["kind"] == ("shell" if entry["source"] == "noctalia" else "native")
    assert entry["template"].strip() == entry["template"] and entry["template"]
    assert not re.search(r"[\r\n\x00-\x1f]", entry["template"])
    assert entry["template"].count("{{") == entry["template"].count("}}")

by_id = {entry["id"]: entry for entry in entries}
for required_id in (
    "noctalia/panel-open",
    "noctalia/session",
    "hyprland/window.close",
    "hyprland/workspace.swap_monitors",
    "niri/close-window",
    "niri/toggle-overview",
    "mangowc/killclient",
    "mangowc/reload_config",
):
    assert required_id in by_id, required_id

assert all(entry["template"].startswith("noctalia msg ")
           for entry in entries if entry["source"] == "noctalia")
assert all(entry["template"].startswith("hl.dsp.") and entry["template"].endswith(")")
           for entry in entries if entry["source"] == "hyprland")
assert all(";" not in entry["template"] and "{" not in re.sub(r"\{\{[^}]+\}\}", "", entry["template"])
           for entry in entries if entry["source"] == "niri")
assert all("#" not in entry["template"]
           for entry in entries if entry["source"] == "mangowc")

# The retained UI deliberately renders only a small result window and removes
# callbacks that are no longer part of the current render.
assert "local visibleCount = math.min(#matches, 6)" in panel
assert "finishDynamicCallbackRender()" in panel
assert 'registerDynamicCallback(callbackName' in panel

print(f"command library tests: ok ({len(entries)} entries: {dict(counts)})")
