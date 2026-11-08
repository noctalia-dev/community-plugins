#!/usr/bin/env python3
"""Check translation keys: every key the plugin uses exists in en.json, and
en.json holds no key nothing uses.

    python3 ufw/tests/check-translations.py

Missing keys fail silently at runtime (the host renders the raw key), so this
catches them early. Keys appear in the code as string literals ("error.busy"):
in tr()/noctalia.tr() calls, but also as textKey/labelKey/key fields and error
returns in the pure modules. So the scan takes every double-quoted literal in the
.luau files whose first segment is a top-level namespace of en.json:
  * a literal naming a defined key counts as used;
  * a literal in a namespace that matches no defined key is reported missing,
    unless it ends in "." (a prefix completed at runtime, e.g. "error." .. name).
Also checked: every label_key / description_key in plugin.toml, and the
"plugin.name" key.

Counts: noctalia.tr has no plural forms, so a message with {n} is a pair of keys
<base>_one / <base>_other, and the code names the base ("footer.unsaved"); a
pure helper (model.countKey) appends the suffix at runtime. A used base counts as
both keys of its pair. Every string holding {n} must be such a pair.
Exit code 1 when a key is missing or unused, or a count message is not a pair.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

LITERAL = re.compile(r'"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+\.?)"')

# Literals in a translation namespace that are not translation keys: widget ids
# and a file name. They are not reported as missing.
NOT_KEYS = {"plugin.toml"}

# Keys the code builds at runtime ("tab." .. id). A scan cannot see them, so they
# are listed here, grouped by the prefix the code concatenates onto. Keep in sync.
DYNAMIC = {
    "tooltip.": ["not_running", "failed", "missing", "unknown", "off", "stopped"],
}


def collect_defined(node, prefix=""):
    out = set()
    for key, value in node.items():
        path = prefix + key
        if isinstance(value, dict):
            out |= collect_defined(value, path + ".")
        else:
            out.add(path)
    return out


PLURAL_SUFFIXES = ("_one", "_other")


def expand_plurals(used, defined):
    """A used base key with both <base>_one and <base>_other defined stands for the pair."""
    out = set()
    for key in used:
        pair = [key + suffix for suffix in PLURAL_SUFFIXES]
        if key not in defined and all(p in defined for p in pair):
            out.update(pair)
        else:
            out.add(key)
    return out


def bad_counts(node, prefix=""):
    """Keys whose text holds {n} but are not one half of a complete _one/_other pair."""
    out = []
    for key, value in node.items():
        path = prefix + key
        if isinstance(value, dict):
            out += bad_counts(value, path + ".")
        elif "{n}" in value:
            base = None
            for suffix in PLURAL_SUFFIXES:
                if key.endswith(suffix):
                    base = key[: -len(suffix)]
            if base is None or not all(base + s in node for s in PLURAL_SUFFIXES):
                out.append(path)
    return out


def main():
    translations = json.loads((ROOT / "translations" / "en.json").read_text())
    defined = collect_defined(translations)
    namespaces = set(translations)

    stale = []
    used = {"plugin.name"}
    candidates = set()
    for source in sorted(ROOT.glob("*.luau")):
        for key in LITERAL.findall(source.read_text()):
            if key.split(".")[0] in namespaces and not key.endswith(".") and key not in NOT_KEYS:
                candidates.add(key)
    used |= candidates
    for prefix, names in DYNAMIC.items():
        for name in names:
            used.add(prefix + name)
        # the prefix must still be concatenated somewhere, or this list is stale
        if not any('"%s" ..' % prefix in path.read_text() for path in ROOT.glob("*.luau")):
            stale.append(prefix)
            print("STALE    dynamic prefix not found in code: " + prefix)

    manifest = (ROOT / "plugin.toml").read_text()
    for key in re.findall(r'(?:label_key|description_key)\s*=\s*"([^"]+)"', manifest):
        used.add(key)

    used = expand_plurals(used, defined)
    counts = bad_counts(translations)
    for key in counts:
        print("COUNT    {n} outside a _one/_other pair: " + key)

    missing = sorted(key for key in used if key not in defined)
    unused = sorted(key for key in defined if key not in used)

    for key in missing:
        print("MISSING  " + key)
    for key in unused:
        print("UNUSED   " + key)
    print("%d used, %d defined, %d missing, %d unused" % (len(used), len(defined), len(missing), len(unused)))
    return 1 if (missing or unused or stale or counts) else 0


if __name__ == "__main__":
    sys.exit(main())
