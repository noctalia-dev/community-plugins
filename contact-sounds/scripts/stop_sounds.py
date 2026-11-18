#!/usr/bin/env python3
"""Stop every PipeWire node the Noctalia sound player is currently playing.

The plugin (and Noctalia's own UI sounds) play through pw_stream nodes named
"noctalia-sound". The runtime API only exposes load/play with no stop, so the
panel's stop button runs this script: it finds those nodes in `pw-dump` and
destroys them via `pw-cli`, cutting off playback immediately (useful when a
long audio file is being tested).

Requires: pw-dump, pw-cli, python3 (all already plugin dependencies).
"""

import json
import shutil
import subprocess
import sys

NODE_NAME = "noctalia-sound"


def main() -> int:
    pw_dump = shutil.which("pw-dump")
    pw_cli = shutil.which("pw-cli")
    if pw_dump is None or pw_cli is None:
        print("contact-sounds: pw-dump and pw-cli are required to stop sounds", file=sys.stderr)
        return 1

    try:
        dump = subprocess.run(
            [pw_dump], check=True, capture_output=True, text=True, timeout=15
        ).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        print(f"contact-sounds: pw-dump failed: {exc}", file=sys.stderr)
        return 1

    try:
        objects = json.loads(dump)
    except json.JSONDecodeError as exc:
        print(f"contact-sounds: pw-dump produced invalid JSON: {exc}", file=sys.stderr)
        return 1

    targets = []
    for obj in objects:
        if obj.get("type") != "PipeWire:Interface:Node":
            continue
        props = obj.get("info", {}).get("props", {}) or {}
        if props.get("node.name") == NODE_NAME:
            targets.append(obj.get("id"))

    for node_id in targets:
        # A stale id (destroyed between dump and here) is normal; ignore errors.
        subprocess.run(
            [pw_cli, "destroy", str(node_id)],
            check=False,
            capture_output=True,
            text=True,
        )
    if targets:
        print(f"contact-sounds: stopped {len(targets)} sound stream(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())