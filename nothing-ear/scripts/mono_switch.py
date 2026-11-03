#!/usr/bin/env python3
"""Mono downmix control for the Noctalia plugin's mono-audio feature.

Operates entirely at the PipeWire/PulseAudio layer via `pactl`, independent
of earbud model or firmware: the RFCOMM protocol has no mono command, and
even if it did, it would only ever cover this plugin's hardware-verified
SKU. Downmixing the earbuds' own Bluetooth audio sink instead works for any
headset PipeWire can see.

Mechanism: load a `module-remap-sink` with `channels=1 channel_map=mono`
in front of the earbuds' real sink. Any stereo stream connecting to a
1-channel sink gets downmixed to mono by PipeWire's own resampler on the
way in; the remap module then fans that single channel back out to both of
the master sink's channels on the way out. No new setting/state is invented
beyond a JSON breadcrumb recording which real sink to revert to.

Stateless per invocation, like nothing_ear_ctl.py: every command re-derives
"is mono currently active" by asking pactl for our module, rather than
trusting the breadcrumb file, so a stale file after a crash can't cause a
false positive.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess

CACHE_DIR = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
STATE_FILE = os.path.join(CACHE_DIR, "nothing_ear_mono_state.json")
MONO_SINK_NAME = "nothing_ear_mono"
PACTL_TIMEOUT = 3.0


def run_pactl(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["pactl", *args], capture_output=True, text=True, timeout=PACTL_TIMEOUT
    )


def list_sinks() -> list[tuple[str, str]]:
    """[(index, name), ...] or [] if pactl/PipeWire isn't reachable."""
    try:
        proc = run_pactl(["list", "short", "sinks"])
    except (OSError, subprocess.TimeoutExpired):
        return []
    if proc.returncode != 0:
        return []
    out = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            out.append((parts[0], parts[1]))
    return out


def list_modules() -> list[tuple[str, str, str]]:
    """[(index, name, args), ...]"""
    try:
        proc = run_pactl(["list", "short", "modules"])
    except (OSError, subprocess.TimeoutExpired):
        return []
    if proc.returncode != 0:
        return []
    out = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            out.append((parts[0], parts[1], parts[2] if len(parts) > 2 else ""))
    return out


def find_bud_sink(mac: str) -> str | None:
    # e.g. "AA:BB:CC:DD:EE:FF" -> bluez sink names of the form
    # "bluez_output.AA_BB_CC_DD_EE_FF.<profile>" (profile index varies by
    # codec/profile, so it's left as a wildcard).
    underscored = re.escape(mac.replace(":", "_").upper())
    pattern = re.compile(r"^bluez_output\." + underscored + r"(\.\d+)?$", re.IGNORECASE)
    for _, name in list_sinks():
        if pattern.match(name):
            return name
    return None


def sink_description(sink_name: str) -> str | None:
    """Human-readable name pactl shows for a sink, e.g. "Ear (2)"."""
    try:
        proc = run_pactl(["list", "sinks"])
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    current = None
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.startswith("Name:"):
            current = line.split(":", 1)[1].strip()
        elif line.startswith("Description:") and current == sink_name:
            return line.split(":", 1)[1].strip()
    return None


def find_mono_module() -> tuple[str, str] | None:
    """(module_id, master_sink_name) for our remap module, if it's loaded."""
    for index, name, args in list_modules():
        if name != "module-remap-sink" or f"sink_name={MONO_SINK_NAME}" not in args:
            continue
        m = re.search(r"master=(\S+)", args)
        return (index, m.group(1) if m else "")
    return None


def read_state() -> dict:
    try:
        with open(STATE_FILE) as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write_state(state: dict) -> None:
    if not state:
        try:
            os.remove(STATE_FILE)
        except OSError:
            pass
        return
    with open(STATE_FILE + ".tmp", "w") as f:
        json.dump(state, f)
    os.replace(STATE_FILE + ".tmp", STATE_FILE)


def default_sink() -> str | None:
    proc = run_pactl(["get-default-sink"])
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def move_sink_inputs(from_sink_name: str, to_sink_name: str) -> None:
    sinks = dict((name, index) for index, name in list_sinks())
    from_index = sinks.get(from_sink_name)
    if from_index is None:
        return
    proc = run_pactl(["list", "short", "sink-inputs"])
    if proc.returncode != 0:
        return
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[1] == from_index:
            run_pactl(["move-sink-input", parts[0], to_sink_name])


def mono_on(mac: str | None) -> dict:
    if not mac:
        return {"ok": False, "error": "no_device"}

    existing = find_mono_module()
    bud_sink = find_bud_sink(mac)

    if existing is not None:
        module_id, master = existing
        if bud_sink is not None and master == bud_sink:
            # Loaded for the right sink; make sure audio is actually going
            # through it (the user may have picked the plain sink since).
            if default_sink() != MONO_SINK_NAME:
                run_pactl(["set-default-sink", MONO_SINK_NAME])
                move_sink_inputs(bud_sink, MONO_SINK_NAME)
            return {"ok": True, "active": True}
        # Stale module (buds reconnected under a new sink name, or the
        # master sink is gone) — drop it and fall through to reload.
        run_pactl(["unload-module", module_id])

    if bud_sink is None:
        # Buds aren't a live PipeWire sink right now (not connected as an
        # audio device, or audio profile hasn't come up yet) — no sink to
        # downmix, so this is a no-op rather than an error.
        return {"ok": True, "active": False, "reason": "no_sink"}

    current_default = default_sink()
    if current_default != bud_sink:
        # The earbuds aren't where system audio is currently going, so
        # there's nothing to make mono. Avoids silently downmixing
        # whatever sink actually is the default (e.g. speakers).
        return {"ok": True, "active": False, "reason": "not_default"}

    # Without a description the output menu shows "Remapped bluez_output.… sink".
    label = (sink_description(bud_sink) or "Earbuds") + " (Mono)"
    label = label.replace("'", "").replace('"', "")
    load = run_pactl(
        [
            "load-module",
            "module-remap-sink",
            f"sink_name={MONO_SINK_NAME}",
            f"master={bud_sink}",
            "channels=1",
            "channel_map=mono",
            # the whole value is quoted, so spaces in the name survive
            f"sink_properties='device.description=\"{label}\"'",
        ]
    )
    if load.returncode != 0:
        return {"ok": False, "error": load.stderr.strip() or "load-module failed"}

    run_pactl(["set-default-sink", MONO_SINK_NAME])
    move_sink_inputs(bud_sink, MONO_SINK_NAME)
    write_state({"original_sink": bud_sink})
    return {"ok": True, "active": True}


def mono_off(_mac: str | None) -> dict:
    existing = find_mono_module()
    if existing is None:
        write_state({})
        return {"ok": True, "active": False}

    module_id, master = existing
    state = read_state()
    target = state.get("original_sink") or master
    if target and not any(name == target for _, name in list_sinks()):
        target = master  # breadcrumb pointed at a sink that no longer exists

    if target:
        if default_sink() == MONO_SINK_NAME:
            run_pactl(["set-default-sink", target])
        move_sink_inputs(MONO_SINK_NAME, target)

    run_pactl(["unload-module", module_id])
    write_state({})
    return {"ok": True, "active": False}


def mono_status(_mac: str | None) -> dict:
    existing = find_mono_module()
    if existing is None:
        return {"ok": True, "active": False}
    if default_sink() != MONO_SINK_NAME:
        # The user picked another output (or the plain earbuds sink) from the
        # audio menu, so audio no longer goes through the mono sink. Treat
        # that as turning mono off and clean up the leftover sink.
        mono_off(_mac)
        return {"ok": True, "active": False, "reason": "user_switched"}
    return {"ok": True, "active": True}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["mono-on", "mono-off", "mono-status"])
    parser.add_argument("--mac", default=None, help="earbuds MAC address")
    args = parser.parse_args()

    try:
        if args.command == "mono-on":
            result = mono_on(args.mac)
        elif args.command == "mono-off":
            result = mono_off(args.mac)
        else:
            result = mono_status(args.mac)
    except (OSError, subprocess.TimeoutExpired) as e:
        result = {"ok": False, "error": str(e)}

    print(json.dumps(result))


if __name__ == "__main__":
    main()
