"""Error reporting: each failure the panel can hit maps to a specific code,
and the cases that can't be reproduced on hardware here keep the raw bytes."""
import errno
import io
import itertools
import json
import pathlib
import socket
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stdout
from unittest.mock import Mock, patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
import nothing_ear_ctl as ctl
import protocol as p
import sdp

ADDRESS = "AA:BB:CC:DD:EE:FF"


def closed_after(*chunks):
    """recv() results for a socket the buds close after sending `chunks`:
    a closed socket keeps returning b"" however often it's read."""
    return itertools.chain(chunks, itertools.repeat(b""))


def run_cli(*argv):
    out = io.StringIO()
    with patch.object(sys, "argv", ["nothing_ear_ctl.py", *argv]), redirect_stdout(out):
        ctl.main()
    return json.loads(out.getvalue())


class ErrorCodeTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = pathlib.Path(directory.name)
        for name, value in (
            ("CHANNEL_FILE", root / "channel"),
            ("STATE_FILE", root / "state.json"),
            ("LOCK_FILE", root / "lock"),
        ):
            patcher = patch.object(ctl, name, str(value))
            patcher.start()
            self.addCleanup(patcher.stop)
        # bluetoothctl knows nothing about the fake device
        patcher = patch.object(ctl, "_run", return_value="")
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_errno_codes(self):
        for exc, code in (
            (OSError(errno.ECONNREFUSED, "Connection refused"), "refused"),
            (OSError(errno.EHOSTDOWN, "Host is down"), "unreachable"),
            (OSError(errno.ETIMEDOUT, "timed out"), "timeout"),
            (socket.timeout("timed out"), "timeout"),
            (OSError(errno.EACCES, "Permission denied"), "permission"),
            (OSError(errno.EAFNOSUPPORT, "not supported"), "no_bt_support"),
            (OSError(errno.EIO, "I/O error"), "os_error"),
        ):
            with self.subTest(exc=exc):
                err = ctl.os_error(exc, "connect")
                self.assertEqual(err.code, code)
                if exc.errno is not None:
                    self.assertEqual(err.to_dict()["errno"], exc.errno)

    def test_python_without_bluetooth(self):
        # e.g. some Nix or uv-managed Pythons
        no_bluetooth = types.SimpleNamespace(timeout=socket.timeout)
        with patch.object(ctl, "socket", no_bluetooth):
            result = run_cli("status", "--mac", ADDRESS)
        self.assertEqual(result["error"], "no_bt_support")
        self.assertFalse(result["connected"])

    def test_service_not_advertised_keeps_sdp_reply(self):
        missing = sdp.ServiceNotFound("no RFCOMM channel", bytes.fromhex("07 00 01 00 05 00 02 35 00 00"))
        with patch.object(ctl, "resolve_rfcomm_channel", side_effect=missing):
            result = run_cli("status", "--mac", ADDRESS)
        self.assertEqual(result["error"], "no_service")
        self.assertEqual(result["stage"], "sdp")
        self.assertEqual(result["sdp_reply"], "07 00 01 00 05 00 02 35 00 00")

    def test_connect_refused_after_retry(self):
        sock = Mock()
        sock.connect.side_effect = OSError(errno.ECONNREFUSED, "Connection refused")
        with patch.object(ctl, "resolve_rfcomm_channel", return_value=16), patch.object(
            ctl.socket, "socket", return_value=sock
        ):
            result = run_cli("status", "--mac", ADDRESS)
        self.assertEqual(result["error"], "refused")
        self.assertEqual(result["stage"], "connect")
        self.assertEqual(result["channel"], 16)
        self.assertIn("channel 16", result["first_failure"])

    def test_unrecognised_reply_keeps_raw_bytes(self):
        # Answers in a framing this plugin doesn't parse.
        sock = Mock()
        sock.recv.side_effect = closed_after(bytes.fromhex("55 20 01 e0 01 00 00"))
        with patch.object(ctl, "resolve_rfcomm_channel", return_value=16), patch.object(
            ctl.socket, "socket", return_value=sock
        ):
            result = run_cli("status", "--mac", ADDRESS)
        self.assertEqual(result["error"], "no_response")
        self.assertEqual(result["reply"], "55 20 01 e0 01 00 00")

    def test_recognised_reply_is_connected(self):
        sock = Mock()
        frame = p.build_frame(p.BATTERY_RESP, bytes([0]), seq=1)
        sock.recv.side_effect = closed_after(frame)
        with patch.object(ctl, "resolve_rfcomm_channel", return_value=16), patch.object(
            ctl.socket, "socket", return_value=sock
        ), patch.object(ctl, "cached_model", return_value=ctl.m.describe("B155")):
            result = run_cli("status", "--mac", ADDRESS)
        self.assertTrue(result["connected"])

    def test_not_connected_skips_paging(self):
        with patch.object(ctl, "_run", return_value="Name: CMF Buds 2\nConnected: no"), patch.object(
            ctl, "resolve_rfcomm_channel"
        ) as resolve, patch.object(ctl.socket, "socket") as sock:
            result = run_cli("status", "--mac", ADDRESS)
        self.assertEqual(result["error"], "not_connected")
        resolve.assert_not_called()
        sock.assert_not_called()

    def test_unreachable_is_not_retried(self):
        sock = Mock()
        sock.connect.side_effect = OSError(errno.EHOSTDOWN, "Host is down")
        with patch.object(ctl, "resolve_rfcomm_channel", return_value=16) as resolve, patch.object(
            ctl.socket, "socket", return_value=sock
        ):
            result = run_cli("status", "--mac", ADDRESS)
        self.assertEqual(result["error"], "unreachable")
        self.assertEqual(sock.connect.call_count, 1)
        resolve.assert_called_once()

    def test_busy_lock_is_reported_on_stdout(self):
        with ctl.channel_lock():
            result = run_cli("status", "--mac", ADDRESS)
        self.assertEqual(result["error"], "busy")


class RefineTests(unittest.TestCase):
    def test_unreachable_split_by_what_bluez_reports(self):
        for show, info, code in (
            ("Powered: no", "Connected: no", "bt_off"),
            ("Powered: yes", "Connected: no", "not_connected"),
            ("Powered: yes", "Connected: yes", "unreachable"),
        ):
            with self.subTest(code=code):
                replies = {"show": show, "info": info}
                with patch.object(ctl, "_run", side_effect=lambda argv: replies[argv[1]]):
                    err = ctl.refine(ctl.CtlError("unreachable", "connect", "Host is down"), ADDRESS)
                self.assertEqual(err.code, code)

    def test_other_codes_untouched(self):
        with patch.object(ctl, "_run") as run:
            err = ctl.refine(ctl.CtlError("refused", "connect", "refused"), ADDRESS)
        self.assertEqual(err.code, "refused")
        run.assert_not_called()


class DiagnoseTests(unittest.TestCase):
    def test_report_masks_address_and_includes_failure(self):
        last = json.dumps({"error": "refused", "stage": "connect", "message": f"refused by {ADDRESS}"})
        with patch.object(ctl, "_run", return_value="Name: CMF Buds 2\nConnected: yes"), patch.object(
            ctl, "resolve_rfcomm_channel", return_value=16
        ), patch.object(ctl, "read_state", side_effect=ctl.CtlError("refused", "connect", "Connection refused")):
            text = ctl.diagnose(ADDRESS, last)["text"]
        self.assertNotIn(ADDRESS, text)
        self.assertIn("AA:BB:CC:xx:xx:xx", text)
        self.assertIn("refused at connect", text)
        self.assertIn("ok, channel 16", text)
        self.assertIn("Name: CMF Buds 2", text)


if __name__ == "__main__":
    unittest.main()
