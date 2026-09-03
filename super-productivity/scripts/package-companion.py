#!/usr/bin/env python3
"""Validate and build the Super Productivity companion archive."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import pathlib
import re
import tomllib
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
COMPANION = ROOT / "companion"
DATA_DIR_NAME = "noctalia-super-productivity"
ARCHIVE_NAME = "noctalia-super-productivity.zip"
METADATA_NAME = "companion-package.json"
FILES = ("manifest.json", "plugin.js", "icon.svg")
TIMESTAMP = (1980, 1, 1, 0, 0, 0)


def default_output() -> pathlib.Path:
    configured = (os.environ.get("XDG_DATA_HOME") or "").strip()
    data_home = pathlib.Path(configured) if configured else pathlib.Path.home() / ".local/share"
    return data_home / DATA_DIR_NAME / ARCHIVE_NAME


def required(pattern: str, source: str, name: str) -> str:
    match = re.search(pattern, source)
    if match is None:
        raise SystemExit(f"{name} constant is missing")
    return match.group(1)


def validate_sources() -> dict[str, object]:
    manifest = json.loads((COMPANION / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("id") != "noctalia-super-productivity":
        raise SystemExit("unexpected companion plugin id")

    plugin_source = (COMPANION / "plugin.js").read_text(encoding="utf-8")
    service_source = (ROOT / "service.luau").read_text(encoding="utf-8")
    common_source = (ROOT / "common.luau").read_text(encoding="utf-8")
    plugin_manifest = tomllib.loads((ROOT / "plugin.toml").read_text(encoding="utf-8"))

    version = required(r"COMPANION_VERSION = '([^']+)'", plugin_source, "companion version")
    protocol = required(r"PROTOCOL_VERSION = (\d+)", plugin_source, "companion protocol")
    noctalia_protocol = required(r"M\.PROTOCOL_VERSION = (\d+)", common_source, "Noctalia protocol")
    schema = required(r"SCHEMA_VERSION = (\d+)", plugin_source, "companion schema")
    noctalia_schema = required(r"SCHEMA_VERSION = (\d+)", service_source, "Noctalia schema")
    bridge_name = required(r"BRIDGE_NAME = '([^']+)'", plugin_source, "companion bridge name")
    noctalia_bridge_name = required(r'BRIDGE_NAME = "([^"]+)"', service_source, "Noctalia bridge name")
    companion_limit = int(required(r"MAX_UPCOMING = (\d+)", plugin_source, "companion task limit"))
    setting = next(item for item in plugin_manifest["setting"] if item["key"] == "max_upcoming")

    if version != manifest.get("version"):
        raise SystemExit("companion version differs between manifest.json and plugin.js")
    if protocol != noctalia_protocol:
        raise SystemExit("protocol version differs between the companion and Noctalia")
    if schema != noctalia_schema:
        raise SystemExit("schema version differs between the companion and Noctalia")
    if bridge_name != noctalia_bridge_name:
        raise SystemExit("bridge directory name differs between the companion and Noctalia")
    if int(setting["max"]) > companion_limit:
        raise SystemExit("Noctalia max_upcoming exceeds the companion payload limit")
    return manifest


def source_sha256() -> str:
    digest = hashlib.sha256()
    for name in FILES:
        data = (COMPANION / name).read_bytes()
        digest.update(name.encode())
        digest.update(b"\0")
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


def build_archive() -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(
        output,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as archive:
        for name in FILES:
            info = zipfile.ZipInfo(name, TIMESTAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, (COMPANION / name).read_bytes())
    return output.getvalue()


def validate_archive(archive_data: bytes) -> None:
    with zipfile.ZipFile(io.BytesIO(archive_data)) as archive:
        if tuple(archive.namelist()) != FILES:
            raise SystemExit("companion archive contains unexpected files")
        for name in FILES:
            if archive.read(name) != (COMPANION / name).read_bytes():
                raise SystemExit(f"companion archive entry differs from source: {name}")


def atomic_write(path: pathlib.Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_file() and path.read_bytes() == data:
        path.chmod(mode)
        return
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
            # temporary may already have been replaced or removed
            pass


def package_metadata(
    manifest: dict[str, object], archive: bytes, output: pathlib.Path
) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "companionVersion": manifest["version"],
        "sourceSha256": source_sha256(),
        "archiveSha256": hashlib.sha256(archive).hexdigest(),
        "archiveSize": len(archive),
        "archivePath": str(output),
    }


def verify_generated_package(
    manifest: dict[str, object], archive: bytes, output: pathlib.Path
) -> None:
    metadata_path = output.with_name(METADATA_NAME)
    if not output.is_file() or not metadata_path.is_file():
        raise SystemExit("companion package has not been built")
    if output.read_bytes() != archive:
        raise SystemExit("generated companion archive differs from the bundled source")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    if metadata != package_metadata(manifest, archive, output):
        raise SystemExit("companion package metadata differs from the bundled source")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Validate the companion sources and deterministic archive without writing it.",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Verify an existing generated package against the bundled source.",
    )
    parser.add_argument(
        "--machine-readable",
        action="store_true",
        help="Print package details as KEY=VALUE lines.",
    )
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        help="Override the generated archive path.",
    )
    args = parser.parse_args()

    manifest = validate_sources()
    archive = build_archive()
    validate_archive(archive)
    if build_archive() != archive:
        raise SystemExit("companion archive generation is not deterministic")

    if args.check and args.verify:
        parser.error("--check and --verify cannot be used together")

    output = (args.output or default_output()).expanduser().absolute()
    if args.check:
        print("companion sources and deterministic archive are valid")
        return
    if args.verify:
        verify_generated_package(manifest, archive, output)
        if args.machine_readable:
            print(f"ZIP_PATH={output}")
            print(f"COMPANION_VERSION={manifest['version']}")
        else:
            print(f"{output} matches the bundled companion source")
        return

    os.umask(0o077)
    metadata_path = output.with_name(METADATA_NAME)
    metadata = package_metadata(manifest, archive, output)
    atomic_write(output, archive, 0o600)
    atomic_write(metadata_path, (json.dumps(metadata, indent=2, sort_keys=True) + "\n").encode(), 0o600)

    if args.machine_readable:
        print(f"ZIP_PATH={output}")
        print(f"COMPANION_VERSION={manifest['version']}")
    else:
        print(output)


if __name__ == "__main__":
    main()
