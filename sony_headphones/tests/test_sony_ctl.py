#!/usr/bin/env python3
"""Unit tests for the MDR V2 framing and parsing helpers in scripts/sony_ctl.py.

Run with:  python3 -m unittest discover -s tests -v
"""

import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

import sony_ctl as sc  # noqa: E402


class EscapeTests(unittest.TestCase):
    def test_escape_unescape_roundtrip(self):
        raw = bytes([0x00, 0x3C, 0x3D, 0x3E, 0xFF, 0x3E, 0x3D, 0x3C])
        self.assertEqual(sc._unescape(sc._escape(raw)), raw)

    def test_escape_maps_specials(self):
        self.assertEqual(sc._escape(b"\x3c"), b"\x3d\x2c")
        self.assertEqual(sc._escape(b"\x3d"), b"\x3d\x2d")
        self.assertEqual(sc._escape(b"\x3e"), b"\x3d\x2e")
        self.assertEqual(sc._escape(b"\x01"), b"\x01")


class FrameTests(unittest.TestCase):
    def test_pack_parse_roundtrip(self):
        payload = bytes([0x66, 0x17, 0x00, 0x3C, 0x3D, 0x3E, 0xAA])
        frame = sc.pack_frame(sc.TYPE_DATA, 0, payload)
        self.assertEqual(frame[0], 0x3E)
        self.assertEqual(frame[-1], 0x3C)

        frames, rest = sc.split_frames(bytearray(frame))
        self.assertEqual(rest, bytearray())
        self.assertEqual(len(frames), 1)

        parsed = sc.parse_frame(frames[0])
        self.assertIsNotNone(parsed)
        ftype, seq, out_payload = parsed
        self.assertEqual(ftype, sc.TYPE_DATA)
        self.assertEqual(seq, 0)
        self.assertEqual(out_payload, payload)

    def test_bad_checksum_rejected(self):
        frame = bytearray(sc.pack_frame(sc.TYPE_DATA, 1, b"\x01\x02"))
        frame[-2] ^= 0xFF  # corrupt the checksum, keep delimiters
        frames, _ = sc.split_frames(bytearray(frame))
        self.assertEqual(len(frames), 1)
        self.assertIsNone(sc.parse_frame(frames[0]))

    def test_split_frames_keeps_incomplete_tail(self):
        frame = sc.pack_frame(sc.TYPE_DATA, 0, b"\x10\x20")
        stream = bytearray(frame + frame[:5])
        frames, rest = sc.split_frames(stream)
        self.assertEqual(len(frames), 1)
        self.assertEqual(rest, bytearray(frame[:5]))


class PayloadTests(unittest.TestCase):
    def test_nc_payload_modes_and_subtype(self):
        off = sc._nc_payload(sc.MODE_OFF, 0, 0x17)
        anc = sc._nc_payload(sc.MODE_ANC, 0, 0x17)
        tr = sc._nc_payload(sc.MODE_TRANSPARENCY, 7, 0x19)

        self.assertEqual(off[0], 0x68)
        self.assertEqual(off[3], 0x00)
        self.assertEqual(anc[3], 0x01)
        self.assertEqual(anc[4], 0x00)
        self.assertEqual(tr[4], 0x01)
        self.assertEqual(tr[7], 7)
        self.assertEqual(tr[1], 0x19)

    def test_nc_payload_clamps_level_and_subtype(self):
        high = sc._nc_payload(sc.MODE_TRANSPARENCY, 999, 0x17)
        self.assertEqual(high[7], 20)
        low = sc._nc_payload(sc.MODE_TRANSPARENCY, -5, 0x17)
        self.assertEqual(low[7], 0)
        self.assertEqual(sc._nc_payload(sc.MODE_ANC, 0, 0x99)[1], 0x17)

    def test_parse_nc(self):
        anc = [(sc.TYPE_DATA, bytes([0x67, 0x17, 0x01, 0x01, 0x00, 0x02, 0x00]))]
        tr = [(sc.TYPE_DATA, bytes([0x69, 0x19, 0x01, 0x01, 0x01, 0x02, 0x00]))]
        off = [(sc.TYPE_DATA, bytes([0x67, 0x17, 0x01, 0x00, 0x00, 0x02, 0x00]))]

        self.assertEqual(sc._parse_nc(anc), (sc.MODE_ANC, 0x17))
        self.assertEqual(sc._parse_nc(tr), (sc.MODE_TRANSPARENCY, 0x19))
        self.assertEqual(sc._parse_nc(off), (sc.MODE_OFF, 0x17))
        self.assertEqual(sc._parse_nc([]), (None, None))

    def test_parse_battery(self):
        payloads = [(sc.TYPE_DATA, bytes([0x23, 0x00, 90, 1]))]
        self.assertEqual(sc._parse_battery(payloads), (90, True))
        self.assertEqual(sc._parse_battery([]), (None, False))


class ModelTests(unittest.TestCase):
    def test_canonical_model(self):
        self.assertEqual(sc._canonical_model("WH-1000XM5"), "WH-1000XM5")
        self.assertEqual(sc._canonical_model("LE_WH-1000XM4"), "WH-1000XM4")
        self.assertEqual(sc._canonical_model("1000X The Collexion"), "WH-1000XX")
        self.assertEqual(sc._canonical_model("1000X The Collection"), "WH-1000XX")
        self.assertEqual(sc._canonical_model("WH-1000XX/B"), "WH-1000XX")
        self.assertIsNone(sc._canonical_model("Some Random Speaker"))
        self.assertIsNone(sc._canonical_model(None))


class ProtocolGatingTests(unittest.TestCase):
    MAC = "AA:BB:CC:DD:EE:FF"

    def test_v1_models_are_detected(self):
        for name in ("WH-1000XM4", "LE_WH-1000XM3", "WH-1000XM2"):
            self.assertTrue(sc._is_v1_model(name), name)
        for name in ("WH-1000XM5", "WH-1000XM6", "WF-1000XM4", "LinkBuds S", "Sony Headphones", None):
            self.assertFalse(sc._is_v1_model(name), name)

    def test_query_device_skips_v2_handshake_for_xm4(self):
        with mock.patch.object(sc, "_load_cache", return_value={}), \
             mock.patch.object(sc, "bluez_device_name", return_value="WH-1000XM4"), \
             mock.patch.object(sc, "bluez_battery", return_value=87), \
             mock.patch.object(sc, "SonySession") as session_cls, \
             mock.patch.object(sc, "_save_cache"):
            state = sc.query_device(self.MAC)

        session_cls.assert_not_called()
        self.assertEqual(state["battery"], 87)
        self.assertEqual(state["model_name"], "WH-1000XM4")
        self.assertEqual(state["protocol"], "v1")
        self.assertFalse(state["noise_control"])
        self.assertTrue(state["connected"])

    def test_detect_protocol(self):
        self.assertEqual(sc.detect_protocol(sc.V1_UUID), "v1")
        self.assertEqual(sc.detect_protocol(sc.V2_UUID.upper()), "v2")
        self.assertIsNone(sc.detect_protocol(""))
        self.assertIsNone(sc.detect_protocol("Service Name: Something Else"))

    def test_query_device_skips_v2_when_sdp_advertises_v1(self):
        sdp = "Service Name: Serial HPC\n%s\n" % sc.V1_UUID
        with mock.patch.object(sc, "_load_cache", return_value={}), \
             mock.patch.object(sc, "bluez_device_name", return_value="Some Sony Headphones"), \
             mock.patch.object(sc, "browse_sdp", return_value=sdp), \
             mock.patch.object(sc, "bluez_battery", return_value=64), \
             mock.patch.object(sc, "SonySession") as session_cls, \
             mock.patch.object(sc, "_save_cache"):
            state = sc.query_device(self.MAC)

        session_cls.assert_not_called()
        self.assertEqual(state["battery"], 64)
        self.assertEqual(state["protocol"], "v1")
        self.assertFalse(state["noise_control"])

    def test_query_device_uses_v2_for_xm5(self):
        fake = mock.MagicMock()
        fake.open.return_value = True
        fake.transact.return_value = []
        sdp = "Service Name: Serial HPC\n%s\n" % sc.V2_UUID
        with mock.patch.object(sc, "_load_cache", return_value={}), \
             mock.patch.object(sc, "bluez_device_name", return_value="WH-1000XM5"), \
             mock.patch.object(sc, "browse_sdp", return_value=sdp), \
             mock.patch.object(sc, "bluez_battery", return_value=55), \
             mock.patch.object(sc, "resolve_channel", return_value=9), \
             mock.patch.object(sc, "SonySession", return_value=fake) as session_cls, \
             mock.patch.object(sc, "_save_cache"):
            state = sc.query_device(self.MAC)

        session_cls.assert_called_once()
        fake.open.assert_called_once()
        fake.close.assert_called_once()
        self.assertEqual(state["battery"], 55)
        self.assertEqual(state["model_name"], "WH-1000XM5")
        self.assertEqual(state["protocol"], "v2")
        self.assertTrue(state["noise_control"])

    def test_set_nc_mode_rejects_v1_without_opening_rfcomm(self):
        with mock.patch.object(sc, "_load_cache", return_value={}), \
             mock.patch.object(sc, "bluez_device_name", return_value="WH-1000XM4"), \
             mock.patch.object(sc, "SonySession") as session_cls, \
             mock.patch.object(sc, "_save_cache"):
            result = sc.set_nc_mode(self.MAC, sc.MODE_ANC)

        self.assertFalse(result["success"])
        self.assertIn("not supported", result["error"])
        session_cls.assert_not_called()

    def test_set_nc_mode_rejects_sdp_detected_v1(self):
        with mock.patch.object(sc, "_load_cache", return_value={}), \
             mock.patch.object(sc, "bluez_device_name", return_value="Some Sony Headphones"), \
             mock.patch.object(sc, "browse_sdp", return_value=sc.V1_UUID), \
             mock.patch.object(sc, "SonySession") as session_cls, \
             mock.patch.object(sc, "_save_cache"):
            result = sc.set_nc_mode(self.MAC, sc.MODE_ANC)

        self.assertFalse(result["success"])
        self.assertIn("not supported", result["error"])
        session_cls.assert_not_called()


if __name__ == "__main__":
    unittest.main()
