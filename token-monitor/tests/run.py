#!/usr/bin/env python3
"""Run pure Luau cases; normalize Noctalia's explicit module suffix for the CLI."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--luau", default=shutil.which("luau"))
args = parser.parse_args()
if not args.luau:
    parser.error("Supply --luau with an existing Luau CLI executable")
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="token-monitor-luau-") as directory:
    target = Path(directory)
    cases = sorted((root / "tests").glob("*_cases.luau"))
    sources = sorted((root / "lib").glob("*.luau")) + cases
    for path in sources:
        name = path.relative_to(root)
        output = target / name
        output.parent.mkdir(parents=True, exist_ok=True)
        # Noctalia accepts explicit .luau suffixes; standalone Luau appends one.
        source = re.sub(r'(require\("[^"]+)\.luau("\))', r'\1\2', (root / name).read_text())
        output.write_text(source)
    subprocess.run([args.luau, *(str(target / path.relative_to(root)) for path in cases)], check=True)
