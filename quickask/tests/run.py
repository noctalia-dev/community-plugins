#!/usr/bin/env python3
"""Execute the shipped Luau sources against a deterministic Noctalia mock.

Python and Luau CLI are development tools only. No keyring/network access.
The bundle injects host globals into modules, as the Noctalia loader does;
no production source is rewritten. JSON uses the test-only MIT rxi codec.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import re

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", default=shutil.which("luau"))
    args = parser.parse_args()
    if not args.runtime:
        parser.error("Luau CLI required: --runtime /path/to/luau")
    manifest = tomllib.loads((ROOT / "plugin.toml").read_text())
    assert manifest["plugin_api"] == 24
    assert manifest["id"] == "yusuferdemyamali/quickask"
    assert len(manifest["panel"]) == 1
    panel = manifest["panel"][0]
    assert (panel["width"], panel["height"]) == (520, 380)
    assert panel["position"] == "bottom_center"
    assert panel["keyboard_focus"] == "exclusive"
    assert panel["dismiss_on_outside_click"] is True
    settings = {item["key"]: item["default"] for item in manifest["setting"]}
    assert settings == {"provider": "opencode-go", "endpoint": "https://api.openai.com/v1/chat/completions", "model": ""}
    assert set(manifest["dependencies"]) == {"secret-tool"}

    def catalog_leaves(value, prefix=""):
        if isinstance(value, dict):
            return {key: text for name, child in value.items()
                    for key, text in catalog_leaves(child, prefix + "." + name).items()}
        assert isinstance(value, str) and value
        return {prefix: set(re.findall(r"\{([\w-]+)\}", value))}

    english = catalog_leaves(json.loads((ROOT / "translations/en.json").read_text()))
    assert catalog_leaves(json.loads((ROOT / "translations/tr.json").read_text())) == english

    parts = ["local json = (function()\n", (ROOT / "tests/vendor/json.lua").read_text(), "\nend)()\n"]
    parts.append("local translations = json.decode([==[" + (ROOT / "translations/en.json").read_text() + "]==])\n")
    parts.append("local settingDefaults = json.decode([==[" + json.dumps(settings) + "]==])\n")
    parts.append((ROOT / "tests/mock.luau").read_text())
    parts.append("\nlocal modules = {}\n")
    for module in ("api", "credentials", "config"):
        parts += [f'modules["./lib/{module}.luau"] = (function()\n',
                  (ROOT / f"lib/{module}.luau").read_text(), "\nend)()\n"]
    parts.append('local function require(path) assert(modules[path], "Unexpected require"); return modules[path] end\n')
    parts.append((ROOT / "panel.luau").read_text())
    parts.append((ROOT / "tests/spec.luau").read_text())
    with tempfile.TemporaryDirectory(prefix="quickask-tests-") as directory:
        path = Path(directory) / "suite.luau"
        path.write_text("\n".join(parts))
        result = subprocess.run([args.runtime, str(path)], cwd=ROOT, check=False)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
