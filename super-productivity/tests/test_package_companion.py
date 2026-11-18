from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "super-productivity" / "scripts" / "package-companion.py"
COMPANION = ROOT / "super-productivity" / "companion"

PACKAGE_FILES = ("manifest.json", "plugin.js", "icon.svg")


def source_sha256() -> str:
    digest = hashlib.sha256()
    for name in PACKAGE_FILES:
        data = (COMPANION / name).read_bytes()
        digest.update(name.encode())
        digest.update(b"\0")
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


class PackageCompanionTest(unittest.TestCase):
    def test_check_rejects_contract_drift(self) -> None:
        cases = (
            ("common.luau", "M.PROTOCOL_VERSION = 2", "M.PROTOCOL_VERSION = 3", "protocol version"),
            ("companion/plugin.js", "PROTOCOL_VERSION = 2", "PROTOCOL_VERSION = 3", "protocol version"),
            ("service.luau", "SCHEMA_VERSION = 1", "SCHEMA_VERSION = 2", "schema version"),
            ("service.luau", 'BRIDGE_NAME = "noctalia-super-productivity"', 'BRIDGE_NAME = "other-bridge"', "bridge directory name"),
        )
        for name, original, replacement, error in cases:
            with self.subTest(source=name, contract=error), tempfile.TemporaryDirectory() as temporary:
                plugin = Path(temporary)
                shutil.copytree(COMPANION, plugin / "companion")
                (plugin / "scripts").mkdir()
                shutil.copyfile(SCRIPT, plugin / "scripts" / SCRIPT.name)
                for source in ("common.luau", "service.luau"):
                    shutil.copyfile(COMPANION.parent / source, plugin / source)
                source = plugin / name
                text = source.read_text(encoding="utf-8")
                self.assertIn(original, text)
                source.write_text(text.replace(original, replacement, 1), encoding="utf-8")

                result = subprocess.run(
                    ["python3", str(plugin / "scripts" / SCRIPT.name), "--check"],
                    check=False, capture_output=True, text=True,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{error} differs between the companion and Noctalia", result.stderr)

    def test_builds_package_in_xdg_data_home(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = os.environ.copy()
            environment["XDG_DATA_HOME"] = temporary
            result = subprocess.run(
                ["python3", str(SCRIPT), "--machine-readable"],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )

            output = Path(
                next(
                    line.removeprefix("ZIP_PATH=")
                    for line in result.stdout.splitlines()
                    if line.startswith("ZIP_PATH=")
                )
            )
            self.assertEqual(
                output,
                Path(temporary)
                / "noctalia-super-productivity"
                / "noctalia-super-productivity.zip",
            )
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(archive.namelist(), list(PACKAGE_FILES))
                for info in archive.infolist():
                    self.assertEqual(
                        archive.read(info.filename),
                        (COMPANION / info.filename).read_bytes(),
                    )

            metadata_path = output.parent / "companion-package.json"
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            manifest = json.loads(
                (COMPANION / "manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(metadata["schemaVersion"], 1)
            self.assertEqual(metadata["companionVersion"], manifest["version"])
            self.assertEqual(metadata["sourceSha256"], source_sha256())
            self.assertEqual(
                metadata["archiveSha256"], hashlib.sha256(output.read_bytes()).hexdigest()
            )
            self.assertEqual(metadata["archiveSize"], output.stat().st_size)
            self.assertEqual(metadata["archivePath"], str(output))

            original = output.read_bytes()
            subprocess.run(
                ["python3", str(SCRIPT), "--verify"],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            corrupted = bytearray(original)
            corrupted[-1] ^= 0xFF
            output.write_bytes(corrupted)
            verification = subprocess.run(
                ["python3", str(SCRIPT), "--verify"],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertNotEqual(verification.returncode, 0)
            self.assertIn("differs from the bundled source", verification.stderr)

            subprocess.run(
                ["python3", str(SCRIPT), "--machine-readable"],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(output.read_bytes(), original)
            metadata["archiveSize"] -= 1
            metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
            verification = subprocess.run(
                ["python3", str(SCRIPT), "--verify"],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertNotEqual(verification.returncode, 0)
            self.assertIn("metadata differs from the bundled source", verification.stderr)


    def test_empty_xdg_data_home_uses_home_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = os.environ.copy()
            environment["HOME"] = temporary
            environment["XDG_DATA_HOME"] = ""
            subprocess.run(
                ["python3", str(SCRIPT)],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )

            output = (
                Path(temporary)
                / ".local/share/noctalia-super-productivity/noctalia-super-productivity.zip"
            )
            self.assertTrue(output.is_file())

    def test_manifest_uses_select_only_bridge_permissions(self) -> None:
        manifest = json.loads(
            (COMPANION / "manifest.json").read_text(encoding="utf-8")
        )

        self.assertEqual(manifest["minSupVersion"], "18.21.2")
        self.assertEqual(manifest["permissions"], ["nodeExecution", "selectTask"])
        self.assertEqual(
            manifest["hooks"],
            [
                "taskComplete",
                "taskUpdate",
                "taskDelete",
                "currentTaskChange",
                "action",
            ],
        )

    def test_check_does_not_write_package(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = os.environ.copy()
            environment["XDG_DATA_HOME"] = temporary
            result = subprocess.run(
                ["python3", str(SCRIPT), "--check"],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertIn("deterministic archive", result.stdout)
            self.assertEqual(list(Path(temporary).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
