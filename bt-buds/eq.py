#!/usr/bin/env python3
"""bt-buds EQ via ffmpeg: apps -> eq_in (null sink) -> ffmpeg DSP -> buds.

Usage: eq.py set <normal|more_bass|boost_vocals|more_highs> | eq.py get
Prints 'ok <preset>' or 'err <reason>'. Must finish in ~2s (caller timeout).
"""
import json
import os
import pwd
import shutil
import signal
import subprocess
import sys
import time

try:
    _HOME = pwd.getpwuid(os.getuid()).pw_dir
except KeyError:
    _HOME = os.path.expanduser("~")

_ENV = dict(os.environ)
_ENV.setdefault("PATH", "/usr/local/sbin:/usr/local/bin:/usr/bin")
_ENV.setdefault("HOME", _HOME)
_ENV.setdefault("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
_ENV.setdefault("DBUS_SESSION_BUS_ADDRESS",
                "unix:path=/run/user/%d/bus" % os.getuid())

STATE_DIR = os.path.expanduser("~/.local/state/bt-buds")
CUR_FILE = os.path.join(STATE_DIR, "eq.json")
PID_FILE = os.path.join(STATE_DIR, "eq-ffmpeg.pid")
EQ_SINK = "eq_in"

FILTERS = {
    "normal": "anull",
    "more_bass": "bass=g=7:f=150,treble=g=1:f=8000",
    "boost_vocals": "bass=g=-2:f=150,equalizer=f=1500:t=q:w=1:g=5,equalizer=f=4000:t=q:w=1:g=3,treble=g=1:f=10000",
    "more_highs": "bass=g=-2:f=150,equalizer=f=1500:t=q:w=1:g=1,treble=g=6:f=6000",
}
PRESETS = list(FILTERS.keys())


def run(*args, timeout=8):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=_ENV)


def sinks_short():
    try:
        return run("pactl", "list", "sinks", "short").stdout
    except subprocess.TimeoutExpired:
        return ""


def buds_sink(sinks_out):
    for line in sinks_out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].startswith("bluez_output."):
            return parts[1]
    return None


def wait_buds_sink(timeout=3.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        target = buds_sink(sinks_short())
        if target:
            return target
        time.sleep(0.5)
    return None


def list_inputs():
    """Parse `pactl list sink-inputs` -> [(id, sink, app, media)]."""
    try:
        out = run("pactl", "list", "sink-inputs").stdout
    except subprocess.TimeoutExpired:
        return []
    items, cur = [], None
    for line in out.splitlines():
        if line.startswith("Sink Input #"):
            if cur:
                items.append(cur)
            cur = {"id": line.split("#")[1].strip(), "sink": "", "app": "", "media": ""}
        elif cur is not None:
            s = line.strip()
            if s.startswith("Sink:"):
                cur["sink"] = s.split(":", 1)[1].strip()
            elif s.startswith("application.name"):
                cur["app"] = s.split("=", 1)[1].strip().strip('"')
            elif s.startswith("media.name"):
                cur["media"] = s.split("=", 1)[1].strip().strip('"')
    if cur:
        items.append(cur)
    return [(i["id"], i["sink"], i["app"], i["media"]) for i in items]


def own_ffmpeg_pids():
    found, me = [], os.getpid()
    try:
        pids = os.listdir("/proc")
    except OSError:
        return found
    for pid in pids:
        if not pid.isdigit() or int(pid) == me:
            continue
        try:
            with open("/proc/%s/cmdline" % pid, "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode()
        except (OSError, ValueError):
            continue
        if "ffmpeq-buds" in cmd and "eq.py" not in cmd:
            found.append(int(pid))
    return found


def stop_chain():
    for pid in own_ffmpeg_pids():
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    try:
        with open(PID_FILE) as f:
            old = int(f.read().strip())
        os.kill(old, signal.SIGTERM)
    except (OSError, ValueError):
        pass
    for pid in own_ffmpeg_pids():
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    try:
        os.unlink(PID_FILE)
    except OSError:
        pass


def save_cur(name):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(CUR_FILE, "w") as f:
        json.dump({"eq": name}, f)


def main(argv):
    if len(argv) == 1 and argv[0] == "get":
        try:
            with open(CUR_FILE) as f:
                name = json.load(f).get("eq", "normal")
        except (OSError, ValueError):
            name = "normal"
        if name not in PRESETS:
            name = "normal"
        print("ok %s" % name)
        return 0
    if len(argv) != 2 or argv[0] != "set" or argv[1] not in PRESETS:
        print("err usage: eq.py set <%s> | get" % "|".join(PRESETS))
        return 2
    name = argv[1]
    if shutil.which("ffmpeg") is None or shutil.which("pactl") is None:
        print("err no-deps")
        return 3

    sinks = sinks_short()
    target = buds_sink(sinks)
    if target is None:
        target = wait_buds_sink()
    if target is None:
        print("err no-buds")
        return 4
    if EQ_SINK not in sinks:
        try:
            r = run("pactl", "load-module", "module-null-sink",
                    "sink_name=" + EQ_SINK,
                    "sink_properties=device.description=BudsEQ")
            if r.returncode != 0:
                print("err eq-sink")
                return 5
        except subprocess.TimeoutExpired:
            print("err eq-sink")
            return 5

    stop_chain()

    os.makedirs(STATE_DIR, exist_ok=True)
    with open(os.path.join(STATE_DIR, "eq-ffmpeg.log"), "ab") as log:
        proc = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error",
             "-f", "pulse", "-i", EQ_SINK + ".monitor",
             "-af", FILTERS[name],
             "-f", "pulse", "-device", target, "ffmpeq-buds"],
            stdout=log, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL, start_new_session=True, env=_ENV)
    with open(PID_FILE, "w") as f:
        f.write(str(proc.pid))

    # wait (<=1s) until ffmpeg's input shows up in the graph
    seen = False
    for _ in range(10):
        time.sleep(0.1)
        if proc.poll() is not None:
            print("err ffmpeg-start")
            return 6
        for iid, sink, app, media in list_inputs():
            if media == "ffmpeq-buds":
                seen = True
                break
        if seen:
            break
    if not seen:
        print("err ffmpeg-start")
        return 6

    # single routing pass over one snapshot
    try:
        if run("pactl", "get-default-sink").stdout.strip() != EQ_SINK:
            run("pactl", "set-default-sink", EQ_SINK)
        for iid, sink, app, media in list_inputs():
            if media == "ffmpeq-buds":
                if sink != target:
                    run("pactl", "move-sink-input", iid, target)
            elif sink != EQ_SINK and not app.startswith("Lavf"):
                run("pactl", "move-sink-input", iid, EQ_SINK)
    except subprocess.TimeoutExpired:
        pass

    save_cur(name)
    print("ok %s" % name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
