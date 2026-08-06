#!/usr/bin/env python3
import json
import os
import sys

def main():
    plugin_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    trans_dir = os.path.join(plugin_dir, "translations")
    en_file = os.path.join(trans_dir, "en.json")

    if not os.path.exists(en_file):
        print(f"Error: Translation file not found at {en_file}")
        sys.exit(1)

    def flatten_keys(d, prefix=""):
        keys = []
        for k, v in d.items():
            full_key = f"{prefix}.{k}" if prefix else k
            if isinstance(v, dict):
                keys.extend(flatten_keys(v, full_key))
            else:
                keys.append(full_key)
        return keys

    with open(en_file, "r", encoding="utf-8") as f:
        en_translations = json.load(f)

    en_keys = set(flatten_keys(en_translations))
    errors = []

    # Code and manifest files to scan (checked against en.json, the reference).
    scan_files = ["plugin.toml", "service.luau", "status.luau", "panel.luau"]
    combined_content = ""

    for fname in scan_files:
        fpath = os.path.join(plugin_dir, fname)
        if os.path.exists(fpath):
            with open(fpath, "r", encoding="utf-8") as f:
                combined_content += f.read() + "\n"

    # 1. Every en.json key must be used somewhere in the codebase.
    missing_keys = []
    for key in sorted(en_keys):
        # Setting label_key and description_key append .label and .description automatically.
        base_key = key.replace(".label", "").replace(".description", "")
        if key not in combined_content and base_key not in combined_content:
            missing_keys.append(key)

    if missing_keys:
        errors.append("Unused translation key(s) found in translations/en.json:\n  - " + "\n  - ".join(missing_keys))

    # 2. Every other translation file must have exactly the same keys as en.json.
    for fname in sorted(os.listdir(trans_dir)):
        if not fname.endswith(".json") or fname == "en.json":
            continue
        fpath = os.path.join(trans_dir, fname)
        with open(fpath, "r", encoding="utf-8") as f:
            try:
                other = json.load(f)
            except json.JSONDecodeError as e:
                errors.append(f"Invalid JSON in translations/{fname}: {e}")
                continue
        other_keys = set(flatten_keys(other))
        missing = sorted(en_keys - other_keys)
        extra = sorted(other_keys - en_keys)
        if missing:
            errors.append(f"translations/{fname} is missing key(s):\n  - " + "\n  - ".join(missing))
        if extra:
            errors.append(f"translations/{fname} has extra key(s) not in en.json:\n  - " + "\n  - ".join(extra))

    if errors:
        for e in errors:
            print(e)
        sys.exit(1)

    other_count = len([f for f in os.listdir(trans_dir) if f.endswith(".json") and f != "en.json"])
    print(f"✓ All {len(en_keys)} translation keys in translations/en.json are active and used in codebase.")
    if other_count:
        print(f"✓ {other_count} other translation file(s) match the en.json key set exactly.")

if __name__ == "__main__":
    main()