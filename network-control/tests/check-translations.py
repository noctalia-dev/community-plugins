#!/usr/bin/env python3
"""Check that every translation key the plugin asks for exists in en.json.

    python3 tests/check-translations.py

Two kinds of mistake this catches, both of which fail silently at runtime (the
host renders the raw key):

  * a tr("...") literal in a .luau file with no entry in en.json
  * a setting's label_key / description_key in plugin.toml with no entry

Keys composed at runtime - tr("field." .. key), the error keys returned by
net.luau, the method labels - cannot be found by scanning strings, so they are
generated from the same names the code uses. Keep DYNAMIC in sync when adding a
field or an error.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

DYNAMIC = (
    ["method." + name for name in ("auto", "manual", "link_local", "disabled", "ignore", "unknown")]
    + ["field." + name for name in (
        "ipv4_method", "ipv4_addresses", "ipv4_gateway", "ipv4_dns", "ipv4_dns_search",
        "ipv6_method", "ipv6_addresses", "ipv6_gateway", "ipv6_dns", "ipv6_dns_search",
    )]
    + ["error.form", "error.method", "error.search"]
    + [
        "error.%s.%s" % (kind, family)
        for kind in ("address", "gateway", "dns", "need_address", "gateway_needs_address")
        for family in ("ipv4", "ipv6")
    ]
)

# failWifi() takes a translation key and translates it inside the helper.
LITERAL = re.compile(r'(?:noctalia\.tr|tr|failWifi)\(\s*"([^"]+)"')

# Keys the code hands to a helper that calls tr() itself (keyValueRow,
# sectionTitle) or names inside a larger expression, so the literal scan above
# cannot see them.
INDIRECT = {
    "panel.live_ipv4", "panel.live_gateway", "panel.live_dns", "panel.live_ipv6", "panel.live_device",
    "panel.connections", "panel.edit",
    "notify.applied", "notify.reverted", "notify.reverted_timeout", "notify.reverted_failed",
    "notify.up_failed", "notify.down_failed",
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

    used = set(DYNAMIC) | set(INDIRECT)
    for source in sorted(ROOT.glob("*.luau")):
        for key in LITERAL.findall(source.read_text()):
            # tr("field." .. key) composes; the parts are in DYNAMIC
            if not key.endswith("."):
                used.add(key)

    manifest = (ROOT / "plugin.toml").read_text()
    for key in re.findall(r'(?:label_key|description_key)\s*=\s*"([^"]+)"', manifest):
        used.add(key)

    missing = sorted(key for key in used if key not in defined)
    unused = sorted(key for key in defined if key not in used)

    for key in missing:
        print("MISSING  " + key)
    for key in unused:
        print("unused   " + key)

    print("\n%d used, %d defined, %d missing, %d unused" % (len(used), len(defined), len(missing), len(unused)))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
