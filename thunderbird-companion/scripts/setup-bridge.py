"""Install the bundled Thunderbird companion bridge for the current user."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import sys
from pathlib import Path
from typing import Any
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

BRIDGE_DATA_DIR_NAME = "noctalia-thunderbird-companion"
NATIVE_HOST_NAME = "dev.noctalia.thunderbird_companion"
EXTENSION_ID = "thunderbird-companion@mdj2812.github.io"


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise TypeError(f"{label} must be an object")
    return value


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} must be a non-empty string")
    return value


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_bytes(data)
        temporary.chmod(mode)
        os.replace(temporary, path)
        path.chmod(mode)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def build_xpi(source_dir: Path) -> bytes:
    destination = io.BytesIO()
    with ZipFile(destination, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
        for source in sorted(path for path in source_dir.rglob("*") if path.is_file()):
            relative = source.relative_to(source_dir).as_posix()
            info = ZipInfo(relative, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, source.read_bytes(), compress_type=ZIP_DEFLATED)
    return destination.getvalue()


def remove_file(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def remove_empty_dir(path: Path) -> None:
    try:
        path.rmdir()
    except OSError:
        pass


def bridge_paths(plugin_dir: Path) -> dict[str, Path]:
    data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    bridge_data_dir = data_home / BRIDGE_DATA_DIR_NAME
    legacy_lib_dir = Path.home() / ".local" / "lib" / BRIDGE_DATA_DIR_NAME
    manifest_dir = Path.home() / ".mozilla" / "native-messaging-hosts"
    return {
        "plugin_dir": plugin_dir,
        "bridge_data_dir": bridge_data_dir,
        "bridge_version_path": plugin_dir / "bridge-version.json",
        "extension_source_dir": plugin_dir / "companion",
        "host_source_path": plugin_dir / "native-host" / "host.py",
        "host_path": bridge_data_dir / "host.py",
        "installed_version_path": bridge_data_dir / "installed-bridge.json",
        "old_release_path": bridge_data_dir / "release.json",
        "manifest_dir": manifest_dir,
        "manifest_path": manifest_dir / f"{NATIVE_HOST_NAME}.json",
        "xpi_path": bridge_data_dir / "thunderbird-companion.xpi",
        "legacy_lib_dir": legacy_lib_dir,
    }


def uninstall(paths: dict[str, Path]) -> int:
    remove_file(paths["manifest_path"])
    remove_file(paths["host_path"])
    remove_file(paths["installed_version_path"])
    remove_file(paths["old_release_path"])
    remove_file(paths["xpi_path"])
    remove_file(paths["legacy_lib_dir"] / "host.py")
    remove_file(paths["legacy_lib_dir"] / "release.json")
    remove_empty_dir(paths["bridge_data_dir"])
    remove_empty_dir(paths["legacy_lib_dir"])
    remove_empty_dir(paths["manifest_dir"])
    print("Native host removed. Remove the companion extension from Thunderbird separately.")
    return 0


def cleanup_legacy(paths: dict[str, Path]) -> None:
    remove_file(paths["old_release_path"])
    legacy_lib_dir = paths["legacy_lib_dir"]
    bridge_data_dir = paths["bridge_data_dir"]
    if legacy_lib_dir != bridge_data_dir:
        remove_file(legacy_lib_dir / "host.py")
        remove_file(legacy_lib_dir / "release.json")
        remove_empty_dir(legacy_lib_dir)


def install(paths: dict[str, Path]) -> str:
    os.umask(0o077)
    bridge_version = require_object(
        json.loads(paths["bridge_version_path"].read_text(encoding="utf-8")),
        "bridge version",
    )
    if bridge_version.get("schemaVersion") != 1:
        raise ValueError("unsupported bridge version schema")
    version = require_string(bridge_version.get("version"), "bridge version")
    bridge_protocol = bridge_version.get("bridgeProtocol")
    if bridge_protocol != 1:
        raise ValueError("unsupported bridge protocol")
    if bridge_version.get("extensionId") != EXTENSION_ID:
        raise ValueError("bridge version has an unexpected extension ID")
    if bridge_version.get("nativeHostName") != NATIVE_HOST_NAME:
        raise ValueError("bridge version has an unexpected native-host name")

    extension_source_dir = paths["extension_source_dir"]
    extension_manifest = require_object(
        json.loads((extension_source_dir / "manifest.json").read_text(encoding="utf-8")),
        "extension manifest",
    )
    gecko = require_object(
        require_object(
            extension_manifest.get("browser_specific_settings"),
            "browser-specific settings",
        ).get("gecko"),
        "Gecko settings",
    )
    if extension_manifest.get("version") != version:
        raise ValueError("extension version does not match bridge-version.json")
    if gecko.get("id") != EXTENSION_ID:
        raise ValueError("extension manifest has an unexpected ID")
    if "update_url" in gecko:
        raise ValueError("bundled extension must not use a remote update channel")
    if "nativeMessaging" not in extension_manifest.get("permissions", []):
        raise ValueError("extension manifest is missing nativeMessaging permission")

    host_source_path = paths["host_source_path"]
    host_data = host_source_path.read_bytes()
    compile(host_data.decode("utf-8"), str(host_source_path), "exec")
    xpi_data = build_xpi(extension_source_dir)

    host_path = paths["host_path"]
    xpi_path = paths["xpi_path"]
    atomic_write(host_path, host_data, 0o755)
    atomic_write(xpi_path, xpi_data, 0o600)
    native_manifest = {
        "name": NATIVE_HOST_NAME,
        "description": "Noctalia Thunderbird Companion native bridge",
        "path": str(host_path.resolve()),
        "type": "stdio",
        "allowed_extensions": [EXTENSION_ID],
    }
    atomic_write(
        paths["manifest_path"],
        (json.dumps(native_manifest, indent=2) + "\n").encode(),
        0o600,
    )
    installed_version = {
        "schemaVersion": 1,
        "version": version,
        "bridgeProtocol": bridge_protocol,
        "extensionId": EXTENSION_ID,
        "nativeHostName": NATIVE_HOST_NAME,
        "extensionSha256": sha256(xpi_data),
        "nativeHostSha256": sha256(host_data),
    }
    atomic_write(
        paths["installed_version_path"],
        (json.dumps(installed_version, indent=2) + "\n").encode(),
        0o600,
    )
    cleanup_legacy(paths)
    return version


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Install the bundled Thunderbird companion bridge for the current user.",
    )
    parser.add_argument(
        "--machine-readable",
        action="store_true",
        help="Print XPI_PATH and BRIDGE_VERSION on stdout for automation.",
    )
    parser.add_argument(
        "--uninstall",
        action="store_true",
        help="Remove the installed native host files for the current user.",
    )
    args = parser.parse_args(argv)

    plugin_dir = Path(__file__).resolve().parent.parent
    paths = bridge_paths(plugin_dir)

    if args.uninstall:
        return uninstall(paths)

    try:
        version = install(paths)
    except TypeError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    if args.machine_readable:
        print(f"XPI_PATH={paths['xpi_path']}")
        print(f"BRIDGE_VERSION={version}")
        return 0

    xpi_path = paths["xpi_path"]
    print(
        f"""Thunderbird Companion bridge {version} installed.

Next:
  1. Open Thunderbird -> Add-ons and Themes.
  2. Open the gear menu and choose "Install Add-on From File".
  3. Select:
     {xpi_path}
  4. Accept the requested permissions and restart Thunderbird.

The bridge is bundled with the Noctalia plugin. Run setup again when the panel
reports that a compatible bridge update is required."""
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
