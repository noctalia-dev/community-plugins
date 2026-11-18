#!/usr/bin/env python3
"""Check translation keys: every key the plugin uses exists in en.json, and
en.json holds no key nothing uses.

    python3 mullvad/tests/check-translations.py

Missing keys fail silently at runtime (the host renders the raw key), so this
catches them early. Keys appear in the code as string literals ("error.busy"):
in tr()/noctalia.tr() calls, but also as textKey/labelKey/key fields and error
returns in the pure modules. So the scan takes every double-quoted literal in the
.luau files whose first segment is a top-level namespace of en.json:
  * a literal naming a defined key counts as used;
  * a literal in a namespace that matches no defined key is reported missing,
    unless it ends in "." (a prefix completed at runtime, e.g. "error." .. name).
Also checked: every label_key / description_key in plugin.toml, and the
"plugin.name" key. Exit code 1 when a key is missing or unused.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

LITERAL = re.compile(r'"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+\.?)"')

# Literals in a translation namespace that are not translation keys: widget ids
# (`key = "account.tab"`) and a file name. They are not reported as missing.
NOT_KEYS = {
    "account.expiry", "account.input", "account.tab", "connect.button", "error.dismiss",
    "error.notice", "header.location", "voucher.input", "advanced.tab", "connect.tab", "plugin.toml",
}

# Keys the code builds at runtime ("tab." .. id). A scan cannot see them, so they
# are listed here, grouped by the prefix the code concatenates onto. Keep in sync.
DYNAMIC = {
    "tab.": ["connect", "advanced", "account"],  # panel.luau TABS
    "connect.mode.": ["country", "my_country", "random"],  # view_connect.luau modes
    "header.action.": [
        "start_service", "enable_service", "restart_service", "disconnect",
        "connect", "lockdown_off", "open_account_tab", "open_account_page",
    ],  # model.luau header actions
    "header.": ["connected", "connecting", "disconnected", "disconnecting"],  # "header." .. tunnel.state
    "tooltip.": ["connecting", "disconnecting"],  # "tooltip." .. tunnel.state
    "error.action.": ["run_in_terminal", "enable_polkit_agent"],  # panel.luau error buttons
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

    missing = sorted(key for key in used if key not in defined)
    unused = sorted(key for key in defined if key not in used)

    for key in missing:
        print("MISSING  " + key)
    for key in unused:
        print("UNUSED   " + key)
    print("%d used, %d defined, %d missing, %d unused" % (len(used), len(defined), len(missing), len(unused)))
    return 1 if (missing or unused or stale) else 0


if __name__ == "__main__":
    sys.exit(main())
