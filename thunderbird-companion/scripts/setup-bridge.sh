#!/usr/bin/env bash
# Install the bundled Thunderbird companion bridge for the current user.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

BRIDGE_DATA_DIR_NAME="noctalia-thunderbird-companion"
NATIVE_HOST_NAME="dev.noctalia.thunderbird_companion"
EXTENSION_ID="thunderbird-companion@mdj2812.github.io"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
BRIDGE_DATA_DIR="$DATA_HOME/$BRIDGE_DATA_DIR_NAME"
BRIDGE_VERSION_PATH="$PLUGIN_DIR/bridge-version.json"
EXTENSION_SOURCE_DIR="$PLUGIN_DIR/companion"
HOST_SOURCE_PATH="$PLUGIN_DIR/native-host/host.py"
HOST_PATH="$BRIDGE_DATA_DIR/host.py"
INSTALLED_VERSION_PATH="$BRIDGE_DATA_DIR/installed-bridge.json"
OLD_RELEASE_PATH="$BRIDGE_DATA_DIR/release.json"
MANIFEST_DIR="$HOME/.mozilla/native-messaging-hosts"
MANIFEST_PATH="$MANIFEST_DIR/$NATIVE_HOST_NAME.json"
XPI_PATH="$BRIDGE_DATA_DIR/thunderbird-companion.xpi"
LEGACY_LIB_DIR="$HOME/.local/lib/$BRIDGE_DATA_DIR_NAME"

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f -- \
    "$MANIFEST_PATH" \
    "$HOST_PATH" \
    "$INSTALLED_VERSION_PATH" \
    "$OLD_RELEASE_PATH" \
    "$XPI_PATH" \
    "$LEGACY_LIB_DIR/host.py" \
    "$LEGACY_LIB_DIR/release.json"
  rmdir --ignore-fail-on-non-empty \
    "$BRIDGE_DATA_DIR" "$LEGACY_LIB_DIR" "$MANIFEST_DIR" 2>/dev/null || true
  printf '%s\n' "Native host removed. Remove the companion extension from Thunderbird separately."
  exit 0
fi

MACHINE_READABLE=false
if [[ "${1:-}" == "--machine-readable" ]]; then
  MACHINE_READABLE=true
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "Missing required command: python3" >&2
  exit 1
fi

BRIDGE_VERSION="$(
  python3 - \
    "$BRIDGE_VERSION_PATH" \
    "$EXTENSION_SOURCE_DIR" \
    "$HOST_SOURCE_PATH" \
    "$HOST_PATH" \
    "$MANIFEST_PATH" \
    "$XPI_PATH" \
    "$INSTALLED_VERSION_PATH" \
    "$EXTENSION_ID" \
    "$NATIVE_HOST_NAME" <<'PY'
from __future__ import annotations

import hashlib
import io
import json
import os
import sys
from pathlib import Path
from typing import Any
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


(
    bridge_version_path,
    extension_source_dir,
    host_source_path,
    host_path,
    native_manifest_path,
    xpi_path,
    installed_version_path,
) = map(Path, sys.argv[1:8])
EXPECTED_EXTENSION_ID, EXPECTED_HOST_NAME = sys.argv[8:10]


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
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


os.umask(0o077)
bridge_version = require_object(
    json.loads(bridge_version_path.read_text(encoding="utf-8")),
    "bridge version",
)
if bridge_version.get("schemaVersion") != 1:
    raise ValueError("unsupported bridge version schema")
version = require_string(bridge_version.get("version"), "bridge version")
bridge_protocol = bridge_version.get("bridgeProtocol")
if bridge_protocol != 1:
    raise ValueError("unsupported bridge protocol")
if bridge_version.get("extensionId") != EXPECTED_EXTENSION_ID:
    raise ValueError("bridge version has an unexpected extension ID")
if bridge_version.get("nativeHostName") != EXPECTED_HOST_NAME:
    raise ValueError("bridge version has an unexpected native-host name")

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
if gecko.get("id") != EXPECTED_EXTENSION_ID:
    raise ValueError("extension manifest has an unexpected ID")
if "update_url" in gecko:
    raise ValueError("bundled extension must not use a remote update channel")
if "nativeMessaging" not in extension_manifest.get("permissions", []):
    raise ValueError("extension manifest is missing nativeMessaging permission")

host_data = host_source_path.read_bytes()
compile(host_data.decode("utf-8"), str(host_source_path), "exec")
xpi_data = build_xpi(extension_source_dir)

atomic_write(host_path, host_data, 0o755)
atomic_write(xpi_path, xpi_data, 0o600)
native_manifest = {
    "name": EXPECTED_HOST_NAME,
    "description": "Noctalia Thunderbird Companion native bridge",
    "path": str(host_path.resolve()),
    "type": "stdio",
    "allowed_extensions": [EXPECTED_EXTENSION_ID],
}
atomic_write(
    native_manifest_path,
    (json.dumps(native_manifest, indent=2) + "\n").encode(),
    0o600,
)
installed_version = {
    "schemaVersion": 1,
    "version": version,
    "bridgeProtocol": bridge_protocol,
    "extensionId": EXPECTED_EXTENSION_ID,
    "nativeHostName": EXPECTED_HOST_NAME,
    "extensionSha256": sha256(xpi_data),
    "nativeHostSha256": sha256(host_data),
}
atomic_write(
    installed_version_path,
    (json.dumps(installed_version, indent=2) + "\n").encode(),
    0o600,
)
print(version)
PY
)"

# Remove files left by older installer layouts after the bundled setup succeeds.
rm -f -- "$OLD_RELEASE_PATH"
if [[ "$LEGACY_LIB_DIR" != "$BRIDGE_DATA_DIR" ]]; then
  rm -f -- "$LEGACY_LIB_DIR/host.py" "$LEGACY_LIB_DIR/release.json"
  rmdir --ignore-fail-on-non-empty "$LEGACY_LIB_DIR" 2>/dev/null || true
fi

if $MACHINE_READABLE; then
  printf 'XPI_PATH=%s\n' "$XPI_PATH"
  printf 'BRIDGE_VERSION=%s\n' "$BRIDGE_VERSION"
  exit 0
fi

cat <<EOF
Thunderbird Companion bridge $BRIDGE_VERSION installed.

Next:
  1. Open Thunderbird -> Add-ons and Themes.
  2. Open the gear menu and choose "Install Add-on From File".
  3. Select:
     $XPI_PATH
  4. Accept the requested permissions and restart Thunderbird.

The bridge is bundled with the Noctalia plugin. Run setup again when the panel
reports that a compatible bridge update is required.
EOF
