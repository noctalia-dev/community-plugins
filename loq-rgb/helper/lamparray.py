#!/usr/bin/env python3
"""
lamparray.py - HID LampArray transport and colour animator for the Noctalia "LOQ RGB" plugin.

Why this file exists: sending a HID *feature* report needs an ioctl(), which Luau plugins cannot do.
This single dependency-free script (Python 3 standard library only, nothing to compile) is the only
non-Luau piece. It owns the device, applies colours with smooth transitions and reports its state.
The plugin keeps all the logic: UI, profiles, palette, gradients, persistence.

Usage:   lamparray.py DATA_DIR

Input:   DATA_DIR/command.txt   key=value lines, last line "END" (the plugin writes it atomically)
             seq=<int>  mode=rgb|off|auto  br=0-100  ms=<transition>  colors=rrggbb,rrggbb,...
Output:  stdout, one event per line:  STATE {json} | BEAT {}
Works with any keyboard exposing the standard HID LampArray interface (usage page 0x59).
"""
import ctypes
import ctypes.util
import fcntl
import glob
import json
import os
import select
import signal
import struct
import sys
import threading
import time

LIGHTING_PAGE = 0x59
USAGES = {
    0x02: "attributes",     # LampArrayAttributesReport
    0x20: "attr_request",   # LampAttributesRequestReport
    0x22: "attr_response",  # LampAttributesResponseReport
    0x50: "multi_update",   # LampMultiUpdateReport
    0x60: "range_update",   # LampRangeUpdateReport
    0x70: "control",        # LampArrayControlReport
}
KIND_KEYBOARD = 1
MAX_ZONES = 32            # per-key keyboards are grouped into at most this many columns
WATCHDOG_S = 5.0
HEX = "0123456789abcdef"
IN_CLOSE_WRITE, IN_MOVED_TO = 0x8, 0x80


# ----------------------------------------------------------------------------- HID descriptor
def parse_descriptor(desc):
    """Return (is_lamparray, reports); reports: name -> {id, kind, bits, size}."""
    reports = {}
    page = rsize = rcount = 0
    rid = None
    stack = []
    locals_ = []
    is_lamp = False
    sizes = (0, 1, 2, 4)
    i, n = 0, len(desc)
    while i < n:
        b = desc[i]
        if b == 0xFE:                       # long item
            if i + 1 >= n:
                break
            i += 3 + desc[i + 1]
            continue
        size = sizes[b & 3]
        typ, tag = (b >> 2) & 3, b >> 4
        if i + 1 + size > n:
            break
        data = int.from_bytes(desc[i + 1:i + 1 + size], "little")
        i += 1 + size
        if typ == 1:                        # global
            if tag == 0:
                page = data
            elif tag == 7:
                rsize = data
            elif tag == 8:
                rid = data
            elif tag == 9:
                rcount = data
        elif typ == 2:                      # local
            if tag == 0:
                locals_.append((page, data))
        elif typ == 0:                      # main
            if tag == 0xA:                  # collection
                use = locals_[-1] if locals_ else None
                name = None
                if use and use[0] == LIGHTING_PAGE:
                    if not stack and use[1] == 0x01 and data == 0x01:
                        is_lamp = True
                    name = USAGES.get(use[1])
                if name and name not in reports:
                    reports[name] = {"id": rid, "kind": None, "bits": 0}
                stack.append(name)
            elif tag == 0xC:
                if stack:
                    stack.pop()
            elif tag in (0x8, 0x9, 0xB):
                name = next((s for s in reversed(stack) if s), None)
                if name:
                    reports[name]["bits"] += rsize * rcount
                    reports[name]["kind"] = {0x8: "input", 0x9: "output", 0xB: "feature"}[tag]
            locals_ = []
    for r in reports.values():
        r["size"] = 1 + (r["bits"] + 7) // 8
    return is_lamp, reports


def _read(path, mode="r"):
    with open(path, mode) as f:
        return f.read()


def _uevent(sysdir):
    out = {}
    try:
        for line in _read(sysdir + "/device/uevent").splitlines():
            k, _, v = line.partition("=")
            out[k] = v
    except OSError:
        pass
    return out


def _ids(uevent):
    parts = uevent.get("HID_ID", "").split(":")
    if len(parts) == 3:
        return parts[1][-4:].lower(), parts[2][-4:].lower()
    return "", ""


def scan_devices(sysroot="/sys/class/hidraw"):
    """All hidraw nodes exposing a HID LampArray, plus a short inventory of every hidraw device."""
    found, inventory = [], []
    for sysdir in sorted(glob.glob(sysroot + "/hidraw*")):
        node = "/dev/" + os.path.basename(sysdir)
        ue = _uevent(sysdir)
        vid, pid = _ids(ue)
        try:
            lamp, reports = parse_descriptor(_read(sysdir + "/device/report_descriptor", "rb"))
        except OSError:
            lamp, reports = False, {}
        inventory.append({"name": ue.get("HID_NAME", "?"), "vid": vid, "pid": pid, "lamparray": lamp})
        if not lamp:
            continue
        try:
            iface = _read(sysdir + "/device/../bInterfaceNumber").strip()
        except OSError:
            iface = ""
        found.append({"node": node, "name": ue.get("HID_NAME", "?"), "vid": vid, "pid": pid,
                      "iface": iface, "reports": reports})
    return found, inventory[:16]


# ----------------------------------------------------------------------------- device I/O
def _ioc(nr, size):
    return (3 << 30) | (size << 16) | (ord("H") << 8) | nr   # _IOC(WRITE|READ, 'H', nr, size)


class HidrawDevice:
    def __init__(self, node):
        self.fd = os.open(node, os.O_RDWR | os.O_CLOEXEC)

    def set_feature(self, data):
        fcntl.ioctl(self.fd, _ioc(0x06, len(data)), bytes(data))

    def get_feature(self, report_id, size):
        buf = bytearray(size)
        buf[0] = report_id
        fcntl.ioctl(self.fd, _ioc(0x07, size), buf, True)
        return bytes(buf)

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass


class Session:
    """One opened LampArray: attributes, lamp grouping and packet building."""

    def __init__(self, dev, reports):
        for need in ("attributes", "multi_update", "control"):
            if need not in reports or reports[need]["id"] is None:
                raise ValueError("report missing in descriptor: " + need)
        self.dev, self.rep = dev, reports
        self.cap = max(1, (reports["multi_update"]["size"] - 3) // 6)   # lamps per update packet

    def _pad(self, key, data):
        return bytes(data).ljust(self.rep[key]["size"], b"\x00")

    def attributes(self):
        r = self.rep["attributes"]
        buf = self.dev.get_feature(r["id"], 64)      # 64 B: the size validated on real hardware
        count, w, h, d, kind, interval = struct.unpack_from("<HIIIII", buf, 1)
        return {"count": count, "kind": kind, "interval_us": interval, "size_um": [w, h, d]}

    def set_autonomous(self, on):
        self.dev.set_feature(self._pad("control", [self.rep["control"]["id"], 1 if on else 0]))

    def positions(self, count):
        """(x, y) in micrometres for every lamp, or None when the device does not expose them."""
        if "attr_request" not in self.rep or "attr_response" not in self.rep:
            return None
        req, resp = self.rep["attr_request"], self.rep["attr_response"]
        out = []
        for lamp in range(count):
            self.dev.set_feature(self._pad("attr_request", bytes([req["id"]]) + struct.pack("<H", lamp)))
            buf = self.dev.get_feature(resp["id"], 64)
            _id, x, y = struct.unpack_from("<HII", buf, 1)
            out.append((x, y))
        return out

    def send(self, items):
        """items: [(lamp_id, (r, g, b))]. Only the last packet carries LampUpdateComplete."""
        mu = self.rep["multi_update"]
        for k in range(0, len(items), self.cap):
            chunk = items[k:k + self.cap]
            last = k + self.cap >= len(items)
            pkt = bytearray([mu["id"], len(chunk), 1 if last else 0])
            for lamp, _ in chunk:
                pkt += struct.pack("<H", lamp)
            pkt += b"\x00\x00" * (self.cap - len(chunk))
            for _, (r, g, b) in chunk:
                pkt += bytes([r, g, b, 255])
            pkt += b"\x00\x00\x00\x00" * (self.cap - len(chunk))
            self.dev.set_feature(self._pad("multi_update", pkt))

    def close(self):
        self.dev.close()


def make_bins(count, positions):
    """Lamps -> zones. <= MAX_ZONES lamps: one zone per lamp. Otherwise grouped left-to-right."""
    if count <= MAX_ZONES:
        return [[i] for i in range(count)]
    order = list(range(count))
    if positions:
        order.sort(key=lambda i: positions[i])
    return [order[k * count // MAX_ZONES:(k + 1) * count // MAX_ZONES] for k in range(MAX_ZONES)]


# ----------------------------------------------------------------------------- animation
class Engine:
    """Colour state and transitions (pure logic, no I/O)."""

    def __init__(self, zones):
        self.zones = zones
        self.cur = [[0.0, 0.0, 0.0] for _ in range(zones)]
        self.start = [list(c) for c in self.cur]
        self.goal = [list(c) for c in self.cur]
        self.t0, self.dur, self.active = 0.0, 0.0, False

    def retarget(self, goal, ms, now, snap=False):
        self.start = [list(c) for c in self.cur]
        self.goal = [[float(v) for v in c] for c in goal]
        if snap or ms <= 0:
            self.cur = [list(c) for c in self.goal]
            self.active = False
        else:
            self.t0, self.dur, self.active = now, ms / 1000.0, True

    def step(self, now):
        if not self.active:
            return
        p = (now - self.t0) / self.dur
        if p >= 1.0:
            self.cur = [list(c) for c in self.goal]
            self.active = False
            return
        e = p * p * (3 - 2 * p)                      # smoothstep
        for i in range(self.zones):
            for k in range(3):
                self.cur[i][k] = self.start[i][k] + (self.goal[i][k] - self.start[i][k]) * e

    def frame(self):
        return [tuple(max(0, min(255, int(round(v)))) for v in c) for c in self.cur]


def parse_command(text):
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if not lines or lines[-1] != "END":
        return None                                   # incomplete write: wait for the next event
    kv = {}
    for ln in lines[:-1]:
        k, _, v = ln.partition("=")
        kv[k.strip()] = v.strip()
    try:
        seq = int(kv["seq"])
        br = max(0, min(100, int(kv.get("br", "100"))))
        ms = max(0, min(5000, int(kv.get("ms", "300"))))
    except (KeyError, ValueError):
        return None
    mode = kv.get("mode")
    if mode not in ("rgb", "off", "auto"):
        return None
    colors = []
    for c in kv.get("colors", "").split(","):
        c = c.strip().lstrip("#").lower()
        if len(c) == 6 and all(ch in HEX for ch in c):
            colors.append((int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16)))
    if mode == "rgb" and not colors:
        return None
    return {"seq": seq, "mode": mode, "br": br, "ms": ms, "colors": colors}


def resample(colors, n):
    if len(colors) == n:
        return list(colors)
    return [colors[min(len(colors) - 1, i * len(colors) // n)] for i in range(n)]


class Inotify:
    def __init__(self, path):
        libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
        self.fd = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            raise OSError("inotify unavailable")
        if libc.inotify_add_watch(self.fd, path.encode(), IN_CLOSE_WRITE | IN_MOVED_TO) < 0:
            raise OSError("inotify_add_watch failed")

    def names(self):
        out = []
        try:
            buf = os.read(self.fd, 8192)
        except BlockingIOError:
            return out
        off = 0
        while off + 16 <= len(buf):
            _wd, _mask, _cookie, ln = struct.unpack_from("iIII", buf, off)
            out.append(buf[off + 16:off + 16 + ln].rstrip(b"\0").decode(errors="replace"))
            off += 16 + ln
        return out


# ----------------------------------------------------------------------------- the helper
class Helper:
    def __init__(self, data_dir, opener=HidrawDevice, scanner=scan_devices, out=None):
        self.dir = data_dir
        self.cmd_path = os.path.join(data_dir, "command.txt")
        self.pid_path = os.path.join(data_dir, "helper.pid")
        self.opener, self.scanner = opener, scanner
        self.out = out or sys.stdout
        self.session = self.engine = self.bins = None
        self.info = {}
        self.has_control = False
        self.last_sent = {}
        self.desired = None
        self.last_seq = None
        self.last_state = ""
        self.next_connect = 0.0
        self.next_frame = 0.0
        self.frame_dt = 1 / 60
        self.min_dt = 1 / 60
        self.watchdog_due = time.monotonic() + WATCHDOG_S
        self.last_wall, self.last_mono = time.time(), time.monotonic()
        self.ppid = os.getppid()
        self.stop_flag = False
        self.handback = True
        self.cmd_sig = None
        self.ino = None

    # ---- output
    def emit(self, tag, obj=None):
        line = tag if obj is None else tag + " " + json.dumps(obj, separators=(",", ":"))
        try:
            self.out.write(line + "\n")
            self.out.flush()
        except (BrokenPipeError, ValueError):
            raise SystemExit(0)

    def emit_state(self, obj):
        s = json.dumps(obj, sort_keys=True)
        if s != self.last_state:                       # no spam while retrying
            self.last_state = s
            self.emit("STATE", obj)

    # ---- connection
    def connect(self):
        cands, inventory = self.scanner()
        if not cands:
            self.emit_state({"state": "no_device", "hid": inventory})
            return 5.0
        denied, failure, best = None, None, None
        for c in cands:
            try:
                dev = self.opener(c["node"])
            except PermissionError:
                denied = denied or c
                continue
            except OSError as e:
                failure = str(e)
                continue
            try:
                sess = Session(dev, c["reports"])
                attrs = sess.attributes()
            except (OSError, ValueError) as e:
                failure = str(e)
                dev.close()
                continue
            if best is None or (attrs["kind"] == KIND_KEYBOARD and best[1]["kind"] != KIND_KEYBOARD):
                if best:
                    best[0].close()
                best = (sess, attrs, c)
            else:
                sess.close()
            if attrs["kind"] == KIND_KEYBOARD:
                break
        if best is None:
            if denied:
                self.emit_state({"state": "needs_access", "name": denied["name"], "vid": denied["vid"],
                                 "pid": denied["pid"], "iface": denied["iface"]})
                return 2.0
            self.emit_state({"state": "error", "message": failure or "device unavailable"})
            return 3.0
        sess, attrs, c = best
        if attrs["count"] < 1:
            sess.close()
            self.emit_state({"state": "error", "message": "the device reports no lamps"})
            return 5.0
        try:
            positions = sess.positions(attrs["count"]) if attrs["count"] > MAX_ZONES else None
        except OSError:
            positions = None
        self.session, self.bins = sess, make_bins(attrs["count"], positions)
        self.engine = Engine(len(self.bins))
        self.min_dt = max(1 / 60, attrs["interval_us"] / 1e6)
        self.frame_dt = self.min_dt
        self.has_control, self.last_sent = False, {}
        self.info = {"state": "ready", "zones": len(self.bins), "lamps": attrs["count"], "name": c["name"],
                     "vid": c["vid"], "pid": c["pid"], "iface": c["iface"], "kind": attrs["kind"],
                     "interval_us": attrs["interval_us"], "grouped": attrs["count"] > MAX_ZONES}
        self.emit_state(self.info)
        if self.desired:
            self.apply(self.desired, time.monotonic())
        return 0.0

    def drop_session(self, why):
        if self.session:
            self.session.close()
        self.session = self.engine = self.bins = None
        self.has_control = False
        self.emit_state({"state": "error", "message": why})
        self.next_connect = time.monotonic() + 2.0

    # ---- commands
    def take_control(self):
        self.session.set_autonomous(False)
        self.has_control, self.last_sent = True, {}

    def release_control(self):
        if self.session and self.has_control:
            self.session.set_autonomous(True)
        self.has_control = False

    def apply(self, cmd, now):
        if not self.session:
            return
        try:
            if cmd["mode"] == "auto":
                self.release_control()
                return
            snap = not self.has_control
            if snap:
                self.take_control()
            if cmd["mode"] == "off":
                goal = [(0, 0, 0)] * len(self.bins)
            else:
                k = cmd["br"] / 100.0
                goal = [(r * k, g * k, b * k) for r, g, b in resample(cmd["colors"], len(self.bins))]
            self.engine.retarget(goal, cmd["ms"], now, snap=snap)
            self.next_frame = now
            self.push_frame()
        except OSError as e:
            self.drop_session(e.strerror or str(e))

    def load_command(self):
        try:
            st = os.stat(self.cmd_path)
            text = _read(self.cmd_path)
        except OSError:
            return
        cmd = parse_command(text)
        if cmd is None or cmd["seq"] == self.last_seq:
            return
        self.last_seq, self.desired = cmd["seq"], cmd
        self.apply(cmd, time.monotonic())

    # ---- frames
    def push_frame(self):
        changed = []
        for b, col in enumerate(self.engine.frame()):
            for lamp in self.bins[b]:
                if self.last_sent.get(lamp) != col:
                    changed.append((lamp, col))
        if not changed:
            return
        t = time.monotonic()
        self.session.send(changed)
        for lamp, col in changed:
            self.last_sent[lamp] = col
        spent = time.monotonic() - t                    # adapt to slow links, never below the device minimum
        self.frame_dt = min(0.1, max(self.min_dt, spent * 1.5))

    def frame_step(self, now):
        try:
            self.engine.step(now)
            self.push_frame()
        except OSError as e:
            self.drop_session(e.strerror or str(e))
            return
        self.next_frame = now + self.frame_dt

    # ---- housekeeping
    def watchdog(self, now):
        self.watchdog_due = now + WATCHDOG_S
        if os.getppid() != self.ppid:                   # plugin gone
            self.stop_flag = True
            return
        try:
            owner = _read(self.pid_path).strip()
        except OSError:
            owner = str(os.getpid())
        if owner != str(os.getpid()):                   # a newer helper took over: leave quietly
            self.stop_flag, self.handback = True, False
            return
        wall, mono = time.time(), time.monotonic()
        jump = (wall - self.last_wall) - (mono - self.last_mono)
        self.last_wall, self.last_mono = wall, mono
        if jump > 2.0 and self.session and self.desired:   # resumed from suspend: firmware may have taken over
            self.has_control, self.last_sent = False, {}
            self.apply(self.desired, now)
        self.emit("BEAT")

    def cleanup(self):
        try:
            if self.handback and self.session and self.has_control:
                self.session.set_autonomous(True)
        except OSError:
            pass
        if self.session:
            self.session.close()
        try:
            if _read(self.pid_path).strip() == str(os.getpid()):
                os.remove(self.pid_path)
        except OSError:
            pass

    def run(self):
        os.makedirs(self.dir, exist_ok=True)
        with open(self.pid_path, "w") as f:
            f.write(str(os.getpid()))
        if threading.current_thread() is threading.main_thread():
            def bye(_sig, _frm):
                raise SystemExit(0)
            for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                signal.signal(s, bye)
        try:
            self.ino = Inotify(self.dir)
        except OSError:
            self.ino = None                             # fallback: light polling
        self.load_command()
        self.emit("BEAT")
        try:
            while not self.stop_flag:
                self.tick()
        except SystemExit:
            pass
        finally:
            self.cleanup()

    def tick(self):
        now = time.monotonic()
        if self.session is None and now >= self.next_connect:
            self.next_connect = now + self.connect()
            now = time.monotonic()
        if self.session and self.engine.active:
            timeout = max(0.0, self.next_frame - now)
        elif self.session is None:
            timeout = max(0.0, self.next_connect - now)
        else:
            timeout = self.watchdog_due - now
        timeout = max(0.0, min(timeout, self.watchdog_due - now))
        if self.ino:
            ready, _, _ = select.select([self.ino.fd], [], [], timeout)
            if ready:
                self.ino.names()
                self.load_command()
        else:
            time.sleep(min(timeout, 0.05))
            try:
                st = os.stat(self.cmd_path)
                sig = (st.st_mtime_ns, st.st_size)
            except OSError:
                sig = None
            if sig != self.cmd_sig:
                self.cmd_sig = sig
                self.load_command()
        now = time.monotonic()
        if self.session and self.engine.active and now >= self.next_frame:
            self.frame_step(now)
        if now >= self.watchdog_due:
            self.watchdog(now)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    Helper(argv[1]).run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
