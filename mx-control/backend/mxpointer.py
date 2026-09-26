# Copyright (C) 2026 Zach Wilke
# SPDX-License-Identifier: GPL-2.0-or-later
"""Per-device pointer acceleration through Hyprland's runtime Lua API.

Logitech mice have no acceleration setting of their own: the feel comes from
libinput. This module turns a per-device preference ("system" or "mac") into
a libinput custom acceleration curve and hands it to Hyprland with
`hl.device({...})` over the IPC socket. Nothing under ~/.config/hypr/ is
written; the compositor forgets the override on config reload, so the helper
listens for `configreloaded` on the event socket and re-applies.
"""
from __future__ import annotations

import json
import math
import os
import re
import socket
from pathlib import Path

ACCEL_MODES = ("system", "mac")
ACCEL_LABELS = {"system": "System default", "mac": "macOS-style"}
REFERENCE_DPI = 1000
DPI_MIN = 100
DPI_MAX = 20000

# Curve shape, defined at 1000 DPI where one device unit per millisecond is
# one inch per second. Gain starts a touch under 1:1 so slow, precise moves
# stay steady, then rises with speed and saturates on flicks, which is the
# feel macOS users expect. libinput extrapolates the last two points, so the
# tail is nearly linear by design.
MAC_GAIN_MIN = 0.8
MAC_GAIN_MAX = 3.2
MAC_KNEE = 4.0  # units/ms at which half the extra gain is reached
MAC_STEP = 1.0
MAC_POINTS = 25  # libinput allows up to 64

HYPR_NAME_RE = re.compile(r"[a-z0-9][a-z0-9._-]{0,120}")
SYSFS_HIDRAW = Path("/sys/class/hidraw")


def mac_gain(speed: float) -> float:
    """Acceleration factor at a given input speed (units/ms, 1000 DPI)."""
    speed = max(0.0, float(speed))
    weight = speed * speed / (speed * speed + MAC_KNEE * MAC_KNEE)
    return MAC_GAIN_MIN + (MAC_GAIN_MAX - MAC_GAIN_MIN) * weight


def _fmt(value: float) -> str:
    text = f"{value:.4f}".rstrip("0").rstrip(".")
    return text if text and text != "-0" else "0"


def clamp_dpi(dpi) -> int:
    try:
        number = float(dpi)
    except (TypeError, ValueError):
        return REFERENCE_DPI
    if not math.isfinite(number) or number <= 0:
        return REFERENCE_DPI
    return max(DPI_MIN, min(DPI_MAX, int(round(number))))


def mac_curve(dpi=REFERENCE_DPI) -> str:
    """libinput custom profile in Hyprland's `custom <step> <points>` form.

    Both axes are raw device units, so the curve is scaled by the sensor's
    DPI: the same hand speed yields the same gain at any DPI, and DPI keeps
    acting as the overall tracking speed, like the macOS slider.
    """
    scale = clamp_dpi(dpi) / REFERENCE_DPI
    step = MAC_STEP * scale
    points = []
    for index in range(MAC_POINTS):
        speed = index * MAC_STEP
        points.append(_fmt(speed * mac_gain(speed) * scale))
    return "custom " + _fmt(step) + " " + " ".join(points)


def accel_mode(value) -> str:
    text = str(value or "system").strip().lower()
    if text not in ACCEL_MODES:
        raise ValueError("Acceleration must be one of: " + ", ".join(ACCEL_MODES))
    return text


def hypr_device_slug(name: str) -> str:
    """Hyprland's deviceNameToInternalString: spaces to hyphens, lowercase."""
    return str(name or "").replace(" ", "-").replace("\n", "-").lower()


def match_hypr_names(candidates, input_names) -> list[str]:
    """Hyprland names that belong to one of the evdev input names. Hyprland
    suffixes duplicates with -1, -2, ... so accept those too."""
    wanted = {hypr_device_slug(n) for n in input_names if str(n or "").strip()}
    found = []
    for raw in candidates:
        name = str(raw or "")
        base = re.sub(r"-\d+$", "", name)
        if name in wanted or base in wanted:
            found.append(name)
    return found


def evdev_names_for_hidraw(path, root: Path | None = None) -> list[str]:
    """Input device names under the hid device that owns a hidraw node."""
    node = Path(str(path or "")).name
    if not re.fullmatch(r"hidraw\d+", node):
        return []
    base = (root or SYSFS_HIDRAW) / node / "device" / "input"
    names = []
    try:
        entries = sorted(base.glob("input*"))
    except OSError:
        return []
    for entry in entries:
        try:
            text = (entry / "name").read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            continue
        if text:
            names.append(text)
    return names


def device_dpi(item: dict) -> int:
    for setting in item.get("settings") or []:
        if str(setting.get("name") or "").lower() in ("dpi", "dpi-extended", "dpi_extended"):
            value = setting.get("value")
            if isinstance(value, dict):
                value = value.get("id")
            return clamp_dpi(value)
    return REFERENCE_DPI


def lua_device_config(hypr_name: str, profile: str | None) -> str:
    """Lua for one device. Names are checked against a strict slug pattern so
    a crafted USB descriptor can never become code."""
    if not HYPR_NAME_RE.fullmatch(str(hypr_name or "")):
        raise ValueError("Unsupported Hyprland device name")
    if profile is None:
        value = 'hl.get_config("input.accel_profile") or ""'
    else:
        if not re.fullmatch(r"[a-z0-9. -]{1,4000}", profile):
            raise ValueError("Unsupported acceleration profile")
        value = json.dumps(profile)
    return "hl.device({ name = %s, accel_profile = %s })" % (json.dumps(hypr_name), value)


def desired_profiles(devices: list[dict], prefs: dict, hypr_mice, sysfs_root: Path | None = None) -> tuple[dict, list[str]]:
    """Map Hyprland mouse names to the curve they should carry. Returns the
    mapping and the ids of devices that wanted acceleration but have no
    Hyprland mouse to apply it to."""
    wanted = {}
    missing = []
    for item in devices:
        did = str(item.get("id") or "")
        pref = (prefs or {}).get(did) or {}
        if accel_mode(pref.get("acceleration")) != "mac":
            continue
        if str(item.get("kind") or "") == "keyboard":
            continue
        names = match_hypr_names(hypr_mice, evdev_names_for_hidraw(item.get("path"), sysfs_root))
        if not names:
            if item.get("online") is not False:
                missing.append(did)
            continue
        curve = mac_curve(device_dpi(item))
        for name in names:
            wanted[name] = curve
    return wanted, missing


class HyprlandEvents:
    """Non-blocking reader on Hyprland's event socket, used only to notice
    `configreloaded`. Connected while an override is active."""
    def __init__(self, path=None):
        self.path = path
        self.sock = None
        self.buffer = b""

    def socket_path(self):
        if self.path is not None:
            return self.path
        signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,200}", signature):
            raise RuntimeError("No Hyprland instance is available")
        runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
        return f"{runtime}/hypr/{signature}/.socket2.sock"

    def fileno(self):
        return self.sock.fileno() if self.sock is not None else None

    def connect(self) -> bool:
        if self.sock is not None:
            return True
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(0.35)
            sock.connect(self.socket_path())
            sock.setblocking(False)
        except Exception:
            return False
        self.sock = sock
        self.buffer = b""
        return True

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None
        self.buffer = b""

    def drain(self) -> bool:
        """Read whatever is pending. True when a config reload was seen."""
        if self.sock is None:
            return False
        reloaded = False
        while True:
            try:
                chunk = self.sock.recv(65536)
            except (BlockingIOError, InterruptedError):
                break
            except OSError:
                self.close()
                return reloaded
            if not chunk:
                self.close()
                return reloaded
            self.buffer += chunk
            if len(self.buffer) > 262144:
                self.buffer = self.buffer[-4096:]
        if b"\n" in self.buffer:
            lines = self.buffer.split(b"\n")
            self.buffer = lines.pop()
            for line in lines:
                if line.startswith(b"configreloaded>>"):
                    reloaded = True
        return reloaded


class PointerRuntime:
    """Keeps Hyprland's per-device acceleration in step with the saved
    preference. `sync` is idempotent and only talks to Hyprland when the
    desired state differs from what was last applied (or when forced after a
    compositor reload)."""
    def __init__(self, request=None, events=None, sysfs_root: Path | None = None):
        if request is None:
            from mxactions import HyprlandIPC
            request = HyprlandIPC()
        self.request = request
        self.events = events or HyprlandEvents()
        self.sysfs_root = sysfs_root
        self.applied: dict[str, str] = {}
        self.error = ""
        self.missing: list[str] = []
        self.fingerprint = None

    @property
    def available(self) -> bool:
        return bool(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"))

    def event_fd(self):
        return self.events.fileno()

    def hypr_mice(self) -> list[str]:
        data = json.loads(self.request("j/devices"))
        return [str(m.get("name") or "") for m in data.get("mice") or [] if isinstance(m, dict)]

    def force_no_accel(self) -> bool:
        try:
            data = json.loads(self.request("j/getoption input:force_no_accel"))
        except Exception:
            return False
        return bool(data.get("bool")) if isinstance(data, dict) else False

    def _send(self, lua: str) -> None:
        result = self.request("/eval " + lua).strip()
        if result.lower() not in ("", "ok"):
            raise RuntimeError("Hyprland rejected the device config: " + result[:160])

    @staticmethod
    def _fingerprint(devices: list[dict], prefs: dict):
        rows = []
        for item in devices:
            did = str(item.get("id") or "")
            rows.append((did, str(item.get("path") or ""), str(item.get("kind") or ""), item.get("online") is not False, device_dpi(item)))
        wanted = tuple(sorted((str(k), str((v or {}).get("acceleration") or "")) for k, v in (prefs or {}).items()))
        return (tuple(sorted(rows)), wanted)

    def sync(self, devices: list[dict], prefs: dict, force: bool = False) -> bool:
        """Apply or revert overrides. Returns True when the published status
        (error or applied set) changed. Without `force`, an unchanged input
        costs no IPC at all, so idle wakes stay free."""
        before = (self.error, dict(self.applied), list(self.missing))
        fingerprint = self._fingerprint(devices, prefs)
        if not force and fingerprint == self.fingerprint:
            if self.applied:
                self.events.connect()
            return False
        self.fingerprint = fingerprint
        active = any(accel_mode((p or {}).get("acceleration")) == "mac" for p in (prefs or {}).values())
        if not active and not self.applied:
            self.events.close()
            self.error = ""
            self.missing = []
            return before != (self.error, dict(self.applied), list(self.missing))
        if not self.available:
            self.error = "Hyprland is not running, so pointer acceleration cannot apply"
            return before != (self.error, dict(self.applied), list(self.missing))
        try:
            wanted, missing = desired_profiles(devices, prefs, self.hypr_mice(), self.sysfs_root)
            self.missing = missing
            for name in list(self.applied):
                if name not in wanted:
                    self._send(lua_device_config(name, None))
                    self.applied.pop(name, None)
            for name, curve in wanted.items():
                if force or self.applied.get(name) != curve:
                    self._send(lua_device_config(name, curve))
                    self.applied[name] = curve
            if wanted and self.force_no_accel():
                self.error = "Hyprland's input.force_no_accel is on, which disables all pointer acceleration"
            elif missing:
                self.error = "Hyprland has not listed this mouse yet; reconnect it to apply acceleration"
            else:
                self.error = ""
        except Exception as exc:
            self.error = "Pointer acceleration: " + str(exc)[:200]
            # Retry on the next wake rather than trusting a failed apply.
            self.fingerprint = None
        if self.applied:
            self.events.connect()
        else:
            self.events.close()
        return before != (self.error, dict(self.applied), list(self.missing))

    def poll(self) -> bool:
        """Call after every wake. True when Hyprland reloaded its config and
        the overrides must be re-sent."""
        return self.events.drain()

    def status(self) -> dict:
        return {
            "available": self.available,
            "error": self.error,
            "applied": sorted(self.applied),
            "missing": list(self.missing),
        }

    def shutdown(self) -> None:
        """Best-effort revert so a disabled plugin leaves libinput defaults."""
        for name in list(self.applied):
            try:
                self._send(lua_device_config(name, None))
            except Exception:
                pass
            self.applied.pop(name, None)
        self.events.close()
