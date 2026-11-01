#!/usr/bin/env python3
"""Run plugin regression tests in Luau without touching real devices or processes."""

import argparse
from pathlib import Path
import subprocess
import tempfile


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--luau", default="luau", help="Path to the Luau CLI")
parser.add_argument("--service", type=Path, help="Alternative service revision to test")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = (args.service or root / "service.luau").read_text()
# Quote as a Luau string literal without interpreting any plugin source.
delimiter = "="
while "]" + delimiter + "]" in source:
    delimiter += "="
prefix = f"local SERVICE_SOURCE = [{delimiter}[{source}]{delimiter}]\n"
for variable, entry in (("PANEL_SOURCE", "panel.luau"), ("WIDGET_SOURCE", "widget.luau")):
    entry_source = (root / entry).read_text()
    delimiter = "="
    while "]" + delimiter + "]" in entry_source:
        delimiter += "="
    prefix += f"local {variable} = [{delimiter}[{entry_source}]{delimiter}]\n"
with tempfile.TemporaryDirectory(prefix="wayvibes-tests-") as directory:
    script = Path(directory) / "service-tests.luau"
    script.write_text(prefix + (root / "tests/service.luau").read_text() + "\n" + (root / "tests/ui.luau").read_text())
    raise SystemExit(subprocess.run([args.luau, str(script)]).returncode)
