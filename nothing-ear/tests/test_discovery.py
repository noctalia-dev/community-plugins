"""Discovery regressions; simulated SDP replies are not hardware captures."""
import pathlib
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import Mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
import nothing_ear_ctl as ctl
import sdp


class DiscoveryTests(unittest.TestCase):
    def test_channel_from_server_honoring_attribute_range(self):
        # A server honoring the requested attribute range returns protocol
        # descriptors only if attribute 0x0004 falls inside that range.
        for channel in (15, 16):
            with self.subTest(channel=channel):
                class Server:
                    def settimeout(self, value): pass
                    def connect(self, address): pass
                    def close(self): pass
                    def send(self, request):
                        self.request = request
                        return len(request)
                    def recv(self, size):
                        start, end = struct.unpack(">HH", self.request[-5:-1])
                        handle = bytes.fromhex("09 00 00 0a 00 01 00 01")
                        protocols = bytes.fromhex(
                            "09 00 04 35 0c 35 03 19 01 00 35 05 19 00 03 08"
                        ) + bytes([channel])
                        attrs = handle + (protocols if start <= 4 <= end else b"")
                        record = bytes([0x35, len(attrs)]) + attrs
                        records = bytes([0x35, len(record)]) + record
                        body = len(records).to_bytes(2, "big") + records + b"\x00"
                        return b"\x07\x00\x01" + len(body).to_bytes(2, "big") + body

                with patch.object(sdp.socket, "socket", return_value=Server()):
                    self.assertEqual(sdp.resolve_rfcomm_channel("AA:BB:CC:DD:EE:FF", ctl.SPP_UUID), channel)

    def test_cache_hit_and_miss(self):
        address = "AA:BB:CC:DD:EE:FF"
        with tempfile.TemporaryDirectory() as directory:
            cache = pathlib.Path(directory) / "channel"
            with patch.object(ctl, "CHANNEL_FILE", str(cache)):
                for contents, expected_calls in (
                    (address + ":16", 0),
                    ("11:22:33:44:55:66:15", 1),
                    ("corrupt", 1),
                    (address + ":invalid", 1),
                    (address + ":0", 1),
                    (address + ":31", 1),
                ):
                    with self.subTest(contents=contents):
                        cache.write_text(contents)
                        with patch.object(ctl, "resolve_rfcomm_channel", return_value=16) as resolve:
                            self.assertEqual(ctl.get_channel(address), 16)
                            self.assertEqual(resolve.call_count, expected_calls)
                cache.unlink()
                with patch.object(ctl, "resolve_rfcomm_channel", return_value=16) as resolve:
                    self.assertEqual(ctl.get_channel(address), 16)
                    self.assertEqual(ctl.get_channel(address), 16)
                    resolve.assert_called_once_with(address, ctl.SPP_UUID)

    def test_stale_cached_channel_is_rediscovered(self):
        address = "AA:BB:CC:DD:EE:FF"
        with tempfile.TemporaryDirectory() as directory:
            cache = pathlib.Path(directory) / "channel"
            cache.write_text(address + ":15")
            failed, sock = Mock(), Mock()
            failed.connect.side_effect = ConnectionRefusedError()
            with patch.object(ctl, "CHANNEL_FILE", str(cache)), \
                 patch.object(ctl.socket, "socket", side_effect=[failed, sock]), \
                 patch.object(ctl, "resolve_rfcomm_channel", return_value=16) as resolve:
                self.assertIs(ctl.connect(address), sock)
                failed.connect.assert_called_once_with((address, 15))
                failed.close.assert_called_once()
                sock.connect.assert_called_once_with((address, 16))
                sock.close.assert_not_called()
                resolve.assert_called_once_with(address, ctl.SPP_UUID)
                self.assertEqual(cache.read_text(), address + ":16")

    def test_failed_retry_closes_both_sockets(self):
        first, second = Mock(), Mock()
        for sock in (first, second):
            sock.connect.side_effect = ConnectionRefusedError()
        with patch.object(ctl, "get_channel", return_value=16), \
             patch.object(ctl.os.path, "exists", return_value=False), \
             patch.object(ctl.socket, "socket", side_effect=[first, second]):
            with self.assertRaises(ConnectionRefusedError):
                ctl.connect("AA:BB:CC:DD:EE:FF")
        first.close.assert_called_once()
        second.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
