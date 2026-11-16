"""Local actions for the CMF Buds.

The earbuds do not store arbitrary commands: the firmware only accepts a
fixed list of actions (play, next, volume, ANC...). What reaches the PC is
the *resulting action*, not the raw press.

That is why the macros are built on the PC:

* The daemon watches the earbuds' sink with ``pactl subscribe``. When the
  action picked on the earbud is "volume +/-" (for example the triple tap
  of the case button), the PC receives the AVRCP key and the sink volume
  changes on its own -> that change is the signal.
* The signals are grouped into multi-taps (double, triple...) with a time
  window.
* The modifier state (SUPER, CTRL, ALT, SHIFT) is read straight from
  /dev/input/event* so a rule can require "SUPER held".
* If a rule matches, the local command runs.
"""

from __future__ import annotations

import copy
import json
import os
import re
import select
import shlex
import signal
import struct
import subprocess
import threading
import time
import uuid

# Window used to group several presses into one (multi-tap).
GROUP_WINDOW = 0.7
# (No time window: our volume change is recognized by the value we set, not
# by when we set it. A time window swallowed the user's gestures that
# arrived right after the volume was restored.)
# Minimal safety net against duplicate events. An event's identity comes
# from its value (two events with the same volume are the same one), so this
# window only has to be shorter than the interval between two real taps
# (100-250 ms): at 200 ms a fast triple counted as a single gesture; at
# 60 ms very close taps were still lost.
EVENT_GAP = 0.03
# After firing a shortcut, events are ignored until the volume settles: when
# the volume is restored the earbuds send theirs back and generate an echo
# that would fire the shortcut again (workspace +1 and -1).
# Wait before restoring the volume: PipeWire applies the volume with a
# ~0.5 s ramp, and a change emitted during the ramp is lost (the ramp
# target wins). We have to wait for it to finish.
RESTORE_DELAY = 0.8
# Retries for the restore when the volume does not stay where it should.
RESTORE_ATTEMPTS = 2

MODIFIER_CODES = {
    125: "super",
    126: "super",
    29: "ctrl",
    97: "ctrl",
    56: "alt",
    100: "alt",
    42: "shift",
    54: "shift",
}

# Lifetime of the "change made by us" mark. It must only absorb the device
# echo: if it lived forever, the first user gesture landing within +-1 would
# be swallowed.
SELF_CHANGE_TTL = 2.0

# Triggers the engine can generate. The UI uses the same names: if they
# drifted apart, the UI rules would never fire.
#
# "knob_press" is a press of the case button. The earbuds do not send the
# raw press: they send the configured action (play/pause, next, previous).
# It is detected through MPRIS (dbus-monitor) and grouped with the same
# window as the dial, so it serves for "press the knob 1, 2 or 3 times".
TRIGGERS = ("volume_up", "volume_down", "knob_press")

# MPRIS members that count as a press of the case button.
MEDIA_PRESS_MEMBERS = ("PlayPause", "Play", "Pause", "Next", "Previous", "Stop")
MEDIA_PRESS_PATTERN = re.compile(r"member=(%s)\b" % "|".join(MEDIA_PRESS_MEMBERS))

MODIFIER_LABELS = {
    "super": "SUPER",
    "ctrl": "CTRL",
    "alt": "ALT",
    "shift": "SHIFT",
}

# Layout of struct input_event: timeval(16) + u16 + u16 + s32 on 64-bit.
# The size is computed from the format so it also fits the 32-bit layout
# (timeval(8)), where a hardcoded size would misparse every event.
INPUT_EVENT_FORMAT = "llHHi"


def _input_event_size(fmt=INPUT_EVENT_FORMAT):
    """Size of an input_event record for the given struct format."""
    return struct.calcsize(fmt)


INPUT_EVENT_SIZE = _input_event_size()

# 'pactl subscribe' line that announces a change on a sink.
SINK_EVENT_PATTERN = re.compile(r"Event 'change' on sink #(\d+)")

# How long a subscription must run without errors to be considered healthy.
# If it closes earlier, that is one more failure (otherwise it would restart
# in a loop).
HEALTHY_SECONDS = 5.0


def _run(cmd, timeout=6):
    try:
        return subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            text=True,
        )
    except Exception:
        return None


def _as_int(value, default=None):
    """Converts to int; None when the value is not a valid number."""
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _as_list(value):
    """Returns a list of modifiers even when the value comes in odd."""
    if isinstance(value, (list, tuple)):
        return [str(v) for v in value]
    if isinstance(value, str):
        return [value]
    return []


def _should_restore(current, previous, tolerance=1):
    """Whether the volume can be restored after a shortcut.

    'current' is the volume now and 'previous' the one right after the
    gesture. If they differ a lot, the user turned the dial again and their
    change is respected: the previous volume is not restored.
    """
    if current is None or previous is None:
        return True
    return abs(int(current) - int(previous)) <= tolerance


def _modifier_from_event(etype, code):
    """Modifier name of a keyboard event, or None.

    Kept separate so it can be checked: if a code changed, the rules that
    require SUPER would never fire and there would be no error.
    """
    if etype != 1:  # EV_KEY
        return None
    return MODIFIER_CODES.get(code)


def _list_event_devices():
    try:
        return [
            os.path.join("/dev/input", name)
            for name in os.listdir("/dev/input")
            if name.startswith("event")
        ]
    except Exception:
        return []


class ModifierTracker:
    """Keyboard modifier state read from /dev/input/event*."""

    def __init__(self, log=None):
        self.held = set()
        self.available = False
        self.log = log or (lambda msg: None)
        self._fds = {}       # fd -> path
        self._by_path = {}   # path -> fd
        self._stop = threading.Event()
        self._lock = threading.Lock()
        # The descriptors are read by the reader thread and closed by stop():
        # a dedicated lock keeps the two apart.
        self._fd_lock = threading.RLock()
        # The thread is created on every start(): the tracker runs only while
        # a rule needs the modifiers, so it is started and stopped as the
        # rules change and a thread that was already used cannot be reused.
        self._thread = None
        self._start_lock = threading.Lock()

    @property
    def running(self):
        """Whether the reader thread is alive."""
        return bool(self._thread is not None and self._thread.is_alive())

    def start(self):
        """Start reading the keyboard, or do nothing if it is already running."""
        with self._start_lock:
            if self.running:
                return
            self._stop = threading.Event()
            self._thread = threading.Thread(target=self._loop, daemon=True)
            self._thread.start()

    def stop(self):
        with self._start_lock:
            thread = self._thread
            if thread is None:
                return
            self._stop.set()
            # The reader thread is waited for before closing the descriptors:
            # it may be opening the devices right now, and the ones it opens
            # after this point would stay open forever. Waiting also avoids
            # closing a descriptor that another thread is about to reuse.
            if thread.is_alive():
                thread.join(timeout=2.0)
            self._thread = None
        self._close_devices()

    def _close_devices(self):
        with self._fd_lock:
            fds = list(self._fds.keys())
            self._fds.clear()
            self._by_path.clear()
            self.available = False
        for fd in fds:
            try:
                os.close(fd)
            except Exception:
                pass

    def modifiers(self):
        with self._lock:
            return sorted(self.held)

    def _open_devices(self):
        for path in sorted(_list_event_devices()):
            if self._stop.is_set():
                return
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            except Exception:
                continue
            with self._fd_lock:
                self._fds[fd] = path
                self._by_path[path] = fd
                self.available = bool(self._fds)

    def _refresh_devices(self):
        """Rescans /dev/input.

        A node can start pointing at another device (for example when a
        virtual keyboard restarts: the /dev/input/eventN node is recreated).
        Without this refresh the old fd stays attached to the deleted device
        and the modifiers are never detected again.
        """
        paths = _list_event_devices()
        current = set(paths)
        changed = False
        with self._fd_lock:
            for path in paths:
                if self._stop.is_set():
                    return
                fd = self._by_path.get(path)
                if fd is not None:
                    try:
                        if os.fstat(fd).st_ino == os.stat(path).st_ino:
                            continue
                    except OSError:
                        pass
                    # the node points at another device: reopen it
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    self._fds.pop(fd, None)
                    self._by_path.pop(path, None)
                    changed = True
                    self.log("Input device recreated, reopened: %s" % path)
                try:
                    nfd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                except OSError:
                    continue
                self._fds[nfd] = path
                self._by_path[path] = nfd
            for fd, path in list(self._fds.items()):
                if path not in current:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    self._fds.pop(fd, None)
                    self._by_path.pop(path, None)
                    changed = True
            self.available = bool(self._fds)
        if changed:
            # The device that was sending the key-up events is gone: the
            # modifiers it held would stay pressed forever (every rule would
            # ask for SUPER and none would ever fire).
            with self._lock:
                stuck = sorted(self.held)
                self.held.clear()
            if stuck:
                self.log(
                    "Input devices changed, releasing the held modifiers: %s"
                    % ",".join(stuck)
                )

    def _loop(self):
        try:
            self._open_devices()
        except Exception as exc:
            self.log("Could not open the input devices: %s" % exc)
        if not self._fds:
            # Without /dev/input (or without permission) the thread is NOT
            # abandoned: the loop stays alive and retries opening the devices
            # every few seconds. The thread used to die here and the modifiers
            # were never detected again, even if the keyboard showed up later.
            self.log("No input devices: retrying every 2 s")
        buf_size = INPUT_EVENT_SIZE
        last_refresh = 0.0
        while not self._stop.is_set():
            try:
                now = time.monotonic()
                if now - last_refresh > 2.0:
                    last_refresh = now
                    self._refresh_devices()
                if not self._fds:
                    self._stop.wait(0.5)
                    continue
                with self._fd_lock:
                    fds = list(self._fds.keys())
                if not fds:
                    self._stop.wait(0.5)
                    continue
                ready, _, _ = select.select(fds, [], [], 0.5)
                for fd in ready:
                    try:
                        data = os.read(fd, buf_size * 32)
                    except Exception:
                        continue
                    # Only complete events: any leftover is ignored.
                    usable = len(data) - (len(data) % buf_size)
                    for off in range(0, usable, buf_size):
                        try:
                            _, _, etype, code, value = struct.unpack(
                                INPUT_EVENT_FORMAT, data[off : off + buf_size]
                            )
                        except Exception:
                            continue
                        name = _modifier_from_event(etype, code)
                        if not name:
                            continue
                        with self._lock:
                            if value == 1:
                                self.held.add(name)
                            elif value == 0:
                                self.held.discard(name)
            except Exception as exc:
                # Never let the thread die: if it did, the modifiers would
                # stay frozen and the shortcuts would stop working.
                self.log("Modifier reader: %s" % exc)
                time.sleep(0.1)


class VolumeWatcher:
    """Detects volume changes of the earbuds' sink."""

    def __init__(self, sink_resolver, on_change, log=None):
        self.sink_resolver = sink_resolver
        self.on_change = on_change
        self.log = log or (lambda msg: None)
        self._proc = None
        self._stop = threading.Event()
        self._reported_no_sink = None
        self._failures = 0
        self._thread = threading.Thread(target=self._loop, daemon=True)

    def start(self):
        self._thread.start()

    def stop(self):
        self._stop.set()
        proc = self._proc
        if proc:
            try:
                proc.terminate()
            except Exception:
                pass
            # The child is reaped: without this it stays as a zombie until
            # the daemon exits.
            try:
                proc.wait(timeout=2)
            except Exception:
                try:
                    proc.kill()
                    proc.wait(timeout=2)
                except Exception:
                    pass

    def _retry_delay(self):
        """Wait before the next attempt.

        It is computed from the number of *previous* failures: the first
        failure waits 1 s, the second 2 s, the third 3 s... up to a cap of
        10 s.
        """
        return min(1.0 + self._failures, 10.0)

    def _fail(self, message):
        """Records a failure and returns how long to wait before retrying."""
        delay = self._retry_delay()
        self._failures += 1
        self.log(
            "%s (failure %d): retrying in %.0f s"
            % (message, self._failures, delay)
        )
        return delay

    def _sink_id(self, sink):
        res = _run(["pactl", "list", "sinks", "short"], 6)
        if not res:
            return None
        for line in (res.stdout or "").splitlines():
            parts = line.split("\t")
            if len(parts) >= 2 and parts[1] == sink:
                return parts[0].strip()
        return None

    def _handle_line(self, line, sink, sink_id):
        """Processes a 'pactl subscribe' line.

        Returns the id of the watched sink (it can change when the earbuds
        reconnect). An error while processing the event is logged and not
        propagated: if it propagated, the watcher thread would die and the
        shortcuts would stop working without a word.
        """
        match = SINK_EVENT_PATTERN.search(line or "")
        if not match:
            return sink_id
        if not sink_id:
            # Without an id there is no way to tell whether the event comes
            # from the watched sink: it is resolved, and if that fails too the
            # event is ignored (otherwise any system volume change would
            # count as a gesture).
            sink_id = self._sink_id(sink)
            if not sink_id:
                return None
        if match.group(1) != sink_id:
            # The sink is recreated when the earbuds reconnect and its id
            # changes: it is resolved again. The resolution is throttled:
            # every unrelated sink change (the laptop volume, another app)
            # would spawn a blocking 'pactl list' on the thread that reads
            # the subscription, and the events would pile up behind it.
            now = time.monotonic()
            if now - getattr(self, "_last_probe", 0.0) < 1.0:
                return sink_id
            self._last_probe = now
            refreshed = self._sink_id(sink)
            if not refreshed or refreshed != match.group(1):
                return sink_id
            self.log("Watcher: the sink changed id to %s" % refreshed)
            sink_id = refreshed
        try:
            self.on_change(sink)
        except Exception as exc:
            self.log("Watcher: error while processing a change: %s" % exc)
        return sink_id

    def _loop(self):
        while not self._stop.is_set():
            try:
                self._watch()
            except Exception as exc:
                # No exception may kill this thread: if it did, the shortcuts
                # would stop working without a word (that happened with the
                # sink resolver, which sat outside any try).
                delay = self._fail("Watcher: unexpected error: %s" % exc)
                self._stop.wait(delay)

    def _watch(self):
        """One turn of the watcher.

        Kept apart from the loop so any exception can be logged and retried
        instead of killing the thread silently.
        """
        sink = self.sink_resolver()
        if not sink:
            # With no earbuds connected there is nothing to watch: it is
            # reported once so the log does not fill up.
            if self._reported_no_sink != sink:
                self._reported_no_sink = sink
                self.log("Watcher: no headphone sink yet")
            self._stop.wait(2.0)
            return
        sink_id = self._sink_id(sink)
        if self._reported_no_sink is not None:
            self._reported_no_sink = None
        try:
            self._proc = subprocess.Popen(
                ["pactl", "subscribe"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
        except Exception as exc:
            # Without a subscription there are no shortcuts: it is reported
            # and retried with the growing delay (1 s, 2 s, 3 s... up to 10 s).
            delay = self._fail(
                "Watcher: could not open the subscription: %s" % exc
            )
            self._stop.wait(delay)
            return
        self.log("Watcher: watching %s (id %s)" % (sink, sink_id))
        started = time.monotonic()
        try:
            for line in self._proc.stdout:
                if self._stop.is_set():
                    break
                sink_id = self._handle_line(line, sink, sink_id)
        except Exception as exc:
            # An error here aborts the subscription. It used to be swallowed
            # in silence while the loop restarted over and over: with a
            # persistent failure the shortcuts never worked and not a single
            # line reached the log.
            delay = self._fail(
                "Watcher: error in the subscription: %s" % exc
            )
        else:
            if self._stop.is_set():
                delay = 0.0
            elif (time.monotonic() - started) < HEALTHY_SECONDS:
                # 'pactl subscribe' closed on its own: that is one more
                # failure, not a normal restart (otherwise it would repeat in
                # a loop).
                delay = self._fail(
                    "Watcher: the subscription closed before time"
                )
            else:
                # It is only accepted as healthy if it ran without errors:
                # here the failure counter is reset and the next retry is
                # like the first one again.
                if self._failures:
                    self.log("Watcher: the subscription works again")
                self._failures = 0
                delay = self._retry_delay()
        finally:
            try:
                if self._proc:
                    self._proc.kill()
            except Exception:
                pass
            self._proc = None
        if not self._stop.is_set():
            self._stop.wait(delay)


class MediaKeyWatcher:
    """Detects case button presses through MPRIS.

    The firmware does not send the raw press over RFCOMM: it runs the
    configured action and the PC sees it as an MPRIS call (PlayPause,
    Next...). ``dbus-monitor`` is part of dbus, which the desktop already
    needs, so it adds no dependencies.
    """

    def __init__(self, on_press, log=None):
        self.on_press = on_press
        self.log = log or (lambda msg: None)
        self._proc = None
        self._stop = threading.Event()
        self._failures = 0
        self._thread = threading.Thread(target=self._loop, daemon=True)

    def start(self):
        self._thread.start()

    def stop(self):
        self._stop.set()
        proc = self._proc
        if proc:
            try:
                proc.terminate()
            except Exception:
                pass
            # The child is reaped: without this it stays as a zombie until
            # the daemon exits.
            try:
                proc.wait(timeout=2)
            except Exception:
                try:
                    proc.kill()
                    proc.wait(timeout=2)
                except Exception:
                    pass

    @staticmethod
    def parse(line):
        """MPRIS member of a dbus-monitor line, or None."""
        match = MEDIA_PRESS_PATTERN.search(line or "")
        return match.group(1) if match else None

    def _loop(self):
        while not self._stop.is_set():
            try:
                self._proc = subprocess.Popen(
                    [
                        "dbus-monitor",
                        "--session",
                        "type='method_call',interface='org.mpris.MediaPlayer2.Player'",
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    bufsize=1,
                )
            except Exception as exc:
                # The same back-off as the other watchers: the delay is
                # computed from the previous failures.
                delay = min(10.0, 1.0 + self._failures)
                self._failures += 1
                self.log("Knob: could not open dbus-monitor: %s" % exc)
                self._stop.wait(delay)
                continue
            started = time.monotonic()
            try:
                for line in self._proc.stdout:
                    if self._stop.is_set():
                        break
                    member = self.parse(line)
                    if member is None:
                        continue
                    try:
                        self.on_press(member)
                    except Exception as exc:
                        self.log("Knob: error while processing %s: %s" % (member, exc))
            except Exception as exc:
                self.log("Knob: error in the subscription: %s" % exc)
            finally:
                try:
                    if self._proc:
                        self._proc.kill()
                        # Reap the child: otherwise it stays as a zombie.
                        self._proc.wait(timeout=2)
                except Exception:
                    pass
                self._proc = None
            if self._stop.is_set():
                return
            if time.monotonic() - started >= HEALTHY_SECONDS:
                self._failures = 0
                delay = min(10.0, 1.0 + self._failures)
            else:
                delay = min(10.0, 1.0 + self._failures)
                self._failures += 1
            self._stop.wait(delay)


class LocalActionEngine:
    """Shortcut rules: earbud signal + modifiers -> command."""

    def __init__(self, data_dir, log=None):
        self.data_dir = data_dir
        self.rules_path = os.path.join(data_dir, "local_actions.json")
        self.log = log or (lambda msg: None)
        self.rules = []
        self._doc = {}
        self.last_event = {}
        self.last_action = {}
        # Every trigger keeps its own open gesture: a volume_down press must
        # not close the volume_up gesture that was still open.
        self._pending = {}
        self._timers = {}
        self._lock = threading.RLock()
        self._self_set_volume = None
        self._self_set_at = 0.0
        # Time of the last event of each trigger (the repeat guard).
        self._last_trigger_at = {}
        # Triggers already reported (once per trigger, not once overall).
        self._no_rule_logged = {}
        self._shadow_logged = {}
        self.modifiers = ModifierTracker(self.log)
        self.media = MediaKeyWatcher(self._on_media_press, self.log)
        self.watcher = None
        self._sink_provider = None
        self._last_volume = None
        # True between start() and stop(): the modifier tracker must not be
        # revived by a rule saved after the engine was stopped.
        self._started = False
        # Daemon hook: this way the panel sees the volume changes made with
        # the dial or from the Nothing app live.
        self.on_volume = None
        # Hook so the daemon can persist state changes (last event, last
        # action) in state.json and the panel sees them live.
        self.on_event = None

    # -- persistence --------------------------------------------------------
    def load(self):
        try:
            with open(self.rules_path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            # The whole document is kept: saving replaces only the rules, so
            # anything else the file holds (a version marker, notes) survives.
            self._doc = dict(data) if isinstance(data, dict) else {}
            rules = data.get("rules", []) if isinstance(data, dict) else []
            if not isinstance(rules, list):
                # A hand-edited file can hold 'rules' as an object or as
                # text. If it were accepted, the engine would iterate over its
                # keys and adding a rule would blow up with an AttributeError
                # nobody would see (the panel would only show a generic error).
                self.log("Rules ignored: 'rules' is not a list")
                rules = []
            cleaned = [r for r in rules if isinstance(r, dict)]
            if len(cleaned) != len(rules):
                self.log(
                    "Rules discarded because they are not objects: %d"
                    % (len(rules) - len(cleaned))
                )
            self.rules = cleaned
            try:
                self._rules_mtime = os.path.getmtime(self.rules_path)
            except OSError:
                self._rules_mtime = 0.0
        except Exception as exc:
            self.log("Could not read the rules: %s" % exc)
            self.rules = []
            self._doc = {}
        return self.rules

    def reload_rules_if_changed(self):
        """Reloads the rules if the file changed.

        The engine must not decide on a stale view: if the rules are edited
        by hand (or from another session) outside the panel, the next gesture
        has to use the new rules already.
        """
        try:
            mtime = os.path.getmtime(self.rules_path)
        except OSError:
            return
        if mtime == getattr(self, "_rules_mtime", 0.0):
            return
        before = len(self.rules)
        self.load()
        self._sync_modifier_tracker()
        self.log("Rules reloaded (%d -> %d)" % (before, len(self.rules)))

    def save(self):
        os.makedirs(self.data_dir, exist_ok=True)
        tmp = self.rules_path + ".tmp"
        doc = dict(getattr(self, "_doc", {}) or {})
        doc["rules"] = self.rules
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False, indent=2)
        os.replace(tmp, self.rules_path)

    def upsert(self, rule):
        with self._lock:
            if not isinstance(rule, dict):
                raise ValueError("a rule must be an object")
            # The file is the source of truth: if someone added or changed
            # rules by hand after the last reload, they have to be read again
            # before saving, or they would be lost.
            self.reload_rules_if_changed()
            rid = str(rule.get("id") or "")
            if not rid:
                # The id has to be unique: a timestamp alone wraps around
                # every few hours and two rules created in the same
                # millisecond would overwrite each other.
                rid = "r" + uuid.uuid4().hex[:10]
                rule["id"] = rid
            found = False
            for idx, existing in enumerate(self.rules):
                if str(existing.get("id")) == rid:
                    self.rules[idx] = rule
                    found = True
                    break
            if not found:
                self.rules.append(rule)
            self.save()
            self._sync_modifier_tracker()
        return rule

    def delete(self, rid):
        with self._lock:
            self.reload_rules_if_changed()
            self.rules = [r for r in self.rules if str(r.get("id")) != str(rid)]
            self.save()
            self._sync_modifier_tracker()
        return self.rules

    # -- startup ------------------------------------------------------------
    def start(self, sink_provider):
        self._sink_provider = sink_provider
        self._started = True
        self.load()
        # Initial value: without it the first change has nothing to restore.
        try:
            sink = sink_provider()
            if sink:
                self._last_volume = self._read_volume(sink)
        except Exception as exc:
            # It is not critical (the initial value is only a reference), but
            # it is good to know when it fails: without it the first gesture
            # would have nothing to restore the volume against.
            self.log("Could not read the initial volume: %s" % exc)
        self._sync_modifier_tracker()
        self.media.start()
        self.watcher = VolumeWatcher(sink_provider, self._on_volume_change, self.log)
        self.watcher.start()
        self.log("Local action engine active")

    def stop(self):
        self._started = False
        for timer in list(self._timers.values()):
            try:
                timer.cancel()
            except Exception:
                pass
        self._timers.clear()
        if self.watcher:
            self.watcher.stop()
        self.media.stop()
        self._sync_modifier_tracker()

    # -- modifiers ----------------------------------------------------------
    def _wants_modifiers(self):
        """Whether an enabled rule needs the keyboard modifier state."""
        for rule in self.rules:
            if not isinstance(rule, dict):
                continue
            if rule.get("enabled") is False:
                continue
            if rule.get("require") or rule.get("forbid"):
                return True
        return False

    def _sync_modifier_tracker(self):
        """Reads the keyboard only while a rule needs the modifiers.

        The tracker opens every /dev/input/event* device: with no rule using
        'require'/'forbid' there is nothing to read, and the descriptors (and
        the permission they need) are not touched at all.
        """
        wanted = self._started and self._wants_modifiers()
        if wanted and not self.modifiers.running:
            self.modifiers.start()
        elif not wanted and self.modifiers.running:
            self.modifiers.stop()

    # -- volume -------------------------------------------------------------
    def note_self_change(self, value=None):
        """Marks a volume change made by us.

        With 'value' the volume we set is stored: later our change (same
        value) can be told apart from a user gesture, without relying on a
        time window that would swallow the gestures.

        The volume reference is updated too: otherwise the next real gesture
        would be computed against a stale baseline and the wrong shortcut
        (or none at all) would fire without a word.
        """
        if value is not None:
            try:
                level = int(value)
            except (TypeError, ValueError):
                return
            with self._lock:
                self._self_set_volume = level
                self._self_set_at = time.time()
                self._last_volume = level

    def _read_volume(self, sink):
        res = _run(["pactl", "get-sink-volume", sink], 6)
        if not res:
            return None
        for token in (res.stdout or "").split():
            if token.endswith("%"):
                try:
                    return int(float(token.rstrip("%")))
                except ValueError:
                    return None
        return None

    def _on_volume_change(self, sink):
        value = self._read_volume(sink)
        if value is None:
            # The sink no longer exists (earbuds disconnected): without a
            # volume reference no change can be computed.
            with self._lock:
                self._last_volume = None
            return
        # Always report (including our own changes): the panel needs to see
        # the real volume live, not only when there is a shortcut.
        if self.on_volume is not None:
            try:
                self.on_volume(value, sink)
            except Exception as exc:
                self.log("Could not publish the volume: %s" % exc)
        # The reference and our own mark are shared with the daemon thread
        # (which sets the volume): they are read and written together so a
        # gesture is never computed against a half-updated state.
        with self._lock:
            previous = self._last_volume
            self._last_volume = value
            self_set = self._self_set_volume
            self_set_at = self._self_set_at
        if previous is None:
            # Without a reference there is no way to know how much the volume
            # changed: the reference is reset and it is reported (it is not a
            # gesture).
            if not getattr(self, "_no_baseline_logged", False):
                self._no_baseline_logged = True
                self.log("No volume reference: resetting the reference")
            return
        self._no_baseline_logged = False
        delta = value - previous
        if delta == 0:
            return
        if (
            self_set is not None
            and (time.time() - self_set_at) <= SELF_CHANGE_TTL
            and abs(value - self_set) <= 1
        ):
            # It is the exact value we set: it is ignored (the event our own
            # write generates).
            return
        # It is a real change: our mark is no longer valid.
        with self._lock:
            self._self_set_volume = None
        self._register("volume_up" if delta > 0 else "volume_down", sink, previous)

    def _on_media_press(self, member):
        """A press of the case button (through MPRIS)."""
        if self._press_from_another_player():
            # Another player is sending the media key (a video, another music
            # app): the earbuds are not playing, so it is not their button.
            return
        self._register("knob_press", None, None)
        self.log("Knob: press detected (%s)" % member)

    def _press_from_another_player(self):
        """Whether the media key comes from a player other than the earbuds.

        The case press reaches the desktop as an MPRIS call, and every player
        sends the same calls: when the earbuds are not the active sink, a
        media key pressed on another app would fire the earbud shortcuts.

        When it cannot be told (the sink is unknown or pactl does not
        answer) the press is not discarded: there is no evidence that it
        comes from another player.
        """
        if not self._sink_provider:
            return False
        try:
            sink = self._sink_provider()
        except Exception:
            return False
        if not sink:
            return False
        res = _run(["pactl", "get-default-sink"], 6)
        if not res or res.returncode != 0:
            return False
        default = (res.stdout or "").strip()
        if not default:
            return False
        return default != sink

    def _publish(self):
        cb = getattr(self, "on_event", None)
        if cb is None:
            return
        try:
            cb()
        except Exception as exc:
            self.log("Could not publish the local state: %s" % exc)

    # -- press grouping ------------------------------------------------------
    def _register(self, trigger, sink=None, previous_volume=None):
        now = time.time()
        with self._lock:
            # A single key can generate several events: ignore repeats.
            if now - self._last_trigger_at.get(trigger, 0.0) < EVENT_GAP:
                return
            self._last_trigger_at[trigger] = now
            self.reload_rules_if_changed()
            modifiers = self.modifiers.modifiers()

            # Press count of the gesture in progress. A new gesture (more than
            # GROUP_WINDOW since the last press) starts from zero, the
            # "already fired" mark included. The gesture belongs to its own
            # trigger: another trigger (volume_down after volume_up) opens
            # its own gesture and does not cancel this one.
            pending = self._pending.get(trigger)
            if pending and now - pending["last"] <= GROUP_WINDOW:
                count = pending["count"] + 1
                first = pending["first"]
                already_fired = pending.get("fired", False)
                # Modifiers and reference volume from the START of the gesture:
                # they are kept for the gesture close. They are what defines
                # the gesture: if the user releases the modifier halfway
                # through, the rule that required it is still the gesture's
                # rule (and the other way round, pressing a modifier later
                # does not trigger a rule: the gesture was already done).
                gesture_modifiers = pending.get("modifiers") or []
                gesture_volume = pending.get("previous_volume")
            else:
                count = 1
                first = now
                already_fired = False
                gesture_modifiers = modifiers
                # Volume before the gesture: that is the one restored when the
                # rule asks to "restore volume" (not the later one, which
                # would undo nothing).
                gesture_volume = previous_volume
            pending = {
                "trigger": trigger,
                "count": count,
                "first": first,
                "last": now,
                "modifiers": gesture_modifiers,
                "previous_volume": gesture_volume,
                "fired": already_fired,
            }
            self._pending[trigger] = pending

            # Which rule applies to this gesture. Each event is evaluated
            # with the modifiers of that instant: that way, pressing the
            # modifier halfway through the gesture can trigger a rule. The
            # gesture keeps the ones from the start, which are the ones that
            # define it when it closes.
            rules = self._applicable_rules(trigger, modifiers)
            exact = [item for item in rules if item[0] == count]
            fallback = [item for item in rules if item[0] == 0]
            # An N-press rule that can still be met makes the "any" rule
            # wait: otherwise it would swallow the events and the N-press
            # rule would never fire.
            blocking = [item for item in rules if item[0] > count]

            chosen = None
            chosen_presses = 0
            if exact:
                chosen = exact[0][2]
                chosen_presses = exact[0][0]
            elif fallback and not blocking:
                chosen = fallback[0][2]
                chosen_presses = 0

            if chosen is not None:
                # One gesture = one action. If there is an N-press rule that
                # can still be met, the "any" rule waits for the gesture to
                # finish (otherwise it would swallow the presses and the
                # N-press rule would never fire). When no N-press rule is
                # pending, "any" fires at the start of the gesture. In both
                # cases the rest of the notches of the same gesture do not
                # repeat the action: the state of the gesture decides it, not
                # any time window.
                if pending.get("fired"):
                    return
                pending["fired"] = True
                self.last_event = {
                    "trigger": trigger,
                    "presses": count,
                    # The modifiers the rule was chosen with: those of this
                    # event.
                    "modifiers": modifiers,
                    "at": int(time.time() * 1000),
                }
                self._publish()
                self._run_rule(chosen, trigger, count, modifiers, gesture_volume)
                # The gesture is still open: the timer closes it (and cleans
                # the pending entry) when the window ends.
                self._arm_timer(trigger)
                return

            if not rules and not self._no_rule_logged.get(trigger):
                # There were rules for this gesture but none of them fits
                # (for example the modifier is not held): it is reported once
                # per trigger so the shortcuts do not look broken.
                self._no_rule_logged[trigger] = True
                self.log(
                    "The %s gesture matches no rule (modifiers: %s)"
                    % (trigger, ",".join(sorted(modifiers)) or "none")
                )
            elif rules:
                self._no_rule_logged.pop(trigger, None)

            if blocking and not self._shadow_logged.get(trigger):
                self._shadow_logged[trigger] = True
                self.log(
                    "The %s gesture has a %d-press rule: the 'any' rule "
                    "waits for the gesture to finish"
                    % (trigger, blocking[0][0])
                )
            elif not blocking:
                self._shadow_logged.pop(trigger, None)

            self._arm_timer(trigger)

    def _arm_timer(self, trigger):
        """(Re)arm the timer that closes the gesture of a trigger."""
        timer = self._timers.get(trigger)
        if timer is not None:
            try:
                timer.cancel()
            except Exception:
                pass
        timer = threading.Timer(GROUP_WINDOW, self._fire, args=(trigger,))
        timer.daemon = True
        self._timers[trigger] = timer
        timer.start()

    # -- rule evaluation ----------------------------------------------------
    def _applicable_rules(self, trigger, modifiers):
        """Rules that can apply to this gesture with these modifiers.

        Each element is (presses, specificity, rule):
          - presses == 0: the "any" rule, used as fallback.
          - presses  > 0: an N-press rule.

        They are sorted with the N-press rules first (and among them the most
        specific one) and the "any" rule last. Everything is evaluated against
        the rule set in force at each event, not against a saved view: that
        way a rule added or removed from the panel is respected from the next
        gesture.
        """
        out = []
        for rule in self.rules:
            if not isinstance(rule, dict):
                continue
            try:
                if not rule.get("enabled", True):
                    continue
                if rule.get("trigger") != trigger:
                    continue
                require = [m for m in _as_list(rule.get("require")) if m]
                forbid = [m for m in _as_list(rule.get("forbid")) if m]
                presses = _as_int(rule.get("presses"))
                if presses is None or presses < 0:
                    # Malformed rule (hand-edited): it is ignored entirely so
                    # it does not shadow the well-written rules.
                    self.log(
                        "Rule ignored because 'presses' is invalid: %s"
                        % rule.get("presses")
                    )
                    continue
                for key in ("require", "forbid"):
                    if key in rule and not isinstance(rule[key], (list, tuple, dict)):
                        self.log("Rule ignored because '%s' is invalid" % key)
                        presses = None
                        break
                if presses is None:
                    continue
            except Exception as exc:
                # A malformed rule (hand-edited) must not bring the engine
                # down: it is reported and the rest keeps going.
                self.log("Invalid rule ignored: %s" % exc)
                continue
            if any(m not in modifiers for m in require):
                continue
            if any(m in modifiers for m in forbid):
                continue
            out.append((presses, len(require), rule))
        out.sort(key=lambda item: (0 if item[0] > 0 else 1, -item[1], item[0]))
        return out

    def _pick_rule(self, rules, count):
        """The rule that applies to a gesture with 'count' presses.

        Exact N-press rules win; if there is none, the "any" rule is used as
        fallback.
        """
        exact = [item for item in rules if item[0] == count]
        if exact:
            return exact[0][2]
        fallback = [item for item in rules if item[0] == 0]
        if fallback:
            return fallback[0][2]
        return None

    def _fire(self, trigger=None):
        """Close of the gesture: the counter will not grow anymore.

        It runs on a timer: if something fails here, the gesture is lost, and
        without this cover nobody would find out.
        """
        try:
            self._fire_gesture(trigger)
        except Exception as exc:
            self.log("Could not close the gesture: %s" % exc)

    def _fire_gesture(self, trigger=None):
        with self._lock:
            if trigger is None:
                # No trigger given: every open gesture is closed.
                pendings = list(self._pending.values())
                self._pending.clear()
            else:
                pending = self._pending.pop(trigger, None)
                pendings = [pending] if pending else []
        for pending in pendings:
            self._close_gesture(pending)

    def _close_gesture(self, pending):
        if not pending:
            return
        if pending.get("fired"):
            # The gesture already fired its action: there is nothing left to
            # do.
            return
        # The modifiers the gesture was made with (the ones from the start):
        # if the user releases them before the window closes, the rule is
        # still the gesture's rule. And if they press them later, they do
        # not trigger a rule: the gesture was already done.
        modifiers = list(pending.get("modifiers") or [])
        rules = self._applicable_rules(pending["trigger"], modifiers)
        rule = self._pick_rule(rules, pending["count"])
        if rule is None:
            self.last_event = {
                "trigger": pending["trigger"],
                "presses": pending["count"],
                "modifiers": modifiers,
                "at": int(time.time() * 1000),
            }
            self._publish()
            return
        self._run_rule(
            rule,
            pending["trigger"],
            pending["count"],
            modifiers,
            # The volume from BEFORE the gesture: that is the one restored
            # when the rule asks for it (the later one would undo nothing).
            pending.get("previous_volume"),
        )

    def _run_rule(self, rule, trigger, count, modifiers, previous_volume):
        command = (rule.get("command") or "").strip()
        info = {
            "trigger": trigger,
            "presses": count,
            "modifiers": modifiers,
            "at": int(time.time() * 1000),
            "command": command,
            "rule_id": rule.get("id"),
            "ran": False,
        }
        if command:
            # The command runs in the background: the watcher cannot wait for
            # it. The real result arrives later and is stored with the action.
            self.run_command(
                command, on_result=lambda ok: self._action_finished(info, ok)
            )
            info["ran"] = True
        if rule.get("restore_volume") and previous_volume is not None:
            self._restore_volume_delayed(previous_volume)
        self.last_action = info
        self._publish()
        self.log(
            "Local action: %s | %s | mods=%s | vol=%s | -> %s"
            % (
                trigger,
                "x%d" % count,
                "+".join(modifiers) if modifiers else "-",
                self._last_volume,
                command or "(no command)",
            )
        )
        if rule.get("notify", True) and command:
            self._notify(info, command)

    def _action_finished(self, info, ok):
        """Stores the real result of a shortcut that ran in the background."""
        info["ok"] = bool(ok)
        self._publish()

    def _restore_volume_delayed(self, percent):
        """Restores the volume waiting for the PipeWire ramp to finish and
        checks that the value stayed; if not, it retries."""

        # The volume right after the gesture: if it is very different now,
        # the user turned the dial again and their change is respected
        # instead of being reverted.
        previous = self._last_volume

        def _apply(attempts):
            try:
                if not self._sink_provider:
                    return
                sink = self._sink_provider()
                if not sink:
                    return
                current = self._read_volume(sink)
                if not _should_restore(current, previous):
                    self.log(
                        "The user changed the volume (%s%%): not restoring"
                        % current
                    )
                    return
                self.note_self_change(int(percent))
                res = _run(
                    ["pactl", "set-sink-volume", sink, "%d%%" % int(percent)], 6
                )
                if res is None or res.returncode != 0:
                    self.log(
                        "Could not restore the volume to %d%% in %s (rc=%s)"
                        % (int(percent), sink, res.returncode if res else "error")
                    )
                time.sleep(0.3)
                current = self._read_volume(sink)
                self.log(
                    "Restore: %d%% -> %s%%" % (int(percent), current)
                )
                if current is None or current == int(percent):
                    return
                if attempts > 0:
                    self.log(
                        "The volume did not stay at %d%% (it is at %s%%): retrying"
                        % (int(percent), current)
                    )
                    time.sleep(RESTORE_DELAY)
                    _apply(attempts - 1)
            except Exception as exc:
                # This thread is a timer: if it dies in silence, the volume
                # stays where it should not and the user does not know why.
                self.log(
                    "Could not restore the volume to %d%%: %s"
                    % (int(percent), exc)
                )

        timer = threading.Timer(RESTORE_DELAY, _apply, args=(RESTORE_ATTEMPTS,))
        timer.daemon = True
        timer.start()

    def _restore_volume(self, percent):
        if not self._sink_provider:
            return
        sink = self._sink_provider()
        if not sink:
            return
        self.note_self_change(int(percent))
        res = _run(["pactl", "set-sink-volume", sink, "%d%%" % int(percent)], 6)
        self.log(
            "Restoring volume to %d%% in %s (rc=%s)"
            % (int(percent), sink, res.returncode if res else "error")
        )

    def _output_name(self):
        """Name of the focused monitor (for the {output} placeholder)."""
        res = _run(["hyprctl", "-j", "activeworkspace"], 5)
        if res:
            try:
                data = json.loads(res.stdout or "{}")
                if data.get("monitor"):
                    return str(data["monitor"])
            except Exception:
                pass
        res = _run(["hyprctl", "monitors", "-j"], 5)
        if res:
            try:
                for mon in json.loads(res.stdout or "[]"):
                    if mon.get("focused"):
                        return str(mon.get("name", ""))
            except Exception:
                pass
        return ""

    def run_command(self, command, wait=False, on_result=None, details=None):
        """Runs the command of a shortcut.

        By default it runs in a separate thread: the watcher must not stay
        blocked waiting for the command, and that way we can log whether it
        fails. With 'wait' the command runs in the calling thread and the
        real result is returned (the panel uses it to tell whether the test
        button worked). 'on_result' is called with the real result when the
        command finishes in the background.

        With 'details' the caller gets what happened (the exit status and
        the output of the command), so it can explain the failure instead of
        only saying that it failed.
        """

        def _exec():
            ok = False
            try:
                cmd = command
                shell_cmd = command
                if "{output}" in cmd:
                    # The name of the monitor is quoted: a name with spaces
                    # or shell characters would break the command.
                    shell_cmd = cmd.replace(
                        "{output}", shlex.quote(self._output_name())
                    )
                proc = subprocess.Popen(
                    ["/bin/sh", "-c", shell_cmd],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    # Its own process group: when the command times out, the
                    # children it started ("app &") are killed too.
                    start_new_session=True,
                )
                try:
                    out_raw, err_raw = proc.communicate(timeout=5)
                    rc = proc.returncode
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    except Exception:
                        pass
                    proc.communicate()
                    raise
                err = (err_raw or "").strip()
                out = (out_raw or "").strip()
                ok = rc == 0
                if details is not None:
                    details["returncode"] = rc
                    details["stdout"] = out
                    details["stderr"] = err
                self.log(
                    "Command: %s | rc=%s | out=%s | err=%s"
                    % (cmd, rc, out[:120], err[:200])
                )
            except Exception as exc:
                if details is not None:
                    details["error"] = str(exc)
                self.log("Could not run '%s': %s" % (command, exc))
            if on_result is not None:
                try:
                    on_result(ok)
                except Exception as exc:
                    self.log("Could not report the command result: %s" % exc)
            return ok

        if wait:
            return _exec()
        try:
            threading.Thread(target=_exec, daemon=True).start()
            return True
        except Exception as exc:
            self.log("Could not launch '%s': %s" % (command, exc))
            return False

    def _notify(self, info, command):
        mods = " + ".join(MODIFIER_LABELS.get(m, m.upper()) for m in info["modifiers"])
        body = "%s x%d" % (info["trigger"], info["presses"])
        if mods:
            body += " with " + mods
        body += " -> " + command
        try:
            subprocess.run(
                [
                    "notify-send",
                    "-a",
                    "Noctalia - CMF Buds",
                    "-i",
                    # The system theme name is "audio-headphones";
                    # "headphones" does not exist and the toast showed no icon.
                    "audio-headphones",
                    "Headphone shortcut",
                    body,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
                start_new_session=True,
            )
        except Exception as exc:
            # The shortcut has already run; only the notification fails.
            self.log("Could not show the shortcut notification: %s" % exc)

    # -- state ---------------------------------------------------------------
    def snapshot(self):
        # The panel has to see the file as it is: if the rules were edited by
        # hand (or from another session), the in-memory view can be stale.
        # Copies are returned: the daemon serializes them while the engine
        # keeps working, and a live reference would be read half-updated.
        with self._lock:
            self.reload_rules_if_changed()
            rules = copy.deepcopy(self.rules)
            last_event = copy.deepcopy(self.last_event)
            last_action = copy.deepcopy(self.last_action)
        return {
            "rules": rules,
            "last_event": last_event,
            "last_action": last_action,
            "modifiers": self.modifiers.modifiers(),
            "modifiers_available": self.modifiers.available,
        }
