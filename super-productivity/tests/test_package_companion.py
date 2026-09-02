from __future__ import annotations

import hashlib
import json
import os
import stat
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
                    self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))
                    self.assertEqual(stat.S_IMODE(info.external_attr >> 16), 0o644)
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
            self.assertEqual(stat.S_IMODE(output.parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(metadata_path.stat().st_mode), 0o600)

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

            subprocess.run(
                ["python3", str(SCRIPT), "--machine-readable"],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(output.read_bytes(), original)
            restored_metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            self.assertEqual(restored_metadata["archiveSize"], len(original))

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
