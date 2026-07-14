#!/usr/bin/env python3
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRANSLATIONS = json.loads((ROOT / "translations" / "en.json").read_text())


def resolves(key: str) -> bool:
    value = TRANSLATIONS
    for part in key.split("."):
        if not isinstance(value, dict) or part not in value:
            return False
        value = value[part]
    return isinstance(value, (str, dict))


required = set()
manifest = (ROOT / "plugin.toml").read_text()
required.update(re.findall(r'(?:label_key|description_key)\s*=\s*"([^"]+)"', manifest))

for path in ROOT.glob("*.luau"):
    source = path.read_text()
    required.update(re.findall(r'(?:noctalia\.)?trp?\(\s*"([^"]+)"', source))
    required.update(re.findall(r'"((?:actions|category)\.[a-z0-9_.]+)"', source))

missing = sorted(key for key in required if not key.endswith(".") and not resolves(key))
assert not missing, "missing English translation keys: " + ", ".join(missing)

# Physical modifier legends are standardized key names. Other literal UI prose
# must go through noctalia.tr so new locales can translate it.
allowed_key_labels = {"Super", "Ctrl", "Shift", "Alt"}
literal_ui = []
panel_source = (ROOT / "panel.luau").read_text()
for match in re.finditer(r'\b(?:text|placeholder|tooltip)\s*=\s*"([^"]+)"', panel_source):
    if match.group(1) not in allowed_key_labels:
        literal_ui.append(match.group(1))
assert not literal_ui, "untranslated literal UI strings: " + ", ".join(literal_ui)

print(f"i18n tests: ok ({len(required)} referenced keys)")
