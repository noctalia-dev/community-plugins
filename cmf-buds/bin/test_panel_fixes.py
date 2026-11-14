#!/usr/bin/env python3
"""Regression tests for the control panel and the daemon commands it uses.

The panel is Luau: Python cannot import it, so its contract is checked
against the source (the shape of the functions that were wrong). The
daemon side is tested for real: the commands and the timeout budget of
the RPC client are plain Python.

Run with: python3 bin/test_panel_fixes.py
"""

import argparse
import inspect
import os
import re
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import budsctl

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as fh:
        return fh.read()


def function_body(text, name):
    """The source of a top level function of a Luau file.

    The functions of the plugin are two-space indented, so the 'end' that
    closes them is the only one at the beginning of a line.
    """
    match = re.search(r"^local function %s\(" % re.escape(name), text, re.M)
    if match is None:
        return ""
    rest = text[match.start() :]
    end = re.search(r"^end\s*$", rest, re.M)
    if end is None:
        return rest
    return rest[: end.end()]


class FakeLink:
    """A stand-in for BudsLink: it records what was sent."""

    def __init__(self, connected=True):
        self.connected = connected
        self.sent = []
        self.closed = 0

    def open(self):
        pass

    def send(self, cmd, payload=b"", timeout=1.0):
        self.sent.append((cmd, payload))

    def request(self, cmd, payload=b"", timeout=1.0):
        return b""

    def close(self):
        self.closed += 1
        self.connected = False


def make_daemon():
    directory = tempfile.mkdtemp(prefix="cmf-buds-panel-")
    args = argparse.Namespace(
        state=os.path.join(directory, "state.json"),
        socket=os.path.join(directory, "daemon.sock"),
        log=os.path.join(directory, "daemon.log"),
        poll=20,
        idle_timeout=300,
        device_mac="",
        device_name="",
    )
    daemon = budsctl.BudsDaemon(args)
    daemon.save = lambda: None
    return daemon


class ReconnectTests(unittest.TestCase):
    """The 'Reconnect' button has to reopen the link.

    The 'connect' command returns at once when the link is alive, so it
    could not recover a half-open RFCOMM link: the button did nothing
    while pretending it had.
    """

    def test_the_reconnect_command_reopens_the_link(self):
        daemon = make_daemon()
        calls = []
        daemon.link = FakeLink()
        daemon.disconnect = lambda: calls.append("disconnect")
        daemon.connect = lambda force_bt=False, user=False, reactivate=False: (
            calls.append(("connect", force_bt, user, reactivate)),
            True,
        )[1]
        result = daemon.handle_rpc({"cmd": "reconnect"})
        self.assertTrue(result.get("ok"), "the reconnect did not report success")
        self.assertEqual(
            calls,
            ["disconnect", ("connect", True, True, True)],
            "the link was not closed and opened again",
        )

    def test_the_reconnect_command_reports_the_failure(self):
        daemon = make_daemon()
        daemon.disconnect = lambda: None
        daemon.connect = lambda force_bt=False, user=False, reactivate=False: False
        daemon.state["error"] = "disconnected"
        daemon.state["error_detail"] = "the phone kept the device"
        result = daemon.handle_rpc({"cmd": "reconnect"})
        self.assertFalse(result.get("ok"), "a failed reconnect reported success")
        self.assertEqual(result.get("error"), "disconnected")
        self.assertEqual(result.get("error_detail"), "the phone kept the device")

    def test_the_daemon_answers_the_reconnect_command(self):
        source = read("bin", "budsctl.py")
        self.assertTrue('if cmd == "reconnect":' in source)

    def test_the_reconnect_reactivates_bluetooth_when_the_channel_is_refused(self):
        """After the serial channel is closed the earbuds refuse it again.

        BlueZ only activates the RFCOMM channel again when the Bluetooth
        link itself is re-established: a reconnect that does not do that
        fails with "Connection refused" and the panel cannot recover.
        """
        daemon = make_daemon()
        commands = []
        opens = []

        class RefusingLink(FakeLink):
            def open(self):
                opens.append(1)
                if len(opens) == 1:
                    raise OSError("[Errno 111] Connection refused")
                self.connected = True

        def fake_run(cmd, timeout=10):
            commands.append(cmd)
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")

        device = {
            "mac": "AA:BB:CC:DD:EE:FF",
            "name": "CMF Buds Pro 2",
            "connected": True,
            "battery": None,
        }
        with mock.patch.object(budsctl, "run", side_effect=fake_run):
            with mock.patch.object(budsctl, "bt_info", return_value=device):
                with mock.patch.object(budsctl, "pick_device", return_value=device):
                    with mock.patch.object(budsctl.time, "sleep"):
                        daemon._new_link = lambda mac: RefusingLink()
                        result = daemon.handle_rpc({"cmd": "reconnect"})
        self.assertTrue(
            result.get("ok"), "the reconnect did not recover the link: %s" % result
        )
        self.assertEqual(len(opens), 2, "the link was not opened again")
        self.assertIn(
            ["bluetoothctl", "disconnect", "AA:BB:CC:DD:EE:FF"],
            commands,
            "the Bluetooth link was not re-established",
        )
        self.assertIn(
            ["bluetoothctl", "connect", "AA:BB:CC:DD:EE:FF"],
            commands,
            "the device was not connected again",
        )


class RpcBudgetTests(unittest.TestCase):
    """One timeout budget for the whole chain.

    The panel waits 60 s for the answer; the client of the daemon must
    answer before that, and a request that timed out must not be
    repeated blindly: the daemon may be working on it.
    """

    def test_the_client_timeout_is_the_shared_budget(self):
        default = inspect.signature(budsctl.rpc_call).parameters["timeout"].default
        self.assertEqual(default, budsctl.RPC_TIMEOUT)

    def test_the_budget_fits_inside_the_panel_timeout(self):
        panel = read("lib", "panel_ui.luau")
        match = re.search(r"local RPC_TIMEOUT_MS = (\d+)", panel)
        self.assertTrue(match, "the panel does not declare its timeout")
        host_timeout = int(match.group(1))
        self.assertTrue(budsctl.RPC_TIMEOUT > 20.0, "the budget is too short")
        self.assertTrue(
            budsctl.RPC_TIMEOUT * 1000 <= host_timeout,
            "the client can outlive the timeout of the panel",
        )

    def test_a_timed_out_request_is_not_repeated_when_the_daemon_is_alive(self):
        calls = []

        def fake_rpc_call(socket_path, req, timeout=20.0):
            calls.append(req.get("cmd"))
            if req.get("cmd") == "ping":
                return {"ok": True}
            raise TimeoutError("timed out")

        args = argparse.Namespace(socket="/tmp/cmf-buds-panel.sock")
        paths = {"socket": args.socket}
        with mock.patch.object(budsctl, "rpc_call", side_effect=fake_rpc_call):
            with mock.patch.object(budsctl, "ensure_daemon") as ensure:
                result = budsctl.rpc_request(args, paths, {"cmd": "refresh"})
        ensure.assert_not_called()
        self.assertFalse(result.get("ok"), "the timeout was reported as success")
        self.assertEqual(result.get("error"), "daemon_failed")
        self.assertEqual(
            calls,
            ["refresh", "ping"],
            "the request was repeated although the daemon was alive",
        )

    def test_the_request_is_repeated_when_the_daemon_is_not_there(self):
        calls = []

        def fake_rpc_call(socket_path, req, timeout=20.0):
            calls.append(req.get("cmd"))
            if req.get("cmd") == "ping":
                raise OSError("no such socket")
            if calls.count("status") == 1:
                raise OSError("no such socket")
            return {"ok": True}

        args = argparse.Namespace(socket="/tmp/cmf-buds-panel.sock")
        paths = {"socket": args.socket}
        with mock.patch.object(budsctl, "rpc_call", side_effect=fake_rpc_call):
            with mock.patch.object(budsctl, "ensure_daemon") as ensure:
                result = budsctl.rpc_request(args, paths, {"cmd": "status"})
        ensure.assert_called_once()
        self.assertTrue(result.get("ok"), "the request was not repeated")

    def test_the_cli_uses_the_shared_helper(self):
        source = read("bin", "budsctl.py")
        self.assertTrue("rpc_request(args, paths, req)" in source)


class PanelContractTests(unittest.TestCase):
    """The contract of the panel (lib/panel_ui.luau).

    The panel cannot be imported by Python, so the shape of the code that
    was wrong is checked here: every bug below was found by reading the
    panel and it has to stay fixed.
    """

    def setUp(self):
        self.panel = read("lib", "panel_ui.luau")

    def test_saving_a_rule_does_not_rewrite_its_constraints(self):
        body = function_body(self.panel, "saveRule")
        self.assertTrue(body, "the panel does not have a saveRule function")
        self.assertTrue(
            "modifierRequire" not in body,
            "saving a rule rebuilds its constraints and loses the hand written ones",
        )
        self.assertTrue(
            "modifierForbid" not in body,
            "saving a rule rebuilds its constraints and loses the hand written ones",
        )

    def test_a_new_rule_starts_with_the_constraints_of_its_modifier(self):
        body = function_body(self.panel, "newRule")
        self.assertTrue(
            "modifierRequire" in body,
            "a new rule has no constraints: it would fire without its modifier",
        )
        self.assertTrue("modifierForbid" in body)

    def test_the_header_refresh_button_asks_for_a_full_refresh(self):
        match = re.search(
            r'glyph = "refresh",.*?onClick = function\(\)\s*'
            r"(?:--[^\n]*\n\s*)*fullRefresh\(\)",
            self.panel,
            re.S,
        )
        self.assertTrue(
            match,
            "the refresh button asks only for the status: the values of the "
            "earbuds stay stale until the next poll",
        )

    def test_the_status_poll_waits_for_the_answer_of_the_request_in_flight(self):
        self.assertTrue(
            "autoRefreshSeq" in self.panel,
            "the poll does not know which request is in flight",
        )
        self.assertTrue(
            "now - autoRefreshAt <= 3" not in self.panel,
            "the poll gives up after three seconds and overlaps the requests",
        )
        self.assertTrue(
            "RPC_TIMEOUT_MS / 1000" in self.panel,
            "the poll does not wait for the timeout of the request",
        )

    def test_the_reconnect_button_asks_the_daemon_to_reopen_the_link(self):
        self.assertTrue(
            '"reconnect"' in self.panel,
            "the reconnect button sends the connect command, that does nothing",
        )

    def test_the_test_button_saves_the_rule_before_running_it(self):
        body = function_body(self.panel, "ruleCard")
        index = body.find('cmd = "local_test"')
        self.assertNotEqual(index, -1, "the test button does not run the command")
        start = body.rfind("onClick = function()", 0, index)
        self.assertNotEqual(start, -1, "the test button has no handler")
        block = body[start:index]
        self.assertTrue(
            "saveRule(rule)" in block,
            "the command is tested before the rule is saved: the text the user "
            "typed is lost when the panel is closed",
        )

    def test_a_rule_with_more_than_five_presses_shows_its_own_count(self):
        body = function_body(self.panel, "ruleCard")
        self.assertTrue(
            "pressOptions" in body,
            "the number of presses is fixed: a hand written rule with more "
            "than five presses is shown as 'any'",
        )
        self.assertTrue("table.insert" in body)


if __name__ == "__main__":
    unittest.main(verbosity=2)
