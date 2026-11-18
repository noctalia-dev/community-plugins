"""Run the foreground operation module with controlled dependencies."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[1]


class OperationTests(unittest.TestCase):
    def test_operation(self):
        binary = os.environ.get("LUAU_BIN") or shutil.which("luau")
        if binary is None:
            self.skipTest("luau is not installed")
        with tempfile.TemporaryDirectory(prefix="sp-operation-") as directory:
            root = Path(directory)
            shutil.copyfile(PLUGIN / "operation.luau", root / "operation.luau")
            shutil.copyfile(PLUGIN / "tests/operation-test.luau", root / "operation-test.luau")
            result = subprocess.run([binary, "operation-test.luau"], cwd=root,
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("operation tests passed", result.stdout)
