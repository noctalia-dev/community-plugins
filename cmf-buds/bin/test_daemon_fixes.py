#!/usr/bin/env python3
"""Regression tests for the daemon (budsctl.py).

Each test describes a bug that was found in the pre-PR review. They run
without Bluetooth: the daemon object is built around a fake link and the
external commands are mocked.

Run with: python3 bin/test_daemon_fixes.py
"""

import argparse
import inspect
import json
import os
import socket
import struct
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import budsctl


class TrackingRLock:
    """An RLock that counts how many times it was entered."""

    def __init__(self):
        self._lock = threading.RLock()
        self.entered = 0

    def __enter__(self):
        self.entered += 1
        self._lock.acquire()
        return self

    def __exit__(self, *exc):
        self._lock.release()
        return False


class FakeLink:
    """A stand-in for BudsLink: it records what was sent."""

    def __init__(self, connected=True):
        self.connected = connected
        self.sent = []
        self.closed = 0
        self.opened = 0

    def open(self):
        self.opened += 1

    def send(self, cmd, payload=b"", timeout=1.0):
        self.sent.append((cmd, payload))

    def request(self, cmd, payload=b"", timeout=1.0):
        return b""

    def close(self):
        self.closed += 1
        self.connected = False


def make_args(directory, **overrides):
    values = {
        "state": os.path.join(directory, "state.json"),
        "socket": os.path.join(directory, "daemon.sock"),
        "log": os.path.join(directory, "daemon.log"),
        "poll": 20,
        "idle_timeout": 300,
        "device_mac": "",
        "device_name": "",
    }
    values.update(overrides)
    return argparse.Namespace(**values)


class DaemonTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name
        self.args = make_args(self.dir)
        self.daemon = budsctl.BudsDaemon(self.args)
        # The tests never write the state file.
        self.daemon.save = lambda: None

    def tearDown(self):
        self._tmp.cleanup()

    # -- A1: a corrupt length must not hide the following frames ------------
    def test_a_corrupt_length_does_not_hide_the_following_frames(self):
        good = budsctl.build_frame(0x1234, b"\x01\x02")
        corrupt = struct.pack(
            "<BHHH", budsctl.SOF, budsctl.CTRL_HOST_CRC, 0x1234, 0x4000
        )
        frames, _rest = budsctl.parse_frames(corrupt + good)
        self.assertEqual(
            len(frames), 1, "the valid frame after the corrupt one was lost"
        )
        self.assertEqual(frames[0][0], 0x1234 | 0x8000)
        self.assertEqual(frames[0][1], b"\x01\x02")

    def test_a_frame_larger_than_the_limit_is_rejected(self):
        huge = struct.pack(
            "<BHHH", budsctl.SOF, budsctl.CTRL_HOST_CRC, 0x1234, 0xFFFF
        )
        frames, _rest = budsctl.parse_frames(huge)
        self.assertEqual(frames, [], "an impossible frame was accepted")

    # -- A2: the link must be swapped under a lock --------------------------
    def test_the_link_is_swapped_under_a_lock(self):
        lock = TrackingRLock()
        self.daemon._link_lock = lock
        link = FakeLink()
        self.daemon._new_link = lambda mac: link
        device = {
            "mac": "00:11:22:33:44:55",
            "name": "CMF Buds Pro 2",
            "connected": True,
        }
        before = lock.entered
        with mock.patch.object(budsctl, "pick_device", return_value=device):
            with mock.patch.object(self.daemon, "query_all", return_value=True):
                self.assertTrue(self.daemon.connect(user=True))
        self.assertGreater(
            lock.entered, before, "the link was swapped without the lock"
        )
        self.assertIs(self.daemon.link, link)

    def test_disconnect_closes_the_link_under_a_lock(self):
        lock = TrackingRLock()
        self.daemon._link_lock = lock
        link = FakeLink()
        self.daemon.link = link
        before = lock.entered
        self.daemon.disconnect()
        self.assertGreater(lock.entered, before)
        self.assertEqual(link.closed, 1)
        self.assertIsNone(self.daemon.link)

    def test_two_disconnects_do_not_close_the_same_socket_twice(self):
        link = FakeLink()

        def slow_close():
            link.closed += 1
            time.sleep(0.05)
            link.connected = False

        link.close = slow_close
        self.daemon.link = link
        threads = [threading.Thread(target=self.daemon.disconnect) for _ in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(5)
        self.assertEqual(link.closed, 1, "the RFCOMM socket was closed twice")
        self.assertIsNone(self.daemon.link)

    # -- A3: a broken state file must not brick the daemon ------------------
    def test_a_state_file_with_a_broken_device_is_ignored(self):
        path = os.path.join(self.dir, "state.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"device": "not an object"}, fh)
        self.daemon.state_path = path
        self.daemon._load_previous_state()
        self.assertIsInstance(
            self.daemon.state["device"], dict, "the device state is broken"
        )

    def test_the_device_of_the_previous_run_is_loaded(self):
        path = os.path.join(self.dir, "state.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"device": {"mac": "AA:BB:CC:DD:EE:FF"}}, fh)
        self.daemon.state_path = path
        self.daemon._load_previous_state()
        self.assertEqual(self.daemon.state["device"]["mac"], "AA:BB:CC:DD:EE:FF")

    # -- A4: the fallback snapshot must have the keys the panel reads -------
    def test_the_fallback_snapshot_has_the_keys_the_panel_reads(self):
        self.daemon.local = None
        snapshot = self.daemon._local_snapshot()
        for key in (
            "rules",
            "last_event",
            "last_action",
            "modifiers",
            "modifiers_available",
        ):
            self.assertIn(key, snapshot, "the panel cannot read '%s'" % key)

    def test_the_fallback_snapshot_does_not_leak_the_previous_one(self):
        self.daemon.local = None
        first = self.daemon._local_snapshot()
        first["rules"].append({"id": "x"})
        second = self.daemon._local_snapshot()
        self.assertEqual(second["rules"], [], "the fallback snapshot is shared")

    # -- A5: the setters must not hand out the live state -------------------
    def test_the_setters_return_a_copy_of_the_state(self):
        self.daemon.link = FakeLink()
        cases = [
            lambda: self.daemon.set_anc("anc", "high"),
            lambda: self.daemon.set_eq("balanced"),
            lambda: self.daemon.set_custom_eq(1, 2, 3),
            lambda: self.daemon.set_bass(True, 2),
            lambda: self.daemon.set_toggle("spatial", True),
            lambda: self.daemon.set_gesture("left", "double", "play_pause"),
            lambda: self.daemon.ring("left", True),
            lambda: self.daemon.fit_test(True),
        ]
        for index, case in enumerate(cases):
            result = case()
            self.assertIsNot(
                result, self.daemon.state, "setter %d returned the live state" % index
            )
            result["anc"]["mode"] = "off"
            self.assertNotEqual(
                self.daemon.state["anc"]["mode"],
                "off",
                "setter %d returned a state that can be modified from outside" % index,
            )

    def test_the_volume_setter_returns_a_copy_of_the_state(self):
        self.daemon.link = FakeLink()
        self.daemon.local = types.SimpleNamespace(
            note_self_change=lambda value: None
        )
        command = types.SimpleNamespace(returncode=0, stdout="", stderr="")
        with mock.patch.object(self.daemon, "_sink", return_value="sink"):
            with mock.patch.object(self.daemon, "refresh_volume", return_value={}):
                with mock.patch.object(budsctl, "run", return_value=command):
                    result = self.daemon.set_volume(50)
        self.assertIsNot(result, self.daemon.state)

    # -- A6: the daemon must stop when nobody talks to it -------------------
    def test_the_daemon_shuts_down_after_the_idle_timeout(self):
        calls = []
        self.daemon.shutdown = lambda: calls.append("shutdown")
        self.daemon.connect = lambda *args, **kwargs: False
        self.daemon.refresh_volume = lambda: {}
        self.daemon.last_client = time.time() - 10_000
        self.daemon.idle_timeout = 60
        self.daemon.monitor()
        self.assertTrue(
            calls, "the daemon kept running after the idle timeout"
        )

    # -- A7: the RPC client must not leak sockets and must normalize paths --
    def test_rpc_call_closes_the_socket_when_the_call_fails(self):
        created = []

        class FakeSocket:
            def __init__(self, *args, **kwargs):
                self.closed = False
                created.append(self)

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                self.close()
                return False

            def settimeout(self, timeout):
                pass

            def connect(self, path):
                raise OSError("no such socket")

            def close(self):
                self.closed = True

        with mock.patch.object(budsctl.socket, "socket", FakeSocket):
            with self.assertRaises(OSError):
                budsctl.rpc_call("/tmp/cmf-buds-missing.sock", {"cmd": "ping"})
        self.assertTrue(created, "the socket was not even created")
        self.assertTrue(created[0].closed, "the socket leaked")

    def test_rpc_call_normalizes_the_socket_path(self):
        seen = {}

        class FakeSocket:
            def __init__(self, *args, **kwargs):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def settimeout(self, timeout):
                seen["timeout"] = timeout

            def connect(self, path):
                seen["path"] = path

            def sendall(self, data):
                seen["data"] = data

            def recv(self, size):
                return b'{"ok": true}\n'

            def close(self):
                pass

        with mock.patch.object(budsctl.socket, "socket", FakeSocket):
            budsctl.rpc_call("~/cmf-buds-test.sock", {"cmd": "ping"})
        self.assertEqual(
            seen["path"],
            os.path.abspath(os.path.expanduser("~/cmf-buds-test.sock")),
            "the socket path was not expanded",
        )

    # -- A8: the RPC timeout must survive a full query ----------------------
    def test_the_rpc_timeout_is_long_enough_for_a_full_query(self):
        default = inspect.signature(budsctl.rpc_call).parameters["timeout"].default
        self.assertGreaterEqual(default, 20.0, "the RPC timeout is too short")

    # -- A9: a client that never sends a line must not pin a thread ---------
    def test_the_rpc_handler_has_a_read_timeout(self):
        self.assertEqual(budsctl.RpcHandler.timeout, 10.0)

    def test_the_rpc_handler_applies_the_timeout_to_the_socket(self):
        seen = {}

        class Probe(budsctl.RpcHandler):
            def handle(self):
                seen["timeout"] = self.request.gettimeout()

        left, right = socket.socketpair()
        try:
            server = types.SimpleNamespace(daemon=self.daemon)
            Probe(left, ("local", 0), server)
        finally:
            try:
                right.close()
            except OSError:
                pass
        self.assertEqual(seen.get("timeout"), 10.0)

    # -- A10: logging without a log file must be a no-op --------------------
    def test_logging_without_a_log_path_does_nothing(self):
        self.daemon.log_path = ""
        with mock.patch.object(budsctl.os, "makedirs") as makedirs:
            self.daemon.log("hello")
        makedirs.assert_not_called()

    def test_logging_writes_to_the_log_file(self):
        self.daemon.log("hello")
        with open(self.daemon.log_path, "r", encoding="utf-8") as fh:
            self.assertIn("hello", fh.read())

    # -- A11: the refresh command must report the real result --------------
    def test_the_refresh_command_reports_the_real_result(self):
        self.daemon.link = None

        def fake_connect(force_bt=False, user=False):
            self.daemon.state["error"] = "the earbuds are not connected"
            return False

        self.daemon.connect = fake_connect
        result = self.daemon.handle_rpc({"cmd": "refresh"})
        self.assertFalse(result["ok"], "the refresh always reported success")
        self.assertTrue(result.get("error"), "the error was not reported")

    # -- A12: the poll interval must have one single range ------------------
    def test_the_default_poll_interval_is_twenty_seconds(self):
        parser = budsctl.build_parser()
        args = parser.parse_args(["daemon"])
        self.assertEqual(args.poll, 20)

    def test_the_poll_interval_is_clamped(self):
        low = budsctl.BudsDaemon(make_args(self.dir, poll=5))
        self.assertEqual(low.poll, 20)
        high = budsctl.BudsDaemon(make_args(self.dir, poll=10_000))
        self.assertEqual(high.poll, 300)

    def test_the_configure_command_clamps_the_poll_interval(self):
        self.daemon.handle_rpc({"cmd": "configure", "poll": 5})
        self.assertEqual(self.daemon.poll, 20)
        self.daemon.handle_rpc({"cmd": "configure", "poll": 100_000})
        self.assertEqual(self.daemon.poll, 300)

    # -- B4: an expected error must not fill the log with a traceback -------
    def test_an_expected_error_is_logged_on_one_line(self):
        logs = []
        self.daemon.log = logs.append
        for error in (budsctl.UserError("no audio sink"), ValueError("invalid preset")):
            logs.clear()
            result = self.daemon._rpc_error(error)
            self.assertFalse(result["ok"])
            self.assertEqual(len(logs), 1)
            self.assertNotIn("Traceback", logs[0])
            self.assertIn(
                str(error), logs[0], "the log line does not say what failed"
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
