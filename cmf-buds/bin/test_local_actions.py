#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Tests for the local shortcut engine (headphones are not required).

The dial signal (a sink volume change) is simulated and the correct rule is
verified:

  - the N-press rule takes precedence over the "any" rule
  - the "any" rule continues to work as a fallback
  - more specific rules take precedence (SUPER before no modifier)
  - a rule with an empty command does not break anything
  - a burst of changes counts as a single gesture
  - rules edited outside the panel are reloaded

Usage: python3 bin/test_local_actions.py
"""

from __future__ import annotations

import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from local_actions import LocalActionEngine, VolumeWatcher  # noqa: E402


class FakeEngine(LocalActionEngine):
    """Engine with simulated volume and recorded commands."""

    def __init__(self, rules):
        super().__init__("/tmp/cmf-buds-test")
        self.volume = 50
        self.fired = []
        self.rules = rules
        self._rules_mtime = 0.0
        self.modifiers.available = True
        self._last_volume = 50

    def _read_volume(self, sink):
        return self.volume

    def run_command(self, command, wait=False, on_result=None):
        if command:
            self.fired.append(command)
        if on_result is not None:
            on_result(True)
        return True

    def _restore_volume(self, percent):
        self.volume = int(percent)
        self.note_self_change(int(percent))


def rule(rid, trigger, presses, modifier, command):
    require = [] if modifier in (None, "none") else [modifier]
    return {
        "id": rid,
        "trigger": trigger,
        "presses": presses,
        "modifier": modifier or "none",
        "command": command,
        "enabled": True,
        "notify": False,
        "restore_volume": False,
        "require": require,
        "forbid": [],
    }


def esperar(cond, timeout=10.0, paso=0.02):
    """
    Wait until the condition is met.

    The tests do not sleep for a fixed period: they wait for the thing they
    need to check. This avoids depending on how fast the machine is, and a
    check cannot pass "by chance" before the situation it checks has occurred.
    """
    fin = time.monotonic() + timeout
    while time.monotonic() < fin:
        if cond():
            return True
        time.sleep(paso)
    return bool(cond())


class Runner:
    def __init__(self, rules):
        self.engine = FakeEngine(rules)
        self.failures = 0

    def evento(self, volume, modifiers, gap=0.16):
        """
        A click of the dial.

        'gap' is the time until the next click: two real clicks are 100-250 ms
        apart; a burst of notches comes in quick succession.
        """
        self.engine.modifiers.held = set(modifiers)
        self.engine.volume = volume
        self.engine._on_volume_change("fake")
        time.sleep(gap)

    def varios(self, volumes, modifiers, gap=0.16):
        for v in volumes:
            self.evento(v, modifiers, gap)

    def check(self, name, condition, detail=""):
        if condition:
            print("  OK   %s" % name)
        else:
            print('  FAIL %s %s' % (name, detail))
            self.failures += 1

    def calmarse(self):
        # Allow the cooldown window to expire (after the restore echo)
        time.sleep(1.6)
        self.engine.fired.clear()


def _pactl_falso(llamadas, motor):
    """
    Simulated 'pactl': records the calls and applies the volume to the engine.

    If the volume is not applied, the restore keeps retrying on a timer that
    outlives the test and leaks into the next one (with another simulated
    'pactl' or the real one).
    """

    def fake_run(cmd, timeout=6):
        llamadas.append(list(cmd))
        if "set-sink-volume" in cmd:
            try:
                motor.volume = int(str(cmd[-1]).rstrip("%"))
            except ValueError:
                pass

        class Res:
            stdout = ""
            returncode = 0

        return Res()

    return fake_run


def _esperar_restore(motor, destino, timeout=8.0):
    """Wait for the restore to finish (and not leak into the next test)."""
    esperar(lambda: motor.volume == destino, timeout=timeout)
    # The restore performs one more check after applying the volume.
    time.sleep(0.6)


def test_regla_cualquiera_sola():
    print("1) only an 'any' rule exists (it fires immediately)")
    r = Runner([rule("a", "volume_up", 0, "super", "SUPER")])
    r.evento(60, ["super"])
    # Without an N-press rule, "any" fires as soon as the gesture starts.
    time.sleep(0.2)
    r.check('runs with SUPER', r.engine.fired == ["SUPER"], r.engine.fired)
    r.calmarse()
    r.evento(70, [])
    time.sleep(0.2)
    r.check('does not run without the modifier', r.engine.fired == [], r.engine.fired)
    return r.failures


def test_contador_manda():
    print("2) 'any' + 3 presses: the 3-press rule wins, and the other serves as the fallback")
    r = Runner(
        [
            rule("any", "volume_up", 0, "super", "CUALQUIERA"),
            rule("tres", "volume_up", 3, "super", "TRES"),
        ]
    )
    # A single click: the 3-press rule is not reached, so "any" acts as the fallback.
    r.evento(60, ["super"])
    # With an N-press rule pending, the fallback waits for the gesture to
    # end (otherwise it would consume the presses).
    time.sleep(0.2)
    r.check(
        'the fallback waits for the gesture to finish',
        r.engine.fired == [],
        r.engine.fired,
    )
    time.sleep(1.0)
    r.check("a single click triggers the 'any' fallback", r.engine.fired == ["CUALQUIERA"], r.engine.fired)
    r.calmarse()
    # Three clicks: the 3-press rule wins.
    r.evento(65, ["super"], 0.15)
    r.evento(70, ["super"], 0.15)
    r.evento(75, ["super"], 0.05)
    time.sleep(0.3)
    r.check('three clicks trigger the 3-press rule', r.engine.fired == ["TRES"], r.engine.fired)
    time.sleep(1.5)
    r.check("the 'any' rule does not repeat", r.engine.fired == ["TRES"], r.engine.fired)
    return r.failures


def test_modificadores_distintos():
    print('3) rules with different modifiers do not overlap')
    r = Runner(
        [
            rule("sin", "volume_up", 0, None, "SIN"),
            rule("con", "volume_up", 3, "super", "CON_SUPER"),
        ]
    )
    r.evento(60, [])
    time.sleep(0.2)
    r.check('no modifier triggers its own rule', r.engine.fired == ["SIN"], r.engine.fired)
    r.calmarse()
    r.evento(65, ["super"], 0.15)
    r.evento(70, ["super"], 0.15)
    r.evento(75, ["super"], 0.05)
    time.sleep(0.3)
    r.check('with SUPER, it waits for 3 presses', r.engine.fired == ["CON_SUPER"], r.engine.fired)
    return r.failures


def test_especificidad():
    print("4) with two 'any' rules, the more specific one wins")
    r = Runner(
        [
            rule("sin", "volume_up", 0, None, "SIN"),
            rule("con", "volume_up", 0, "super", "CON_SUPER"),
        ]
    )
    r.evento(60, ["super"])
    time.sleep(0.2)
    r.check('with SUPER, the SUPER rule wins', r.engine.fired == ["CON_SUPER"], r.engine.fired)
    r.calmarse()
    r.evento(75, [])
    time.sleep(0.2)
    r.check('without a modifier, the rule without a modifier wins', r.engine.fired == ["SIN"], r.engine.fired)
    return r.failures


def test_comando_vacio():
    print('5) rule with an empty command')
    r = Runner([rule("vacia", "volume_down", 0, "super", "")])
    r.evento(40, ["super"])
    time.sleep(0.2)
    r.check('runs nothing', r.engine.fired == [], r.engine.fired)
    r.check('but records the event', r.engine.last_event is not None)
    return r.failures


def test_rafaga():
    print('6) burst of changes = a single gesture')
    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    r.varios([60, 65, 70, 75, 80], ["super"], 0.02)
    time.sleep(0.3)
    r.check('a single execution', r.engine.fired == ["UNO"], r.engine.fired)
    return r.failures


def test_gesto_despues_de_restaurar():
    print('8) a gesture after restoring the volume is not lost')
    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    r.evento(60, ["super"])
    time.sleep(0.2)
    r.check('the first action runs', r.engine.fired == ["UNO"], r.engine.fired)
    # The restore marks the volume: a new gesture must still be detected.
    r.engine._restore_volume(40)
    r.calmarse()
    r.engine.fired.clear()
    r.evento(45, ["super"])
    time.sleep(0.2)
    r.check('the next gesture does too', r.engine.fired == ["UNO"], r.engine.fired)
    return r.failures


def test_pinchazos_muy_juntos():
    print('9) very closely spaced clicks (50 ms) are counted separately')
    r = Runner(
        [
            rule("any", "volume_up", 0, "super", "CUALQUIERA"),
            rule("dos", "volume_up", 2, "super", "DOS"),
        ]
    )
    r.evento(60, ["super"], 0.05)
    r.evento(65, ["super"], 0.05)
    time.sleep(0.3)
    r.check('two quick clicks trigger the 2-press rule', r.engine.fired == ["DOS"], r.engine.fired)
    return r.failures


def test_cambio_propio_por_valor():
    print('10) our volume change is recognized by value, not by time')
    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    r.engine.modifiers.held = {"super"}
    # The engine sets the volume to 40 (as the restore does).
    r.engine._restore_volume(40)
    # Much later, the same value: it is ours, so it is ignored.
    time.sleep(0.5)
    r.engine.volume = 40
    r.engine._on_volume_change("fake")
    time.sleep(0.2)
    r.check('the same value does not count as a gesture', r.engine.fired == [], r.engine.fired)
    # A different value does count (separated like two real clicks).
    time.sleep(0.2)
    r.engine.volume = 55
    r.engine._on_volume_change("fake")
    time.sleep(0.2)
    r.check('a different value does count', r.engine.fired == ["UNO"], r.engine.fired)
    return r.failures


def test_gestos_separados():
    print('11) separate gestures (outside the window) = one action each')
    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    r.evento(60, ["super"], 0.9)   # Gesture 1
    r.evento(65, ["super"], 0.9)   # Gesture 2 (outside gesture 1's window)
    time.sleep(0.3)
    r.check('two actions', r.engine.fired == ["UNO", "UNO"], r.engine.fired)
    return r.failures


def test_regla_malformada():
    print('12) a malformed rule is ignored and does not hide the others')
    r = Runner([rule("ok", "volume_up", 0, "super", "BIEN")])
    r.engine.rules.append({"id": "rota", "trigger": "volume_up", "presses": "abc", "require": 5})
    r.evento(60, ["super"])
    time.sleep(0.3)
    r.check('the valid rule runs', r.engine.fired == ["BIEN"], r.engine.fired)
    r.calmarse()
    r.engine.fired.clear()
    r.evento(70, ["super"])
    time.sleep(0.3)
    r.check('and keeps working', r.engine.fired == ["BIEN"], r.engine.fired)
    return r.failures


def test_watcher_sobrevive():
    print('13) the watcher survives a transient error and logs it')
    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    calls = {"n": 0}
    logs = []

    def on_change(sink):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("fallo simulado")

    watcher = VolumeWatcher(lambda: "sink-falso", on_change, logs.append)
    # Inject the event manually: without headphones there is no 'pactl subscribe'
    # to report anything, and the error path must be exercised for real.
    try:
        watcher._handle_line("Event 'change' on sink #42", "sink-falso", "42")
        ok = True
    except Exception as exc:
        ok = False
        logs.append("excepcion: %s" % exc)
    r.check('the error does not propagate', ok, logs)
    r.check(
        'the error is logged',
        any("fallo simulado" in m for m in logs),
        logs,
    )
    r.check('the event was attempted', calls["n"] == 1, calls)
    return r.failures


def test_watcher_sin_suscripcion():
    print('14) if subscription is unavailable, it reports the error and keeps retrying')
    import local_actions

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    logs = []
    original = local_actions.subprocess.Popen

    def boom(cmd, *args, **kwargs):
        # Only intercept the subscription: 'subprocess.run' (pactl list)
        # also uses Popen internally and must keep working.
        if cmd[:2] == ["pactl", "subscribe"]:
            raise OSError("pactl no disponible")
        return original(cmd, *args, **kwargs)

    local_actions.subprocess.Popen = boom
    try:
        watcher = VolumeWatcher(lambda: "sink-falso", lambda sink: None, logs.append)
        watcher.start()
        esperar(lambda: any("subscription" in m for m in logs))
        alive = watcher._thread.is_alive()
        watcher.stop()
    finally:
        local_actions.subprocess.Popen = original
    r.check('the thread remains alive', alive)
    r.check(
        'reports the failure in the log',
        any("subscription" in m for m in logs),
        logs,
    )
    return r.failures


class FakeStop:
    """Stand-in for the stop event: records waits without sleeping."""

    def __init__(self, stop_after=None):
        self.waits = []
        self._stopped = False
        self._stop_after = stop_after

    def is_set(self):
        return self._stopped

    def wait(self, timeout=None):
        self.waits.append(timeout)
        if self._stop_after is not None and len(self.waits) >= self._stop_after:
            self._stopped = True
        return self._stopped

    def set(self):
        self._stopped = True


class FakeProc:
    """Simulated 'pactl subscribe' process."""

    def __init__(self, lines=(), delay=0.0):
        self.stdout = self._lines(lines, delay)
        self.killed = False

    def _lines(self, lines, delay):
        for line in lines:
            yield line
        if delay:
            time.sleep(delay)

    def kill(self):
        self.killed = True

    def terminate(self):
        self.killed = True


def test_espera_creciente():
    print('15) the wait increases between retries')
    import local_actions

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    logs = []
    original = local_actions.subprocess.Popen

    def boom(cmd, *args, **kwargs):
        if cmd[:2] == ["pactl", "subscribe"]:
            raise OSError("pactl no disponible")
        return original(cmd, *args, **kwargs)

    local_actions.subprocess.Popen = boom
    try:
        watcher = VolumeWatcher(lambda: "sink-falso", lambda sink: None, logs.append)
        watcher._stop = FakeStop(stop_after=4)
        watcher.start()
        esperar(lambda: len(watcher._stop.waits) >= 4)
        waits = list(watcher._stop.waits)
        watcher.stop()
    finally:
        local_actions.subprocess.Popen = original
    r.check('the waits grow: 1, 2, 3, 4', waits == [1.0, 2.0, 3.0, 4.0], waits)
    r.check(
        'the log tracks the failure count and when it retries',
        any("(failure 4): retrying in 4 s" in m for m in logs),
        logs,
    )
    r.check(
        'the failure number and wait correspond, in order',
        [m for m in logs if "(failure" in m]
        == [
            "Watcher: could not open the subscription: pactl no disponible "
            "(failure %d): retrying in %d s" % (n, n)
            for n in range(1, 5)
        ],
        [m for m in logs if "(failure" in m],
    )
    return r.failures


def test_contador_se_reinicia():
    print('16) the failure counter resets when the subscription works')
    import local_actions

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    logs = []
    llamadas = {"n": 0}
    original = local_actions.subprocess.Popen
    original_healthy = local_actions.HEALTHY_SECONDS
    local_actions.HEALTHY_SECONDS = 0.05

    def fake_popen(cmd, *args, **kwargs):
        if cmd[:2] != ["pactl", "subscribe"]:
            return original(cmd, *args, **kwargs)
        llamadas["n"] += 1
        if llamadas["n"] == 2:
            # The second attempt is a healthy subscription: it resets the
            # counter. Without this reset, the next failure would be number 2.
            return FakeProc(["Event 'change' on sink #42\n"], delay=0.15)
        raise OSError("pactl no disponible")

    local_actions.subprocess.Popen = fake_popen
    try:
        watcher = VolumeWatcher(lambda: "sink-falso", lambda sink: None, logs.append)
        watcher._stop = FakeStop(stop_after=4)
        watcher.start()
        esperar(lambda: len(watcher._stop.waits) >= 4)
        waits = list(watcher._stop.waits)
        watcher.stop()
    finally:
        local_actions.subprocess.Popen = original
        local_actions.HEALTHY_SECONDS = original_healthy
    r.check('the first failure waits 1 s', waits[:1] == [1.0], waits)
    r.check(
        'reports that the subscription works again',
        any("works again" in m for m in logs),
        logs,
    )
    r.check(
        'the next failure is number 1 again (counter reset)',
        len([m for m in logs if "(failure 1)" in m]) == 2,
        logs,
    )
    sanas = [i for i, m in enumerate(logs) if "works again" in m]
    fallos1 = [i for i, m in enumerate(logs) if "(failure 1)" in m]
    r.check(
        'and the healthy subscription is between the two failures',
        len(sanas) == 1 and len(fallos1) == 2 and fallos1[0] < sanas[0] < fallos1[1],
        logs,
    )
    r.check(
        'and the next one waits longer (2 s)',
        waits[-1:] == [2.0],
        waits,
    )
    return r.failures


def test_suscripcion_corta():
    print('17) a subscription that closes prematurely counts as a failure')
    import local_actions

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    logs = []
    original = local_actions.subprocess.Popen
    original_healthy = local_actions.HEALTHY_SECONDS
    local_actions.HEALTHY_SECONDS = 5.0

    def fake_popen(cmd, *args, **kwargs):
        if cmd[:2] != ["pactl", "subscribe"]:
            return original(cmd, *args, **kwargs)
        # A subscription that closes immediately.
        return FakeProc([], delay=0.0)

    local_actions.subprocess.Popen = fake_popen
    try:
        watcher = VolumeWatcher(lambda: "sink-falso", lambda sink: None, logs.append)
        watcher._stop = FakeStop(stop_after=3)
        watcher.start()
        esperar(lambda: len(watcher._stop.waits) >= 3)
        waits = list(watcher._stop.waits)
        watcher.stop()
    finally:
        local_actions.subprocess.Popen = original
        local_actions.HEALTHY_SECONDS = original_healthy
    r.check(
        'reports that it closed prematurely',
        any("closed before time" in m for m in logs),
        logs,
    )
    r.check('the waits grow', waits == [1.0, 2.0, 3.0], waits)
    r.check(
        'the log tracks the failure count',
        any("(failure 3): retrying in 3 s" in m for m in logs),
        logs,
    )
    return r.failures


def test_watcher_resolutor_falla():
    print('18) the watcher survives a failing resolver')
    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    logs = []

    def resolver_falla():
        raise RuntimeError("fallo al resolver el sink")

    watcher = VolumeWatcher(resolver_falla, lambda sink: None, logs.append)
    watcher._stop = FakeStop(stop_after=3)
    watcher.start()
    esperar(lambda: len(watcher._stop.waits) >= 3)
    waits = list(watcher._stop.waits)
    watcher.stop()
    # The thread must exit: wait for it to happen, because checking at
    # the exact moment is a race and fails intermittently.
    esperar(lambda: not watcher._thread.is_alive(), timeout=5.0)
    alive = watcher._thread.is_alive()
    r.check(
        'the error is logged',
        any("unexpected error" in m for m in logs),
        logs,
    )
    # What proves that the thread did not die with the exception: it keeps
    # retrying (and therefore the waits grow). If it had died, there would be only one.
    r.check('the waits grow (it keeps retrying)', waits == [1.0, 2.0, 3.0], waits)
    r.check('and the thread exits when stopped', not alive)
    return r.failures


def test_restore_falla_visible():
    print('19) if the restore fails, it is logged (it does not fail silently)')
    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    logs = []
    r.engine.log = logs.append

    def proveedor_falla():
        raise RuntimeError("sin sink")

    r.engine._sink_provider = proveedor_falla
    r.engine._restore_volume_delayed(40)
    esperar(lambda: any("Could not restore" in m for m in logs), timeout=5.0)
    r.check(
        'it is recorded in the log',
        any("Could not restore the volume to 40%" in m for m in logs),
        logs,
    )
    return r.failures


def test_no_se_pisan_las_reglas_del_fichero():
    print("20) saving does not overwrite the file's rules")
    import json

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    path = "/tmp/cmf-buds-test-fichero.json"
    r.engine.rules_path = path
    r.engine._rules_mtime = 0.0
    # Someone adds a rule to the file manually, outside the panel.
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(
            '{"rules": [%s, %s]}'
            % (
                _json_rule("a", "volume_up", 0, "super", "UNO"),
                _json_rule("manual", "volume_down", 0, "super", "MANUAL"),
            )
        )
    # The panel adds another rule: the file's rule must not be lost.
    r.engine.upsert(rule("nueva", "volume_up", 0, "super", "NUEVA"))
    with open(path, "r", encoding="utf-8") as fh:
        ids = [x["id"] for x in json.load(fh)["rules"]]
    r.check("the file's rule is still there", "manual" in ids, ids)
    r.check('and the new rule was added', "nueva" in ids, ids)
    r.check(
        'the panel sees the file rules',
        "manual" in [x["id"] for x in r.engine.snapshot()["rules"]],
    )
    if os.path.exists(path):
        os.unlink(path)
    return r.failures


def test_gesto_no_se_pierde():
    print('21) if closing the gesture fails, it is logged')
    # With a 3-press rule, a single click does NOT fire anything: the
    # action is decided when the gesture closes (by the timer that triggers it).
    r = Runner([
        rule("any", "volume_up", 0, "super", "CUALQUIERA"),
        rule("tres", "volume_up", 3, "super", "TRES"),
    ])
    logs = []
    r.engine.log = logs.append

    def falla():
        raise RuntimeError("fallo simulado")

    # Deliberately break gesture closure: if it is not protected, the
    # timer thread dies and the gesture is lost without anyone noticing.
    r.engine._fire_gesture = falla
    r.evento(60, ["super"])
    esperar(lambda: any("Could not close the gesture" in m for m in logs), timeout=5.0)
    r.check(
        'it is recorded in the log',
        any("Could not close the gesture" in m for m in logs),
        logs,
    )
    r.check('the gesture did not run', r.engine.fired == [], r.engine.fired)
    # And the engine keeps working: restore closure and another gesture works.
    r.engine._fire_gesture = LocalActionEngine._fire_gesture.__get__(r.engine)
    r.engine.fired.clear()
    r.evento(70, ["super"])
    esperar(lambda: r.engine.fired == [], timeout=0.5)
    time.sleep(1.2)
    r.check('the engine remains alive', r.engine.fired == ["CUALQUIERA"], r.engine.fired)
    return r.failures


def test_lector_cierra_el_socket():
    print('22) the reader closes the socket when it dies (the descriptor does not leak)')
    import socket as _socket

    import budsctl

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    a, b = _socket.socketpair()
    link = budsctl.BudsLink("00:00:00:00:00:00")
    link.sock = a
    link.running = True
    logs = []
    link.log = logs.append
    original = budsctl.parse_frames

    def falla(buf):
        raise RuntimeError("fallo simulado")

    budsctl.parse_frames = falla
    b.sendall(b"\x99\x99\x99\x99")
    try:
        link._read_loop()
    finally:
        budsctl.parse_frames = original
    r.check('the socket is closed', a.fileno() == -1, a.fileno())
    r.check('the link is disconnected', not link.connected)
    r.check(
        'it is recorded in the log',
        any("Unexpected error in the reader" in m for m in logs),
        logs,
    )
    b.close()
    return r.failures


def test_reconectar_cierra_el_enlace_anterior():
    print('23) reconnecting closes the previous link (its socket does not remain open)')
    import socket as _socket

    import budsctl

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    a, b = _socket.socketpair()
    anterior = budsctl.BudsLink("00:00:00:00:00:00")
    anterior.sock = a
    anterior.connected = True
    budsctl.BudsDaemon._close_previous_link(anterior)
    r.check("the previous link's socket is closed", a.fileno() == -1, a.fileno())
    r.check('the previous link is disconnected', not anterior.connected)
    r.check('it does not connect with a null link', budsctl.BudsDaemon._close_previous_link(None) is None)
    b.close()
    return r.failures


def test_tramas_rfcmm():
    print('24) frames are built and parsed, and garbage does not crash the parser')
    import random

    import budsctl

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    payload = b"\x01\x02\x03"
    frame = budsctl.build_frame(0xC001, payload, 7)
    frames, resto = budsctl.parse_frames(frame)
    r.check('the frame is parsed', len(frames) == 1, frames)
    r.check('the payload is correct', bool(frames) and frames[0][1] == payload, frames)
    r.check('no remainder is left', resto == b"", resto)
    r.check(
        'the frame CRC is the calculated one',
        frame[-2:] == budsctl.struct.pack("<H", budsctl.crc16(frame[:-2])),
    )
    basura = bytes(random.randrange(256) for _ in range(64))
    try:
        frames2, resto2 = budsctl.parse_frames(basura)
        ok = isinstance(frames2, list) and isinstance(resto2, bytes)
    except Exception as exc:
        ok = False
        frames2 = exc
    r.check('garbage does not crash it', ok, frames2)
    medio = frame[:5]
    frames3, resto3 = budsctl.parse_frames(medio)
    r.check(
        'an incomplete frame waits for more data',
        frames3 == [] and resto3 == medio,
        (frames3, resto3),
    )
    r.check(
        'the buffer is bounded (it does not grow indefinitely)',
        budsctl._clamp_buffer(b"x" * (budsctl.MAX_BUFFER + 1)) == b"",
    )
    r.check(
        'a normal buffer is preserved',
        budsctl._clamp_buffer(b"x" * 10) == b"x" * 10,
    )
    return r.failures


def test_ecodec_y_modelo():
    print("25) the equalizer's float codec and model detection")
    import budsctl

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    for valor in (0.0, 1.0, -1.0, 0.5, 12.0, -7.25):
        codificado = budsctl.eq_float_encode(valor)
        recuperado = budsctl.eq_float_decode(codificado)
        r.check(
            "the float %s makes a round trip" % valor,
            abs(recuperado - valor) < 1e-6,
            (valor, recuperado),
        )
    r.check(
        'the preamp has its own encoding',
        budsctl.eq_float_encode(0.0, preamp=True) == bytes([0x00, 0x00, 0x00, 0x80]),
    )
    r.check(
        'decoding garbage does not crash',
        budsctl.eq_float_decode(b"") == 0.0 and budsctl.eq_float_decode(b"x") == 0.0,
    )
    r.check(
        'the model is detected by name',
        budsctl.model_from_name("CMF Buds Pro 2") == "B172"
        and budsctl.model_from_name("cmf buds 2 plus") == "B171"
        and budsctl.model_from_name("CMF Buds 2") == "B168"
        and budsctl.model_from_name("CMF Buds") == "B168",
    )
    r.check(
        'an unknown name yields no model',
        budsctl.model_from_name("otra cosa") is None
        and budsctl.model_from_name(None) is None
        and budsctl.model_from_name("") is None,
    )
    r.check(
        'the model is detected by serial number',
        budsctl.model_from_serial("1234769999") == "B172"
        and budsctl.model_from_serial("1234") is None
        and budsctl.model_from_serial(None) is None,
    )
    return r.failures


def test_codigos_de_modificadores():
    print('26) key codes map to the correct modifier')
    import local_actions

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    esperados = {
        125: "super",   # KEY_LEFTMETA
        126: "super",   # KEY_RIGHTMETA
        29: "ctrl",     # KEY_LEFTCTRL
        97: "ctrl",     # KEY_RIGHTCTRL
        56: "alt",      # KEY_LEFTALT
        100: "alt",     # KEY_RIGHTALT
        42: "shift",    # KEY_LEFTSHIFT
        54: "shift",    # KEY_RIGHTSHIFT
    }
    for codigo, nombre in esperados.items():
        r.check(
            "key code %d is %s" % (codigo, nombre),
            local_actions._modifier_from_event(1, codigo) == nombre,
            local_actions._modifier_from_event(1, codigo),
        )
    r.check(
        'a normal key is not a modifier',
        local_actions._modifier_from_event(1, 30) is None,
    )
    r.check(
        'a non-keyboard event is not a modifier',
        local_actions._modifier_from_event(0, 125) is None
        and local_actions._modifier_from_event(2, 125) is None,
    )
    # The names used by the engine are the same as those in the rules:
    # otherwise, rules requiring SUPER would never fire.
    r.check(
        'the engine names match the rule names',
        set(local_actions.MODIFIER_CODES.values()) == {"super", "ctrl", "alt", "shift"},
    )
    return r.failures


def test_aviso_del_atajo():
    print('27) the shortcut notification is sent and, if it fails, it is logged')
    import local_actions

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    r.engine.rules[0]["notify"] = True
    logs = []
    r.engine.log = logs.append
    llamadas = []
    original = local_actions.subprocess.Popen

    def fake_popen(cmd, *args, **kwargs):
        llamadas.append(cmd)
        return None

    local_actions.subprocess.Popen = fake_popen
    try:
        r.evento(60, ["super"])
        time.sleep(0.3)
    finally:
        local_actions.subprocess.Popen = original
    r.check(
        'a notification is sent with notify-send',
        any(isinstance(c, list) and c and c[0] == "notify-send" for c in llamadas),
        llamadas,
    )
    r.check('the shortcut ran', r.engine.fired == ["UNO"], r.engine.fired)

    # And if the notification fails, it is not silently lost. First let the
    # gesture window pass, otherwise the second click is part of the
    # first and will not fire again.
    r.calmarse()
    logs.clear()
    r.engine.log = logs.append

    def falla(*args, **kwargs):
        raise OSError("sin notify-send")

    local_actions.subprocess.Popen = falla
    try:
        r.evento(70, ["super"])
        time.sleep(0.3)
    finally:
        local_actions.subprocess.Popen = original
    r.check(
        'the notification failure is logged',
        any("Could not show the shortcut notification" in m for m in logs),
        logs,
    )
    return r.failures


def test_contrato_luau_motor():
    print('28) the UI and engine use the same names')
    import re
    import tomllib

    import local_actions

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    raiz = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    def lista_de(texto, nombre):
        m = re.search(r"local %s = \{([^}]*)\}" % nombre, texto)
        if m is None:
            return None
        return re.findall(r'"([^"]+)"', m.group(1))

    with open(os.path.join(raiz, "lib", "panel_ui.luau"), encoding="utf-8") as fh:
        ui = fh.read()
    with open(os.path.join(raiz, "lib", "common.luau"), encoding="utf-8") as fh:
        comun = fh.read()
    with open(os.path.join(raiz, "plugin.toml"), "rb") as fh:
        manifiesto = tomllib.load(fh)

    modificadores_ui = lista_de(ui, "MODIFIERS")
    r.check(
        'the UI modifiers are the ones the engine understands',
        set(modificadores_ui or []) == set(local_actions.MODIFIER_CODES.values()) | {"none", "no_super"},
        modificadores_ui,
    )
    disparadores_ui = lista_de(ui, "TRIGGERS")
    r.check(
        'the UI triggers match the engine triggers',
        tuple(disparadores_ui or []) == tuple(local_actions.TRIGGERS),
        (disparadores_ui, local_actions.TRIGGERS),
    )
    nombres_ui = lista_de(ui, "TRIGGER_NAMES")
    r.check(
        'all triggers have a name in the UI',
        set(disparadores_ui or []) >= set(local_actions.TRIGGERS),
        nombres_ui,
    )
    import budsctl as _budsctl

    niveles_ui = set(re.findall(r'level == "(\w+)"', ui))
    r.check(
        'the UI ANC levels match the daemon levels',
        niveles_ui == set(_budsctl.ANC_LEVELS),
        (sorted(niveles_ui), sorted(_budsctl.ANC_LEVELS)),
    )
    paneles_ui = re.findall(r'PANEL_ID\s*=\s*"(faminec/cmf-buds:[\w-]+)"', comun)
    paneles_manifiesto = {p["id"] for p in manifiesto["panel"]}
    r.check(
        'the UI panels match the manifest panels',
        set(paneles_ui) == {"faminec/cmf-buds:" + p for p in paneles_manifiesto},
        (paneles_ui, paneles_manifiesto),
    )
    return r.failures


def _acciones_permitidas_luau(texto):
    """Extract {group: {gesture: [actions]}} from Luau."""
    bloque = re.search(r"local ACTION_ALLOWED = \{(.*?)\n\}", texto, re.S)
    if bloque is None:
        return None
    salida = {}
    grupo = None
    for linea in bloque.group(1).splitlines():
        m = re.match(r"\s*(\w+) = \{(.*)$", linea)
        if m is None:
            continue
        nombre, resto = m.group(1), m.group(2)
        if resto.strip() in ("", "}"):
            # Group line: opens a table of gestures.
            grupo = nombre
            salida[grupo] = {}
        elif grupo is not None:
            salida[grupo][nombre] = re.findall(r'"([^"]+)"', resto)
    return salida


def test_gestos_permitidos():
    print('29) the allowed action list is the same in the UI and daemon')
    import budsctl

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    raiz = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    with open(os.path.join(raiz, "lib", "common.luau"), encoding="utf-8") as fh:
        comun = fh.read()
    ui = _acciones_permitidas_luau(comun)
    r.check('the UI list could be read', ui is not None and len(ui) > 0, ui)
    # The daemon indexes by (group, gesture); regroup it for comparison.
    demonio = {}
    for (grupo, gesto), acciones in budsctl.GESTURE_ALLOWED.items():
        demonio.setdefault(grupo, {})[gesto] = set(acciones)
    r.check(
        'the groups are the same',
        set(ui or {}) == set(demonio),
        (sorted((ui or {}).keys()), sorted(demonio.keys())),
    )
    diferencias = []
    for grupo, gestos in (ui or {}).items():
        for gesto, acciones in gestos.items():
            otras = set(demonio.get(grupo, {}).get(gesto, []))
            if set(acciones) != otras:
                diferencias.append((grupo, gesto, sorted(set(acciones) ^ otras)))
    r.check(
        'the allowed actions are the same in both places',
        not diferencias,
        diferencias,
    )
    # And the daemon does not accept an action that is not allowed for that gesture.
    permitidas = budsctl.GESTURE_ALLOWED[("left", "double")]
    no_permitida = next(
        (a for a in budsctl.GESTURE_ACTIONS if a not in permitidas),
        None,
    )
    r.check(
        'the daemon rejects an action not allowed for that gesture',
        no_permitida is not None,
        permitidas,
    )
    error = None
    try:
        budsctl.BudsDaemon._check_gesture("left", "double", no_permitida)
    except ValueError as exc:
        error = str(exc)
    r.check('and reports the reason', error is not None and "not available" in error, error)
    error2 = None
    try:
        budsctl.BudsDaemon._check_gesture("left", "double", "play_pause")
    except ValueError as exc:
        error2 = str(exc)
    r.check('an allowed action passes', error2 is None, error2)
    error3 = None
    try:
        budsctl.BudsDaemon._check_gesture("left", "inventado", "play_pause")
    except ValueError as exc:
        error3 = str(exc)
    r.check('a nonexistent gesture is rejected', error3 is not None, error3)
    # An invalid ANC level is also rejected (it previously fell back to "strong"
    # silently and the state stored the invalid level).
    exc4 = None
    try:
        budsctl.BudsDaemon._check_anc("anc", "inventado")
    except Exception as exc:
        exc4 = exc
    r.check(
        'an invalid ANC level is rejected with a clear error',
        isinstance(exc4, ValueError) and "ANC level" in str(exc4),
        exc4,
    )
    r.check(
        'a valid ANC level is accepted',
        budsctl.BudsDaemon._check_anc("anc", "high") is not None
        and budsctl.BudsDaemon._check_anc("off") is not None
        and budsctl.BudsDaemon._check_anc("transparency") is not None,
    )
    error5 = None
    try:
        budsctl.BudsDaemon._check_anc("inventado")
    except ValueError as exc:
        error5 = str(exc)
    r.check('an invalid ANC mode is rejected', error5 is not None, error5)
    return r.failures


def test_ajustes_invalidos():
    print('30) invalid settings are rejected rather than silently changed')
    import budsctl

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    exc = None
    try:
        budsctl.BudsDaemon._check_side("centro")
    except Exception as e:
        exc = e
    r.check('an invalid side is rejected', isinstance(exc, ValueError), exc)
    r.check(
        'valid sides are accepted',
        budsctl.BudsDaemon._check_side("left") == 0x02
        and budsctl.BudsDaemon._check_side("right") == 0x03,
    )
    # The volume is clamped before being marked as our change: if the
    # unclamped value were marked, it would not match the actual volume and
    # the engine would mistake the change for a user gesture.
    import inspect

    fuente = inspect.getsource(budsctl.BudsDaemon.set_volume)
    r.check(
        'the change is marked with the already-clamped volume',
        "note_self_change(pct)" in fuente
        and "note_self_change(percent)" not in fuente,
        fuente,
    )
    return r.failures


def test_apagado_de_anillos():
    print('31) a ring that cannot be turned off is retried')
    import budsctl

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    demonio = budsctl.BudsDaemon.__new__(budsctl.BudsDaemon)
    demonio.ring_until = {"left": 10.0, "right": 0}
    intentos = []

    def falla(side, enabled):
        intentos.append((side, enabled))
        raise RuntimeError("sin enlace")

    demonio.ring = falla
    demonio._stop_rings(100.0)
    r.check('it tries to turn off the applicable ring', intentos == [("left", False)], intentos)
    r.check(
        'if it fails, it is not considered off (it will be retried)',
        demonio.ring_until.get("left") == 10.0,
        demonio.ring_until,
    )
    r.check('the other ring is left unchanged', demonio.ring_until.get("right") == 0)
    # If it succeeds, it is marked as off.
    demonio.ring_until = {"left": 10.0}
    demonio.ring = lambda side, enabled: intentos.append((side, enabled))
    demonio._stop_rings(100.0)
    r.check('if it succeeds, it is marked as off', demonio.ring_until.get("left") == 0, demonio.ring_until)
    return r.failures


def test_la_marca_caduca():
    print('32) our-change marker expires (it does not swallow a later gesture)')
    import local_actions

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    e = r.engine
    e.modifiers.held = {"super"}
    # 1) The device echo (the same value) is always ignored.
    e.note_self_change(40)
    e.volume = 40
    e._on_volume_change("fake")
    time.sleep(0.3)
    r.check('the device echo is ignored', e.fired == [], e.fired)

    # 2) Within the period, a user +1 falls within the echo tolerance and
    # is confused with it: the gesture is lost.
    e.fired.clear()
    e.note_self_change(40)
    e.volume = 41
    e._on_volume_change("fake")
    time.sleep(0.3)
    r.check('within the period, a +1 is confused with the echo', e.fired == [], e.fired)

    # 3) After the period, a +1 is a user gesture and is not swallowed.
    e.fired.clear()
    e.note_self_change(40)
    time.sleep(local_actions.SELF_CHANGE_TTL + 0.4)
    e.volume = 41
    e._on_volume_change("fake")
    time.sleep(0.3)
    r.check('a later gesture is not swallowed', e.fired == ["UNO"], e.fired)
    return r.failures


def test_restore_respeta_al_usuario():
    print('33) the restore does not override a user change')
    import local_actions

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    # The volume is the current one; 'since' is the value from before the gesture.
    r.check(
        'if the volume has not changed, it is restored',
        local_actions._should_restore(45, 45) is True,
    )
    r.check(
        'a difference of 1 (echo rounding) is also restored',
        local_actions._should_restore(46, 45) is True,
    )
    r.check(
        'if the user has turned it again, it is not restored',
        local_actions._should_restore(50, 45) is False,
    )
    r.check(
        'if the volume is unknown, it is restored',
        local_actions._should_restore(None, 45) is True
        and local_actions._should_restore(45, None) is True,
    )
    return r.failures


def test_modificador_prohibido():
    print('34) a rule can require a modifier NOT to be held')
    r = Runner([rule("a", "volume_up", 0, "none", "SIN_SUPER")])
    # The UI's "no_super" option is stored as forbid: ["super"].
    r.engine.rules[0]["require"] = []
    r.engine.rules[0]["forbid"] = ["super"]
    r.evento(60, ["super"])
    time.sleep(0.3)
    r.check('with SUPER held, it does not run', r.engine.fired == [], r.engine.fired)
    r.calmarse()
    r.evento(70, [])
    time.sleep(0.3)
    r.check('without SUPER, it does run', r.engine.fired == ["SIN_SUPER"], r.engine.fired)
    # And a rule requiring SUPER continues to require it.
    r.calmarse()
    r2 = Runner([rule("b", "volume_up", 0, "super", "CON_SUPER")])
    r2.evento(60, [])
    time.sleep(0.3)
    r2.check('the rule requiring SUPER does not run without it', r2.engine.fired == [], r2.engine.fired)
    r2.calmarse()
    r2.evento(70, ["super"])
    time.sleep(0.3)
    r2.check('and it does run with it', r2.engine.fired == ["CON_SUPER"], r2.engine.fired)
    return r.failures


def test_restaurar_volumen():
    print("35) the 'restore volume' option returns the previous volume")
    import local_actions

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    r.engine.rules[0]["restore_volume"] = True
    r.engine._sink_provider = lambda: "sink-falso"
    llamadas = []
    original = local_actions._run

    # Replace the pactl call: the system's actual volume is not touched.
    local_actions._run = _pactl_falso(llamadas, r.engine)
    try:
        r.engine._run_rule(
            r.engine.rules[0], "volume_up", 1, ["super"], 40
        )
        _esperar_restore(r.engine, 40)
    finally:
        local_actions._run = original
    r.check(
        'it requests restoration of the previous volume',
        any(
            "set-sink-volume" in " ".join(c) and "40%" in " ".join(c)
            for c in llamadas
        ),
        llamadas,
    )
    return r.failures


def test_contrato_del_estado():
    print('36) the UI only reads keys published by the daemon')
    import re

    import budsctl

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    raiz = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    leidas = set()
    for nombre in os.listdir(os.path.join(raiz, "lib")):
        if not nombre.endswith(".luau"):
            continue
        with open(os.path.join(raiz, "lib", nombre), encoding="utf-8") as fh:
            leidas |= set(re.findall(r"\bst\.([a-z_]+)", fh.read()))
    for nombre in os.listdir(raiz):
        if nombre.startswith("panel_") and nombre.endswith(".luau"):
            with open(os.path.join(raiz, nombre), encoding="utf-8") as fh:
                leidas |= set(re.findall(r"\bst\.([a-z_]+)", fh.read()))
    with open(os.path.join(raiz, "widget.luau"), encoding="utf-8") as fh:
        leidas |= set(re.findall(r"\bst\.([a-z_]+)", fh.read()))

    publicadas = set(budsctl.empty_state().keys()) | {"local_actions"}
    r.check('the UI reads some keys', len(leidas) > 5, sorted(leidas))
    r.check(
        'the daemon publishes every key read by the UI',
        leidas <= publicadas,
        sorted(leidas - publicadas),
    )
    return r.failures


def test_forbid_vacio():
    print('37) a rule saved from the panel with forbid={} still works')
    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    # Simulate what the panel serializes: forbid as an empty object.
    r.engine.rules[0]["forbid"] = {}
    r.engine.rules[0]["require"] = ["super"]
    r.engine._rules_mtime = 0.0
    r.engine.modifiers.held = {"super"}
    r.engine.volume = 60
    r.engine._on_volume_change("fake")
    time.sleep(0.2)
    r.check('the rule with forbid={} is triggered', r.engine.fired == ["UNO"], r.engine.fired)
    return r.failures


def test_knob_press():
    print('38) the case button (knob) can also trigger rules')
    r = Runner([rule("k", "knob_press", 1, "none", "KNOB")])
    r.engine._on_media_press("PlayPause")
    time.sleep(0.9)
    r.check('a knob press triggers the rule', "KNOB" in r.engine.fired, r.engine.fired)
    return r.failures


def test_ultima_accion_y_mods():
    print('39) the engine publishes the last action and the modifiers used')
    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    r.engine.modifiers.held = {"super"}
    r.engine.modifiers.available = True
    r.engine.volume = 60
    r.engine._on_volume_change("fake")
    time.sleep(0.2)
    snap = r.engine.snapshot()
    r.check('last_event contains the trigger', snap["last_event"].get("trigger") == "volume_up", snap["last_event"])
    r.check('last_action contains the command', snap["last_action"].get("command") == "UNO", snap["last_action"])
    r.check('last_action stores the modifiers', snap["last_action"].get("modifiers") == ["super"], snap["last_action"])
    r.check('modifiers are available', snap["modifiers_available"] is True, snap)
    return r.failures


def test_traducciones():
    print('37) translations are consistent and valid for the store')
    import json
    import re

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    raiz = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    def aplanar(tabla, prefijo=""):
        salida = {}
        for clave, valor in tabla.items():
            ruta = prefijo + clave
            if isinstance(valor, dict):
                salida.update(aplanar(valor, ruta + "."))
            else:
                salida[ruta] = valor
        return salida

    tablas = {}
    for lang in ("es", "en"):
        with open(
            os.path.join(raiz, "translations", "%s.json" % lang), encoding="utf-8"
        ) as fh:
            tablas[lang] = json.load(fh)
    planas = {lang: aplanar(t) for lang, t in tablas.items()}

    r.check(
        'es.json and en.json have the same keys',
        set(planas["es"]) == set(planas["en"]),
        sorted(set(planas["es"]) ^ set(planas["en"])),
    )
    r.check('there are no empty keys', all(v != "" for v in planas["es"].values()))

    # The store requires every key to be a simple lowercase segment
    # (a-z, 0-9, hyphens and underscores, not leading) and requires nesting
    # to be expressed with objects, not dots.
    segmento = re.compile(r"^[a-z0-9-][a-z0-9_-]*$")
    malas = []
    for lang, tabla in tablas.items():
        for clave in tabla:
            if not segmento.match(clave):
                malas.append("%s: %s" % (lang, clave))
    r.check('top-level keys are valid', not malas, malas)
    r.check(
        'keys do not contain dots (nesting uses objects)',
        not any("." in k for k in tablas["es"]),
        [k for k in tablas["es"] if "." in k],
    )

    # And all keys used by the code exist in the translations.
    # lib/ is checked too: most keys live there, and previously only the root
    # was checked, so a broken key in lib/ was not detected.
    usadas = set()
    prefijos = set()
    for base in (raiz, os.path.join(raiz, "lib")):
        for nombre in os.listdir(base):
            ruta = os.path.join(base, nombre)
            if not os.path.isfile(ruta) or not nombre.endswith(".luau"):
                continue
            with open(ruta, encoding="utf-8") as fh:
                texto = fh.read()
            # Only literal keys: concatenated keys ("anc." .. x) cannot be
            # checked here (only their prefix is checked).
            usadas |= set(re.findall(r'tr\(\s*"([^"]+)"\s*\)', texto))
            prefijos |= set(re.findall(r'tr\(\s*"([^"]*\.)', texto))
    faltan = sorted(k for k in usadas if k not in planas["en"])
    r.check('all keys used by the code exist', not faltan, faltan)
    prefijos_faltan = sorted(
        p for p in prefijos if not any(k.startswith(p) for k in planas["en"])
    )
    r.check(
        'prefixes for concatenated keys exist',
        not prefijos_faltan,
        prefijos_faltan,
    )
    return r.failures


def test_recarga():
    print('7) rules edited outside the panel are reloaded')
    path = "/tmp/cmf-buds-test-rules.json"
    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    r.engine.rules_path = path
    with open(path, "w", encoding="utf-8") as fh:
        fh.write('{"rules": [%s]}' % _json_rule("b", "volume_up", 0, "super", "DESDE_FICHERO"))
    r.evento(60, ["super"])
    time.sleep(0.2)
    r.check('it uses the rule from the file', r.engine.fired == ["DESDE_FICHERO"], r.engine.fired)
    if os.path.exists(path):
        os.unlink(path)
    return r.failures


def test_demonio_refleja_la_caida():
    print('46) the daemon notices that the link has dropped')
    import argparse

    import budsctl

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    args = argparse.Namespace(
        state="/tmp/cmf-buds-test-demonio/state.json",
        socket="/tmp/cmf-buds-test-demonio/buds.sock",
        log="/tmp/cmf-buds-test-demonio/daemon.log",
        poll=20,
        idle_timeout=600,
        device_mac="",
        device_name="CMF Buds Pro 2",
    )
    daemon = budsctl.BudsDaemon(args)
    daemon.state["connected"] = True
    link = None
    try:
        link = daemon._new_link("00:00:00:00:00:00")
        link.connected = True
        link._abort("The RFCOMM connection was lost")
        caida = True
    except Exception as exc:
        caida = False
        print('   (could not simulate the disconnection: %s)' % exc)
    r.check('the link reports its disconnection', caida)
    if link is not None:
        r.check(
            'the state changes to disconnected',
            daemon.state["connected"] is False,
            daemon.state["connected"],
        )
        r.check(
            'the notification is recorded',
            daemon.state["error"] == "link_lost"
            and "RFCOMM" in daemon.state["error_detail"],
            (daemon.state["error"], daemon.state["error_detail"]),
        )
    return r.failures


def test_configuracion_del_demonio():
    print('47) configuration is applied to the daemon at runtime')
    import argparse

    import budsctl

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    raiz = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    args = argparse.Namespace(
        state="/tmp/cmf-buds-test-demonio/state.json",
        socket="/tmp/cmf-buds-test-demonio/buds.sock",
        log="/tmp/cmf-buds-test-demonio/daemon.log",
        poll=60,
        idle_timeout=600,
        device_mac="",
        device_name="",
    )
    daemon = budsctl.BudsDaemon(args)
    logs = []
    daemon.log = logs.append
    resp = daemon.handle_rpc(
        {
            "cmd": "configure",
            "poll": 20,
            "device_mac": "AA:BB:CC:DD:EE:FF",
            "device_name": "CMF Buds Pro 2",
        }
    )
    r.check('the polling interval is applied', daemon.poll == 20, daemon.poll)
    r.check(
        'the device name is applied',
        daemon.preferred_name == "CMF Buds Pro 2",
        daemon.preferred_name,
    )
    r.check(
        'the MAC is applied',
        daemon.preferred_mac == "AA:BB:CC:DD:EE:FF",
        daemon.preferred_mac,
    )
    r.check('the response is correct', resp.get("ok") is True, resp)
    r.check(
        'the application is recorded (to verify that it is running correctly)',
        any("20" in m for m in logs),
        logs,
    )
    # And the service must pass that configuration to the daemon: when the
    # plugin reloads, the daemon starts with the default values (the user's
    # configuration has not been applied yet) and stays that way until the panel
    # is opened.
    with open(os.path.join(raiz, "service.luau"), encoding="utf-8") as fh:
        servicio = fh.read()
    r.check(
        'the service passes the configuration to the daemon',
        '"cmd":"configure"' in servicio and "configureDaemon()" in servicio,
    )
    return r.failures


def test_error_esperado_del_rpc():
    print('48) an expected RPC error does not fill the log with tracebacks')
    import argparse

    import budsctl

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    args = argparse.Namespace(
        state="/tmp/cmf-buds-test-demonio/state.json",
        socket="/tmp/cmf-buds-test-demonio/buds.sock",
        log="/tmp/cmf-buds-test-demonio/daemon.log",
        poll=20,
        idle_timeout=600,
        device_mac="",
        device_name="CMF Buds Pro 2",
    )
    daemon = budsctl.BudsDaemon(args)
    logs = []
    daemon.log = logs.append
    exc = None
    try:
        # No link: the action cannot be performed. This is a normal situation
        # (the user presses a button with the headphones disconnected), not a
        # daemon failure.
        daemon.handle_rpc({"cmd": "anc", "mode": "anc", "level": "high"})
    except Exception as e:
        exc = e
    r.check(
        'the action fails with an expected error',
        isinstance(exc, getattr(budsctl, "UserError", ())),
        exc,
    )
    resp = daemon._rpc_error(exc)
    r.check('the response reports the failure', resp.get("ok") is False, resp)
    r.check(
        'the log is a single line, with no traceback',
        len(logs) == 1 and "Traceback" not in logs[0],
        logs,
    )
    return r.failures


def _json_rule(rid, trigger, presses, modifier, command):
    import json

    return json.dumps(rule(rid, trigger, presses, modifier, command))


def test_restore_volumen_al_cerrar_el_gesto():
    print("40) the 'any' rule that waits for closure restores the previous volume")
    import local_actions

    # A 3-press rule blocks the "any" rule: it does not fire when the
    # gesture starts, but when the gesture closes. When it closes, it must
    # restore the volume from BEFORE the gesture.
    r = Runner(
        [
            rule("n", "volume_up", 3, "none", "TRES"),
            rule("a", "volume_up", 0, "none", "UNO"),
        ]
    )
    r.engine.rules[1]["restore_volume"] = True
    r.engine._sink_provider = lambda: "sink-falso"
    llamadas = []
    original = local_actions._run

    local_actions._run = _pactl_falso(llamadas, r.engine)
    try:
        # The dial rises from 50 to 60: the volume before the gesture is 50.
        r.engine.volume = 60
        r.engine._on_volume_change("fake")
        _esperar_restore(r.engine, 50)
    finally:
        local_actions._run = original
    r.check("the 'any' rule runs when the gesture closes", "UNO" in r.engine.fired, r.engine.fired)
    r.check(
        'the previous volume is restored when the gesture closes',
        any(
            "set-sink-volume" in " ".join(c) and "50%" in " ".join(c)
            for c in llamadas
        ),
        llamadas,
    )
    return r.failures


def test_modificadores_del_gesto():
    print('41) the gesture resolves with the modifiers used to make it')
    # A 3-press rule blocks the "any" rule: it is
    # resolved when the gesture closes.
    reglas = [
        rule("n", "volume_up", 3, "none", "TRES"),
        rule("a", "volume_up", 0, "super", "CON_SUPER"),
    ]

    r = Runner(reglas)
    r.engine.modifiers.held = {"super"}
    r.engine.volume = 60
    r.engine._on_volume_change("fake")
    # The user releases SUPER before the gesture closes: the gesture was
    # made with SUPER, so the rule still matches.
    r.engine.modifiers.held = set()
    esperar(lambda: "CON_SUPER" in r.engine.fired, timeout=4.0)
    r.check(
        'the gesture remembers the modifiers from the start',
        "CON_SUPER" in r.engine.fired,
        r.engine.fired,
    )

    r2 = Runner(reglas)
    # The opposite: the gesture was made WITHOUT a modifier and SUPER is pressed
    # afterward. The gesture is already complete: the SUPER rule cannot activate.
    r2.engine.volume = 60
    r2.engine._on_volume_change("fake")
    r2.engine.modifiers.held = {"super"}
    time.sleep(1.4)
    r2.check(
        'a modifier pressed afterward does not activate the rule',
        r2.engine.fired == [],
        r2.engine.fired,
    )
    return r.failures


def test_reglas_malformadas():
    print("42) a rules file whose 'rules' value is not a list does not break the engine")
    import json

    r = Runner([])
    path = "/tmp/cmf-buds-test-malformadas.json"
    r.engine.rules_path = path
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"rules": {"id": "a"}}, fh)
    r.engine.load()
    r.check('malformed rules are discarded', r.engine.rules == [], r.engine.rules)
    # And the engine can still add rules normally.
    try:
        r.engine.upsert(rule("b", "volume_up", 0, "none", "OK"))
        upsert_ok = len(r.engine.rules) == 1
    except Exception as exc:
        upsert_ok = False
        print('   (upsert failed: %s)' % exc)
    r.check('rules can still be added', upsert_ok, r.engine.rules)
    if os.path.exists(path):
        os.unlink(path)
    return r.failures


def test_watcher_sin_id_de_sink():
    print('43) the watcher ignores events if it cannot identify the sink')
    import local_actions

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    llamadas = {"n": 0}
    logs = []

    def on_change(sink):
        llamadas["n"] += 1

    original = local_actions._run

    def fake_run(cmd, timeout=6):
        class Res:
            stdout = ""
            returncode = 1

        return Res()

    local_actions._run = fake_run
    try:
        watcher = VolumeWatcher(lambda: "sink-falso", on_change, logs.append)
        nuevo = watcher._handle_line("Event 'change' on sink #42", "sink-falso", None)
    finally:
        local_actions._run = original
    r.check('the event is ignored', llamadas["n"] == 0, llamadas)
    r.check('the watcher does not invent an ID', nuevo is None, nuevo)
    return r.failures


def test_modificadores_sin_dispositivos():
    print('44) the modifier reader survives without /dev/input and retries')
    import tempfile

    import local_actions

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    logs = []
    original = local_actions._list_event_devices
    local_actions._list_event_devices = lambda: []
    tracker = local_actions.ModifierTracker(logs.append)
    try:
        tracker.start()
        time.sleep(0.3)
        vivo = tracker._thread.is_alive()
        r.check('the thread remains alive without devices', vivo)
        # When the devices appear, it opens them without needing to restart.
        with tempfile.NamedTemporaryFile(prefix="cmf-event", delete=False) as fh:
            ruta = fh.name
        local_actions._list_event_devices = lambda: [ruta]
        try:
            aparecer = esperar(lambda: tracker.available, timeout=8.0)
        finally:
            os.unlink(ruta)
    finally:
        local_actions._list_event_devices = original
        tracker.stop()
    r.check('the thread retries and opens the devices', aparecer, logs)
    return r.failures


def test_enlace_muerto():
    print('45) a dead RFCOMM socket aborts the link (the daemon reconnects)')
    import budsctl

    r = Runner([rule("a", "volume_up", 0, "super", "UNO")])
    link = budsctl.BudsLink("00:00:00:00:00:00")
    errores = []
    link.on_disconnect = lambda reason: errores.append(reason)
    link.connected = True
    link.running = True

    class SockMuerto:
        def sendall(self, data):
            raise OSError(107, "Transport endpoint is not connected")

        def shutdown(self, how):
            pass

        def close(self):
            pass

    link.sock = SockMuerto()
    excepcion = None
    try:
        link.request(0xC007, b"", timeout=0.5)
    except Exception as exc:
        excepcion = exc
    r.check('the request fails', excepcion is not None, excepcion)
    r.check('the link is disconnected', not link.connected)
    r.check('the socket is released', link.sock is None)
    r.check('the disconnection is reported', bool(errores), errores)
    return r.failures


def main():
    print('Local shortcut engine tests\n')
    total = 0
    for test in (
        test_regla_cualquiera_sola,
        test_contador_manda,
        test_modificadores_distintos,
        test_especificidad,
        test_comando_vacio,
        test_rafaga,
        test_recarga,
        test_gesto_despues_de_restaurar,
        test_pinchazos_muy_juntos,
        test_cambio_propio_por_valor,
        test_gestos_separados,
        test_regla_malformada,
        test_watcher_sobrevive,
        test_watcher_sin_suscripcion,
        test_espera_creciente,
        test_contador_se_reinicia,
        test_suscripcion_corta,
        test_watcher_resolutor_falla,
        test_restore_falla_visible,
        test_no_se_pisan_las_reglas_del_fichero,
        test_gesto_no_se_pierde,
        test_lector_cierra_el_socket,
        test_reconectar_cierra_el_enlace_anterior,
        test_tramas_rfcmm,
        test_ecodec_y_modelo,
        test_codigos_de_modificadores,
        test_aviso_del_atajo,
        test_contrato_luau_motor,
        test_gestos_permitidos,
        test_ajustes_invalidos,
        test_apagado_de_anillos,
        test_la_marca_caduca,
        test_restore_respeta_al_usuario,
        test_modificador_prohibido,
        test_restaurar_volumen,
        test_contrato_del_estado,
        test_forbid_vacio,
        test_knob_press,
        test_ultima_accion_y_mods,
        test_traducciones,
        test_restore_volumen_al_cerrar_el_gesto,
        test_modificadores_del_gesto,
        test_reglas_malformadas,
        test_watcher_sin_id_de_sink,
        test_modificadores_sin_dispositivos,
        test_enlace_muerto,
        test_demonio_refleja_la_caida,
        test_configuracion_del_demonio,
        test_error_esperado_del_rpc,
    ):
        total += test()
    print("")
    if total:
        print('%d FAILURES' % total)
        return 1
    print('All tests passed')
    return 0

if __name__ == "__main__":
    sys.exit(main())
