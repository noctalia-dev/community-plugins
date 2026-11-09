"""Run UI/state checks under Lua with Noctalia APIs mocked.
Luau's += is expanded for the Lua interpreter; this is not a live UI test.
"""
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which("lua"), "optional Lua interpreter unavailable")
class UiTests(unittest.TestCase):
    def test_headphones_and_earbuds(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            for name in ("shared.luau", "panel.luau", "widget.luau", "desktop-widget.luau", "service.luau"):
                source = (root / name).read_text()
                source = re.sub(r"(\b\w+) \+= (.+)", r"\1 = \1 + \2", source)
                pathlib.Path(directory, name).write_text(source)
            result = subprocess.run(
                ["lua", str(root / "tests/ui_checks.lua"), directory],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
