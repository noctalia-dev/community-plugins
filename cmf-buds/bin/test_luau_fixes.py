#!/usr/bin/env python3
"""Regression tests for the second round of the Luau review.

The daemon side is tested for real (Python); the Luau side is checked
against the source, because Python cannot import it: the contract of the
functions that were wrong is verified (the shape of the code, the
arguments of the calls).

Every test here describes a bug that was found in the review that
precedes the pull request.

Run with: python3 bin/test_luau_fixes.py
"""

import argparse
import ast
import inspect
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import budsctl

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as fh:
        return fh.read()


def contains(text, needle):
    """Whether the text holds the needle.

    The assertions of the Luau files use it: a failed assertIn would print
    the whole file.
    """
    return needle in text


def function_body(text, name):
    """The source of a function of a Luau file.

    The functions of the plugin are two-space indented, so the 'end' that
    closes them is the only one at the beginning of a line. Both the local
    and the global functions are found.
    """
    match = re.search(r"^(?:local )?function %s\(" % re.escape(name), text, re.M)
    if match is None:
        return ""
    rest = text[match.start() :]
    end = re.search(r"^end\s*$", rest, re.M)
    if end is None:
        return rest
    return rest[: end.end()]


def method_body(text, name):
    """The source of a method of a returned module (M.name) in a Luau file."""
    match = re.search(r"^function M\.%s\(" % re.escape(name), text, re.M)
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


def make_daemon(**overrides):
    directory = tempfile.mkdtemp(prefix="cmf-buds-luau-")
    values = {
        "state": os.path.join(directory, "state.json"),
        "socket": os.path.join(directory, "daemon.sock"),
        "log": os.path.join(directory, "daemon.log"),
        "poll": 20,
        "idle_timeout": 300,
        "device_mac": "",
        "device_name": "",
        "no_autostart": False,
    }
    values.update(overrides)
    args = argparse.Namespace(**values)
    daemon = budsctl.BudsDaemon(args)
    daemon.save = lambda: None
    return daemon


class DaemonTests(unittest.TestCase):
    """The daemon side of the findings."""

    def test_the_refresh_command_reconnects_without_the_backoff(self):
        daemon = make_daemon()
        daemon.link = None
        calls = {}

        def fake_connect(force_bt=False, user=False):
            calls["force_bt"] = force_bt
            calls["user"] = user
            return False

        daemon.connect = fake_connect
        daemon.handle_rpc({"cmd": "refresh"})
        self.assertTrue(
            calls.get("user"),
            "the manual refresh was blocked by the automatic backoff",
        )

    def test_a_failed_command_test_reports_the_code_and_the_detail(self):
        daemon = make_daemon()

        class FakeEngine:
            def run_command(self, command, wait=False, on_result=None, details=None):
                if details is not None:
                    details["returncode"] = 1
                    details["stderr"] = "no such file"
                return False

            def snapshot(self):
                return {}

        daemon.local = FakeEngine()
        response = daemon.handle_rpc({"cmd": "local_test", "command": "foo"})
        self.assertFalse(response["ok"], "the failed test reported success")
        self.assertEqual(response.get("error"), "command_failed")
        self.assertIn("no such file", response.get("error_detail", ""))

    def test_the_engine_reports_the_exit_status_of_the_command(self):
        daemon = make_daemon()
        # The real engine: it runs the command and reports what happened.
        response = daemon.handle_rpc({"cmd": "local_test", "command": "exit 3"})
        self.assertFalse(response["ok"])
        self.assertEqual(response.get("error"), "command_failed")
        self.assertIn("3", response.get("error_detail", ""))

    def test_the_volume_writes_are_serialized(self):
        daemon = make_daemon()
        daemon.link = FakeLink()
        daemon.local = types.SimpleNamespace(note_self_change=lambda value: None)
        events = []
        guard = threading.Lock()

        def fake_run(cmd, timeout=10):
            with guard:
                events.append("start")
            time.sleep(0.05)
            with guard:
                events.append("end")
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")

        with mock.patch.object(budsctl, "run", side_effect=fake_run):
            with mock.patch.object(daemon, "_sink", return_value="sink"):
                with mock.patch.object(daemon, "refresh_volume", return_value={}):
                    threads = [
                        threading.Thread(target=daemon.set_volume, args=(50,))
                        for _ in range(2)
                    ]
                    for thread in threads:
                        thread.start()
                    for thread in threads:
                        thread.join(5)
        pairs = list(zip(events[0::2], events[1::2]))
        self.assertEqual(len(pairs), 2, "the volume was not written twice")
        for first, second in zip(pairs, pairs[1:]):
            self.assertNotEqual(
                (first[1], second[0]),
                ("start", "start"),
                "two volume writes overlapped",
            )

    def test_the_stop_waits_for_the_daemon_to_release_the_socket(self):
        directory = tempfile.mkdtemp(prefix="cmf-buds-stop-")
        socket_path = os.path.join(directory, "daemon.sock")
        with open(socket_path, "w", encoding="utf-8") as fh:
            fh.write("")

        def release():
            time.sleep(0.2)
            try:
                os.unlink(socket_path)
            except OSError:
                pass

        thread = threading.Thread(target=release)
        thread.start()
        self.assertTrue(
            budsctl.wait_for_daemon_exit(socket_path, timeout=3.0),
            "the stop did not wait for the daemon to exit",
        )
        thread.join(5)

    def test_the_stop_gives_up_when_the_daemon_does_not_exit(self):
        directory = tempfile.mkdtemp(prefix="cmf-buds-stop-")
        socket_path = os.path.join(directory, "daemon.sock")
        with open(socket_path, "w", encoding="utf-8") as fh:
            fh.write("")
        self.assertFalse(
            budsctl.wait_for_daemon_exit(socket_path, timeout=0.3),
            "the stop reported an exit that never happened",
        )

    def test_the_rpc_does_not_start_the_daemon_when_the_autostart_is_off(self):
        daemon = make_daemon(no_autostart=True)
        paths = {
            "state": daemon.state_path,
            "socket": daemon.socket_path,
            "log": daemon.log_path,
        }
        with mock.patch.object(budsctl, "ensure_daemon") as ensure:
            response = budsctl.rpc_request(daemon.args, paths, {"cmd": "ping"})
        ensure.assert_not_called()
        self.assertFalse(response.get("ok"))

    def test_the_cli_accepts_the_no_autostart_flag(self):
        parser = budsctl.build_parser()
        args = parser.parse_args(["rpc", "--no-autostart"])
        self.assertTrue(args.no_autostart)
        self.assertFalse(parser.parse_args(["rpc"]).no_autostart)


class LuauContractTests(unittest.TestCase):
    """The Luau side of the findings (checked against the source)."""

    def setUp(self):
        self.panel = read("lib", "panel_ui.luau")
        self.widget = read("widget.luau")
        self.service = read("service.luau")
        self.common = read("lib", "common.luau")

    def test_a_deleted_rule_is_not_saved_again(self):
        body = function_body(self.panel, "removeRule")
        self.assertTrue(
            contains(body, "pendingCommands[tostring(id)] = nil"),
            "a deleted rule could be saved again when the panel is closed",
        )

    def test_the_service_restarts_the_daemon_after_the_stop(self):
        body = function_body(self.service, "onConfigChanged")
        self.assertTrue(
            contains(body, "stopDaemon(function()"),
            "the daemon was started while the old one still held the lock",
        )
        self.assertTrue(contains(body, "startDaemon()"))

    def test_the_service_passes_the_configuration_to_the_daemon(self):
        for argument in ('"--poll"', '"--device-mac"', '"--device-name"'):
            self.assertTrue(
                contains(self.service, argument), "%s is missing" % argument
            )

    def test_the_service_does_not_resurrect_the_daemon(self):
        self.assertTrue(
            contains(self.service, '"--no-autostart"'),
            "the service can start a daemon after the plugin was disabled",
        )

    def test_the_service_restarts_the_daemon_when_the_ping_does_not_answer(self):
        body = function_body(self.service, "ping")
        self.assertTrue(
            contains(body, "json.decode"),
            "the ping does not read the answer of the daemon",
        )
        self.assertTrue(
            contains(body, "data.ok"),
            "the ping does not check whether the daemon answered",
        )
        self.assertFalse(
            contains(body, "exitCode"),
            "the ping only checks the exit code, which is always zero",
        )

    def test_the_widget_coalesces_the_volume_of_the_wheel(self):
        self.assertTrue(
            contains(self.widget, "volumeInFlight"),
            "the wheel starts one request per event",
        )
        body = function_body(self.widget, "onScroll")
        self.assertFalse(
            contains(body, 'rpc({ cmd = "volume"'),
            "the wheel sends the volume without coalescing the events",
        )

    def test_the_widget_has_no_unused_fonts(self):
        self.assertFalse(contains(self.widget, "loadFonts"))
        self.assertFalse(contains(self.widget, "batteryValue"))

    def test_the_widget_only_redraws_when_the_state_changed(self):
        # update() runs every second and redrawing the bar rebuilt the whole
        # node tree even when the daemon had published the same state.
        body = function_body(self.widget, "update")
        self.assertTrue(
            contains(body, "changed"),
            "the widget redraws the bar on every tick",
        )
        self.assertTrue(
            contains(function_body(self.widget, "readState"), ", false"),
            "readState does not tell an unchanged state apart",
        )

    def test_the_service_only_sends_the_configuration_when_it_is_needed(self):
        # The service sent `configure` every round, which is one more python3
        # process per 20 s for values the daemon already had.
        self.assertTrue(
            contains(self.service, "configPayload()"),
            "the configuration payload is not built in one place",
        )
        body = function_body(self.service, "needsConfigure")
        self.assertTrue(
            contains(body, "lastPayload") and contains(body, "pid"),
            "the configuration is sent without checking whether it changed",
        )
        self.assertTrue(
            contains(function_body(self.service, "update"), "ping()"),
            "the round no longer asks the daemon how it is doing",
        )
        self.assertFalse(
            contains(function_body(self.service, "update"), "configureDaemon()"),
            "the round still sends the configuration unconditionally",
        )

    def test_the_cli_does_not_import_the_shortcut_engine(self):
        # The engine, subprocess and traceback are only used by the daemon:
        # importing them on every RPC call cost about 50 ms of the ~100 ms
        # the process lives.
        source = read("bin", "budsctl.py")
        self.assertNotRegex(
            source,
            r"(?m)^import subprocess$",
            "subprocess is imported on every call, the RPC path does not use it",
        )
        self.assertNotRegex(
            source,
            r"(?m)^import traceback$",
            "traceback is imported on every call, the RPC path does not use it",
        )
        # Checked in a fresh interpreter: another test may already have
        # loaded the engine in this one.
        probe = subprocess.run(
            [
                sys.executable,
                "-c",
                "import sys, budsctl; "
                "print('local_actions' in sys.modules, "
                "'subprocess' in sys.modules, budsctl.LocalActionEngine)",
            ],
            cwd=os.path.join(ROOT, "bin"),
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(probe.returncode, 0, probe.stderr)
        self.assertEqual(
            probe.stdout.split(),
            ["False", "False", "None"],
            "loading the CLI pulls in the modules only the daemon needs",
        )
        engine, error = budsctl.local_engine_class()
        self.assertIsNotNone(engine, "the engine is not importable: %s" % (error,))

    def test_the_daemon_publishes_a_volume_moved_by_another_application(self):
        # The panel and the bar read state.json now, so the monitor has to
        # write the volume it reads instead of keeping it in memory only.
        self.assertIn("publish", inspect.getsource(budsctl.BudsDaemon.refresh_volume))
        monitor = inspect.getsource(budsctl.BudsDaemon.monitor)
        self.assertIn("refresh_volume(publish=True)", monitor)

    def test_the_panel_has_no_unused_font_or_animation(self):
        self.assertFalse(contains(self.panel, "grotesk"))
        self.assertIsNone(
            re.search(r"\banim\b", self.panel),
            "the animation state of the panel is never used",
        )

    def test_a_late_frame_tick_does_not_rearm_the_closed_panel(self):
        # With the panel closed, a frame tick queued before the close called
        # setNeedsFrameTick(true) again: the host kept ticking forever and
        # the plugin polled the daemon at 2 Hz with no panel to show it.
        body = method_body(self.panel, "onFrameTick")
        self.assertTrue(
            contains(body, "if closed then"),
            "a late frame tick re-arms the tick after the panel was closed",
        )
        self.assertTrue(
            contains(body, "return"),
            "the guard of the frame tick does not stop the function",
        )
        self.assertTrue(
            contains(method_body(self.panel, "update"), "if closed then"),
            "update() keeps polling the daemon after the panel was closed",
        )

    def test_an_unknown_shortcut_value_shows_itself_and_not_a_key(self):
        self.assertTrue(contains(self.common, "function M.trOr("))
        self.assertTrue(contains(self.panel, "C.trOr("))

    def test_the_knob_watcher_is_declared(self):
        manifest = read("plugin.toml")
        self.assertIn("dbus-monitor", manifest)
        self.assertIn("dbus-monitor", read("README.md"))

    def test_the_daemon_server_runs_before_python_312(self):
        # `socketserver.ThreadingUnixStreamServer` only exists from Python
        # 3.12: on Debian 12 (3.11) or Ubuntu 22.04 (3.10) the daemon died at
        # start-up with an AttributeError and the plugin did nothing.
        import socketserver

        self.assertIs(
            budsctl._threading_unix_server(),
            getattr(socketserver, "ThreadingUnixStreamServer", None),
            "the server class of the interpreter is not the one used",
        )
        saved = socketserver.ThreadingUnixStreamServer
        del socketserver.ThreadingUnixStreamServer
        try:
            server = budsctl._threading_unix_server()
        finally:
            socketserver.ThreadingUnixStreamServer = saved
        self.assertTrue(issubclass(server, socketserver.ThreadingMixIn))
        self.assertTrue(issubclass(server, socketserver.UnixStreamServer))
        self.assertTrue(server.daemon_threads)

    def test_the_python_sources_parse_as_python_38(self):
        # The plugin runs on the `python3` of the distribution: the syntax
        # has to stay valid on the oldest interpreter the README promises.
        for name in ("budsctl.py", "local_actions.py"):
            source = read("bin", name)
            try:
                ast.parse(source, filename=name, feature_version=(3, 8))
            except SyntaxError as exc:  # pragma: no cover - the test fails
                self.fail("%s is not valid Python 3.8: %s" % (name, exc))

    def test_the_engine_has_no_unused_state(self):
        engine = read("bin", "local_actions.py")
        self.assertFalse(contains(engine, "notify_enabled"))

    def test_the_error_codes_are_the_same_in_the_two_languages(self):
        with open(
            os.path.join(ROOT, "translations", "en.json"), encoding="utf-8"
        ) as fh:
            english = json.load(fh)
        with open(
            os.path.join(ROOT, "translations", "es.json"), encoding="utf-8"
        ) as fh:
            spanish = json.load(fh)
        self.assertEqual(set(english["error"]["code"]), set(spanish["error"]["code"]))
        self.assertIn("command_failed", english["error"]["code"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
