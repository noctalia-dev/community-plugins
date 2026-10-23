#!/usr/bin/env python3
"""Execute the shipped Luau sources against a deterministic Noctalia mock.

Python and Luau CLI are development tools only. No keyring/network access.
The bundle injects host globals into modules, as the Noctalia loader does;
no production source is rewritten. JSON uses the test-only MIT rxi codec.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib

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
    assert "settings" not in manifest and "config" not in manifest

    parts = ["local json = (function()\n", (ROOT / "tests/vendor/json.lua").read_text(), "\nend)()\n"]
    parts.append("local translations = json.decode([==[" + (ROOT / "translations/en.json").read_text() + "]==])\n")
    parts.append((ROOT / "tests/mock.luau").read_text())
    parts.append("\nlocal modules = {}\n")
    for module in ("api", "credentials"):
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
