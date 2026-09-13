#!/usr/bin/env python3
"""Unit tests for the MDR V2 framing and parsing helpers in scripts/sony_ctl.py.

Run with:  python3 -m unittest discover -s tests -v
"""

import os
import sys
import unittest

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


if __name__ == "__main__":
    unittest.main()
