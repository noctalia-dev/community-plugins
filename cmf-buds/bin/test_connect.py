#!/usr/bin/env python3
"""Tests for the panel's Connect button (manual Bluetooth connection).

They run without touching the real earbuds: `pick_device`, `bluetoothctl` and
the RFCOMM link are mocked.
"""

import os
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import budsctl

MAC = "2C:BE:EE:40:3F:6D"


class FakeLink:
    def __init__(self):
        self.connected = False
        self.opened = False

    def open(self):
        self.opened = True
        self.connected = True

    def close(self):
        self.connected = False


class ConnectTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        args = types.SimpleNamespace(
            state=os.path.join(self.tmp.name, "state.json"),
            socket=os.path.join(self.tmp.name, "daemon.sock"),
            log=os.path.join(self.tmp.name, "daemon.log"),
            poll=20,
            idle_timeout=300,
            device_mac=MAC,
            device_name="CMF Buds Pro 2",
        )
        self.d = budsctl.BudsDaemon(args)
        self.d.save = lambda: None
        self.d.query_all = lambda: None
        self.link = FakeLink()
        self.d._new_link = lambda mac: self.link
        # Fake clock: the waits must not slow the suite down.
        self.clock = [1000.0]
        time_patch = mock.patch.object(budsctl.time, "time", side_effect=lambda: self.clock[0])
        sleep_patch = mock.patch.object(
            budsctl.time, "sleep", side_effect=lambda seconds: self.clock.__setitem__(0, self.clock[0] + seconds)
        )
        time_patch.start()
        sleep_patch.start()
        self.addCleanup(time_patch.stop)
        self.addCleanup(sleep_patch.stop)
        self.addCleanup(self.tmp.cleanup)

    def info(self, connected=True):
        return {
            "mac": MAC,
            "name": "CMF Buds Pro 2",
            "alias": "CMF Buds Pro 2",
            "connected": connected,
            "battery": None,
            "icon": "audio-headset",
        }

    def test_manual_connect_ignores_backoff(self):
        self.d.last_connect_attempt = time.time()
        self.d.connect_backoff = 30.0
        with mock.patch.object(budsctl, "pick_device", return_value=self.info(True)):
            ok = self.d.connect(force_bt=True, user=True)
        self.assertTrue(ok)
        self.assertTrue(self.link.opened)
        self.assertLessEqual(self.d.connect_backoff, 5.0)

    def test_auto_connect_keeps_backoff(self):
        self.d.last_connect_attempt = time.time()
        self.d.connect_backoff = 30.0
        with mock.patch.object(budsctl, "pick_device", return_value=self.info(True)):
            ok = self.d.connect(force_bt=False)
        self.assertFalse(ok)
        self.assertFalse(self.link.opened)

    def test_manual_connect_runs_bluetoothctl(self):
        calls = []

        def fake_run(cmd, timeout=10):
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, "Connection successful\n", "")

        with mock.patch.object(budsctl, "pick_device", return_value=self.info(False)), \
                mock.patch.object(budsctl, "run", side_effect=fake_run), \
                mock.patch.object(budsctl, "bt_info", return_value=self.info(True)):
            ok = self.d.connect(force_bt=True, user=True)
        self.assertTrue(ok)
        self.assertIn(["bluetoothctl", "connect", MAC], calls)
        self.assertTrue(self.link.opened)

    def test_manual_connect_reports_bluetooth_failure(self):
        def fake_run(cmd, timeout=10):
            return subprocess.CompletedProcess(
                cmd, 1, "Failed to connect: org.bluez.Error.Failed\n", ""
            )

        with mock.patch.object(budsctl, "pick_device", return_value=self.info(False)), \
                mock.patch.object(budsctl, "run", side_effect=fake_run), \
                mock.patch.object(budsctl, "bt_info", return_value=self.info(False)):
            ok = self.d.connect(force_bt=True, user=True)
        self.assertFalse(ok)
        self.assertFalse(self.link.opened)
        # The state carries a stable code (the panel translates it), not a
        # sentence in a fixed language.
        self.assertEqual(self.d.state["error"], "connect_failed")
        self.assertIn(
            "org.bluez.Error.Failed", self.d.state["error_detail"]
        )

    def test_connect_rpc_reports_failure(self):
        def fake_run(cmd, timeout=10):
            return subprocess.CompletedProcess(
                cmd, 1, "Failed to connect: org.bluez.Error.Failed\n", ""
            )

        with mock.patch.object(budsctl, "pick_device", return_value=self.info(False)), \
                mock.patch.object(budsctl, "run", side_effect=fake_run), \
                mock.patch.object(budsctl, "bt_info", return_value=self.info(False)):
            res = self.d.handle_rpc({"cmd": "connect"})
        self.assertFalse(res["ok"])
        self.assertEqual(res["error"], "connect_failed")
        self.assertIn("org.bluez.Error.Failed", res["error_detail"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
