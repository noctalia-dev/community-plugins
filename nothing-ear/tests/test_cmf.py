"""Newer CMF models: framing, model detection and the per-model reads. The
frames are real ones captured from a CMF Buds 2 Plus (posted in BudsLink's
issue tracker); CMF Buds 2 frames below are built from the same layouts."""
import itertools
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
import models as m
import nothing_ear_ctl as ctl
import protocol as p

ADDRESS = "AA:BB:CC:DD:EE:FF"

# CMF Buds 2 Plus, captured
MODEL_B184 = "55 60 01 1c 40 02 00 01 84 b1 52 ed"
BATTERY_REPLY = "55 60 01 07 40 05 00 02 02 02 64 03 64 32 ba"
ANC_PUSH = "55 20 01 03 e0 06 00 00 01 04 00 02 04 00 0f 54"
BATTERY_PUSH = "55 20 01 01 e0 05 00 00 02 03 5f 02 64 5b de"
BASS_PUSH = "55 20 01 4e 40 02 00 00 01 04 e2 0c"
EMPTY_REPLY = "55 60 01 1d 40 00 00 09 dd 1b"


def frames(*hexes):
    return p.FrameParser().feed(b"".join(bytes.fromhex(h) for h in hexes))


class FramingTests(unittest.TestCase):
    def test_pushes_are_parsed(self):
        got = {f.cmd: f.payload for f in frames(ANC_PUSH, BATTERY_PUSH, BASS_PUSH)}
        self.assertEqual(p.parse_anc(got[p.ANC_PUSH]), {"mode": "anc", "strength": "adaptive"})
        self.assertEqual(p.parse_battery(got[p.BATTERY_PUSH])["left"], {"level": 100, "charging": False})
        self.assertEqual(p.parse_bass(got[p.BASS_RESP]), {"enabled": True, "level": 2})

    def test_replies_and_pushes_mixed_in_one_read(self):
        got = [f.cmd for f in frames(MODEL_B184, ANC_PUSH, BATTERY_REPLY)]
        self.assertEqual(got, [p.MODEL_RESP, p.ANC_PUSH, p.BATTERY_RESP])

    def test_false_start_with_huge_length_is_skipped(self):
        got = [f.cmd for f in frames("55 60 01 00 00 ff ff", BATTERY_REPLY)]
        self.assertEqual(got, [p.BATTERY_RESP])

    def test_corrupt_frame_is_skipped(self):
        bad = ANC_PUSH[:-2] + "00"
        got = [f.cmd for f in frames(bad, BATTERY_REPLY)]
        self.assertEqual(got, [p.BATTERY_RESP])

    def test_empty_payload_parses_to_nothing(self):
        (frame,) = frames(EMPTY_REPLY)
        self.assertEqual(frame.payload, b"")
        for parse in (p.parse_battery, p.parse_anc, p.parse_eq_preset, p.parse_latency,
                      p.parse_personal_anc, p.parse_sound_profile, p.parse_bass, p.parse_model):
            with self.subTest(parse=parse.__name__):
                self.assertIsNone(parse(b""))

    def test_battery_count_longer_than_payload(self):
        self.assertEqual(p.parse_battery(bytes([3, 0x02, 0x50]))["left"], {"level": 80, "charging": False})


class ModelTests(unittest.TestCase):
    def test_model_id_is_little_endian(self):
        (frame,) = frames(MODEL_B184)
        self.assertEqual(p.parse_model(frame.payload), "B184")

    def test_cmf_buds_2(self):
        model = m.identify("B179")
        self.assertEqual(model["name"], "CMF Buds 2")
        self.assertEqual(model["eq"], "listening")
        self.assertTrue(model["bass"])
        self.assertIn({"index": 0, "name": "dirac"}, model["eq_presets"])

    def test_model_id_beats_serial(self):
        # The serial lookup misreads some newer models as an Ear (1).
        self.assertEqual(m.identify("B184", "SH0101xxxxxxxx")["base"], "B184")

    def test_fallbacks(self):
        self.assertEqual(m.identify(None, "SH1718xxxxxxxx")["base"], "B155")
        self.assertEqual(m.identify(None, None, "CMF Buds 2")["base"], "B179")
        unknown = m.identify("B999", None, "Some Headphones")
        self.assertIsNone(unknown["base"])
        self.assertEqual(unknown["eq"], "classic")

    def test_listening_model_without_table_hides_eq(self):
        self.assertIsNone(m.identify("B168")["eq"])


def build(cmd, payload, seq=1):
    return p.build_frame(cmd, bytes(payload), seq=seq)


# What a CMF Buds 2 answers to the model and serial reads; the read after it
# only goes out once this has arrived.
MODEL_B179 = build(p.MODEL_RESP, [0x79, 0xB1]) + build(p.SERIAL_RESP, [])


class ReadStateTests(unittest.TestCase):
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
        for patcher in (
            patch.object(ctl, "_run", return_value="Name: CMF Buds 2\nConnected: yes"),
            patch.object(ctl, "resolve_rfcomm_channel", return_value=16),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)

    def read(self, *chunks):
        sock = Mock()
        sock.recv.side_effect = itertools.chain(chunks, itertools.repeat(b""))
        with patch.object(ctl.socket, "socket", return_value=sock):
            state = ctl.read_state(ADDRESS)
        sent = [b[3] | b[4] << 8 for (b,), _ in sock.send.call_args_list]
        return state, sent

    def test_cmf_buds_2_unsupported_reads_dont_fail_the_poll(self):
        # What the reported CMF Buds 2 crash looked like: empty answers to
        # the personal ANC and sound profile reads it doesn't support.
        rest = b"".join([
            build(p.BATTERY_RESP, [3, 0x02, 0x64, 0x03, 0x5F, 0x04, 0x84]),
            build(p.ANC_RESP, [0x01, 0x05, 0x00]),
            build(p.FIRMWARE_RESP, b"1.0.1.52"),
            build(p.LATENCY_RESP, [0x02]),
            build(p.LISTENING_MODE_RESP, [0x03]),
            build(p.BASS_RESP, [0x01, 0x06]),
            build(p.PERSONAL_ANC_RESP, []),
            build(p.SOUND_PROFILE_RESP, []),
            build(p.SOUND_PROFILE_ID_RESP, []),
        ])
        state, sent = self.read(MODEL_B179, rest)
        self.assertEqual(state["model"]["base"], "B179")
        self.assertEqual(state["eq_preset"], 3)
        self.assertEqual(state["bass"], {"enabled": True, "level": 3})
        self.assertEqual(state["battery"]["case"], {"level": 4, "charging": True})
        self.assertNotIn("personal_anc", state)
        self.assertEqual(state["unparsed"], {"4020": ""})
        self.assertIn(p.LISTENING_MODE_READ, sent)
        self.assertNotIn(p.EQ_PRESET_READ, sent)

    def test_cached_model_skips_identification(self):
        self.read(MODEL_B179, build(p.BATTERY_RESP, [1, 0x02, 0x50]))
        _, sent = self.read(build(p.BATTERY_RESP, [1, 0x02, 0x50]))
        self.assertNotIn(p.MODEL_READ, sent)

    def test_other_device_is_identified_again(self):
        self.read(MODEL_B179, build(p.BATTERY_RESP, [1, 0x02, 0x50]))
        sock = Mock()
        sock.recv.side_effect = itertools.chain([MODEL_B179, build(p.BATTERY_RESP, [1, 0x02, 0x50])], itertools.repeat(b""))
        with patch.object(ctl.socket, "socket", return_value=sock):
            ctl.read_state("11:22:33:44:55:66")
        sent = [b[3] | b[4] << 8 for (b,), _ in sock.send.call_args_list]
        self.assertIn(p.MODEL_READ, sent)

    def test_bass_refused_on_model_without_it(self):
        with patch.object(ctl, "cached_model", return_value=m.describe("B155")):
            with self.assertRaises(ctl.CtlError) as caught:
                ctl.write_bass(ADDRESS, 3)
        self.assertEqual(caught.exception.code, "bad_value")

    def test_identify_ignores_cache(self):
        self.read(MODEL_B179, build(p.BATTERY_RESP, [1, 0x02, 0x50]))
        sock = Mock()
        sock.recv.side_effect = itertools.chain([MODEL_B179, build(p.BATTERY_RESP, [1, 0x02, 0x50])], itertools.repeat(b""))
        with patch.object(ctl.socket, "socket", return_value=sock):
            ctl.read_state(ADDRESS, identify=True)
        sent = [b[3] | b[4] << 8 for (b,), _ in sock.send.call_args_list]
        self.assertIn(p.MODEL_READ, sent)

    def test_battery_push_stands_in_for_reply(self):
        state, _ = self.read(MODEL_B179, bytes.fromhex(BATTERY_PUSH))
        self.assertEqual(state["battery"]["right"], {"level": 95, "charging": False})


if __name__ == "__main__":
    unittest.main()
