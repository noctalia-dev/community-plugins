#!/usr/bin/env bash
# Download and install the pinned Thunderbird companion bridge release.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

BRIDGE_DATA_DIR_NAME="noctalia-thunderbird-companion"
NATIVE_HOST_NAME="dev.noctalia.thunderbird_companion"
EXTENSION_ID="thunderbird-companion@mdj2812.github.io"
UPDATE_URL="https://mdj2812.github.io/noctalia-thunderbird-companion/updates.json"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
BRIDGE_DATA_DIR="$DATA_HOME/$BRIDGE_DATA_DIR_NAME"
RELEASE_SPEC_PATH="$PLUGIN_DIR/bridge-release.json"
HOST_PATH="$BRIDGE_DATA_DIR/host.py"
INSTALLED_RELEASE_PATH="$BRIDGE_DATA_DIR/release.json"
MANIFEST_DIR="$HOME/.mozilla/native-messaging-hosts"
MANIFEST_PATH="$MANIFEST_DIR/$NATIVE_HOST_NAME.json"
XPI_PATH="$BRIDGE_DATA_DIR/thunderbird-companion.xpi"
LEGACY_LIB_DIR="$HOME/.local/lib/$BRIDGE_DATA_DIR_NAME"

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f -- \
    "$MANIFEST_PATH" \
    "$HOST_PATH" \
    "$INSTALLED_RELEASE_PATH" \
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
    "$RELEASE_SPEC_PATH" \
    "$HOST_PATH" \
    "$MANIFEST_PATH" \
    "$XPI_PATH" \
    "$INSTALLED_RELEASE_PATH" \
    "$EXTENSION_ID" \
    "$NATIVE_HOST_NAME" \
    "$UPDATE_URL" <<'PY'
from __future__ import annotations

import hashlib
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import Any


MAX_MANIFEST_BYTES = 256 * 1024
MAX_XPI_BYTES = 16 * 1024 * 1024
MAX_HOST_BYTES = 2 * 1024 * 1024
HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")

release_spec_path, host_path, native_manifest_path, xpi_path, installed_release_path = (
    map(Path, sys.argv[1:6])
)
EXPECTED_EXTENSION_ID, EXPECTED_HOST_NAME, EXPECTED_UPDATE_URL = sys.argv[6:9]


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    return value


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} must be a non-empty string")
    return value


def require_hash(value: Any, label: str) -> str:
    digest = require_string(value, label)
    if not HASH_PATTERN.fullmatch(digest):
        raise ValueError(f"{label} must be a lowercase SHA-256 digest")
    return digest


def require_https_github_url(value: Any, label: str) -> str:
    url = require_string(value, label)
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != "github.com":
        raise ValueError(f"{label} must be an HTTPS github.com URL")
    return url


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def download(url: str, maximum: int, label: str) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Noctalia-Thunderbird-Companion-Installer/1"},
    )
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                length = response.headers.get("Content-Length")
                if length and int(length) > maximum:
                    raise ValueError(f"{label} exceeds its size limit")
                data = response.read(maximum + 1)
            if len(data) > maximum:
                raise ValueError(f"{label} exceeds its size limit")
            return data
        except (OSError, urllib.error.URLError) as error:
            last_error = error
            if attempt < 2:
                time.sleep(1 + attempt)
    raise RuntimeError(f"could not download {label}: {last_error}")


def verified_download(asset: dict[str, Any], maximum: int, label: str) -> tuple[bytes, str]:
    url = require_https_github_url(asset.get("url"), f"{label} URL")
    expected = require_hash(asset.get("sha256"), f"{label} SHA-256")
    data = download(url, maximum, label)
    actual = sha256(data)
    if actual != expected:
        raise ValueError(f"{label} SHA-256 mismatch")
    return data, expected


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


os.umask(0o077)
spec = require_object(
    json.loads(release_spec_path.read_text(encoding="utf-8")),
    "bridge release specification",
)
if spec.get("schemaVersion") != 1:
    raise ValueError("unsupported bridge release specification")
version = require_string(spec.get("version"), "bridge release version")
bridge_protocol = spec.get("bridgeProtocol")
if bridge_protocol != 1:
    raise ValueError("unsupported bridge protocol")

manifest_spec = require_object(spec.get("manifest"), "release manifest reference")
manifest_url = require_https_github_url(manifest_spec.get("url"), "release manifest URL")
manifest_hash = require_hash(
    manifest_spec.get("sha256"),
    "release manifest SHA-256",
)
manifest_data = download(manifest_url, MAX_MANIFEST_BYTES, "release manifest")
if sha256(manifest_data) != manifest_hash:
    raise ValueError("release manifest SHA-256 mismatch")
release = require_object(json.loads(manifest_data), "release manifest")

if (
    release.get("schemaVersion") != 1
    or release.get("version") != version
    or release.get("bridgeProtocol") != bridge_protocol
):
    raise ValueError("release manifest is incompatible with the plugin")

extension = require_object(release.get("extension"), "extension release")
native_host = require_object(release.get("nativeHost"), "native-host release")
if extension.get("id") != EXPECTED_EXTENSION_ID:
    raise ValueError("release manifest has an unexpected extension ID")
if native_host.get("name") != EXPECTED_HOST_NAME:
    raise ValueError("release manifest has an unexpected native-host name")

xpi_data, xpi_hash = verified_download(
    require_object(extension.get("asset"), "extension asset"),
    MAX_XPI_BYTES,
    "extension",
)
host_data, host_hash = verified_download(
    require_object(native_host.get("asset"), "native-host asset"),
    MAX_HOST_BYTES,
    "native host",
)

with zipfile.ZipFile(io.BytesIO(xpi_data)) as archive:
    extension_manifest = require_object(
        json.loads(archive.read("manifest.json")),
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
    raise ValueError("XPI version does not match the compatible bridge release")
if gecko.get("id") != EXPECTED_EXTENSION_ID:
    raise ValueError("XPI has an unexpected extension ID")
if gecko.get("update_url") != EXPECTED_UPDATE_URL:
    raise ValueError("XPI has an unexpected update URL")

compile(host_data.decode("utf-8"), str(host_path), "exec")

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
installed_release = {
    "schemaVersion": 1,
    "version": version,
    "bridgeProtocol": bridge_protocol,
    "releaseManifestSha256": manifest_hash,
    "extensionSha256": xpi_hash,
    "nativeHostSha256": host_hash,
}
atomic_write(
    installed_release_path,
    (json.dumps(installed_release, indent=2) + "\n").encode(),
    0o600,
)
print(version)
PY
)"

# Remove files left by bridge releases that predated XDG_DATA_HOME storage.
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

Thunderbird will update the extension automatically. Noctalia will prompt for
setup again when the plugin requires a newer compatible native host.
EOF
