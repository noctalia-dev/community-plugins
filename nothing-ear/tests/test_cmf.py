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

    def test_headphone_name_fallbacks(self):
        for name in ("CMF Headphone Pro", "CMF Headphones Pro", " cmf headphone pro "):
            self.assertEqual(m.identify(bt_name=name)["base"], "B175")
        self.assertEqual(m.identify("B175", "SH0101xxxxxxxx")["base"], "B175")
        headphones = m.describe("B175")
        self.assertEqual(headphones["eq"], "listening")
        self.assertEqual([preset["name"] for preset in headphones["eq_presets"]],
                         ["pop", "rock", "electronic", "enhance_vocals", "classical", "custom"])
        self.assertFalse(headphones["bass"])
        self.assertEqual(headphones["spatial"], ["concert", "cinema", "off"])
        self.assertEqual(headphones["codecs"], ["aac", "ldac"])
        self.assertEqual(m.identify(serial="SH0101xxxxxxxx", bt_name="CMF Headphone Pro")["base"], "B175")

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
            ("LAST_WRITE_FILE", root / "last_write.json"),
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

    HEADPHONES = build(p.MODEL_RESP, [0x75, 0xB1]) + build(p.SERIAL_RESP, [])

    def test_headphones_read(self):
        # Synthetic B175 packets from ear-web's layouts, not a capture.
        state, sent = self.read(
            self.HEADPHONES,
            build(p.BATTERY_RESP, [1, 0x06, 0xD0]) + build(p.LISTENING_MODE_RESP, [3]) +
            build(p.SPATIAL_RESP, [2, 0]) + build(p.CODEC_RESP, [2]),
        )
        self.assertEqual(state["model"]["base"], "B175")
        self.assertEqual(state["battery"]["single"], {"level": 80, "charging": True})
        self.assertIsNone(state["battery"]["left"])
        self.assertEqual(state["eq_preset"], 3)
        self.assertEqual(state["spatial"], "concert")
        self.assertEqual(state["codec"], "ldac")
        self.assertNotIn("bass", state)
        for cmd in (p.LISTENING_MODE_READ, p.SPATIAL_READ, p.CODEC_READ):
            self.assertIn(cmd, sent)
        for cmd in (p.EQ_PRESET_READ, p.BASS_READ, p.PERSONAL_ANC_READ, p.SOUND_PROFILE_READ):
            self.assertNotIn(cmd, sent)

    def test_headphones_unknown_spatial_and_codec_are_hidden_and_recorded(self):
        # Head tracking, a mode outside the model's list, a codec it lacks.
        for spatial, codec in (([1, 1], [1]), ([4, 0], [9]), ([], [])):
            with self.subTest(spatial=spatial, codec=codec):
                state, _ = self.read(
                    self.HEADPHONES,
                    build(p.BATTERY_RESP, [1, 6, 50]) + build(p.SPATIAL_RESP, spatial) + build(p.CODEC_RESP, codec),
                )
                self.assertNotIn("spatial", state)
                self.assertNotIn("codec", state)
                self.assertEqual(set(state["unparsed"]), {"404f", "4029"})

    def test_headphones_without_spatial_or_codec_reply_still_read(self):
        state, _ = self.read(self.HEADPHONES, build(p.BATTERY_RESP, [1, 6, 50]))
        self.assertTrue(state["connected"])
        self.assertNotIn("spatial", state)
        self.assertNotIn("unparsed", state)

    def test_headphone_controls_use_documented_wire_payloads(self):
        self.read(self.HEADPHONES, build(p.BATTERY_RESP, [1, 6, 50]))
        for action, args, command, payload in (
            (ctl.write_eq, (3,), 0xF01D, [3, 0]),
            (ctl.write_spatial, ("concert",), 0xF052, [2, 0]),
            (ctl.write_spatial, ("cinema",), 0xF052, [3, 0]),
            (ctl.write_spatial, ("off",), 0xF052, [0, 0]),
            (ctl.write_codec, ("ldac",), 0xF01C, [2]),
            (ctl.write_codec, ("aac",), 0xF01C, [0]),
            (ctl.write_latency, (True,), 0xF040, [1, 0]),
            (ctl.write_latency, (False,), 0xF040, [2, 0]),
            (ctl.write_anc, ("anc", "low"), 0xF00F, [1, 3, 0]),
            (ctl.write_anc, ("transparency", None), 0xF00F, [1, 7, 0]),
            (ctl.write_custom_eq, ("3,0,-3",), 0xF041, bytes.fromhex(
                "03000040c00100000000000075443333333f02000040c000c05a450000803f"
                "000000404000000c43cdcc4c3f000000000000000000")),
        ):
            with self.subTest(action=action.__name__, args=args):
                sent = self.write(action, *args)
                writes = [frame for frame in sent if frame[3] | frame[4] << 8 == command]
                self.assertEqual(len(writes), 1)
                self.assertEqual(writes[0][5], len(payload))
                self.assertEqual(writes[0][8:-2], bytes(payload))

    def write(self, action, *args):
        sock = Mock()
        with patch.object(ctl, "connect", return_value=sock), patch.object(ctl, "gather", return_value={}), \
                patch.object(ctl.time, "sleep"):
            action(ADDRESS, *args)
        return [b for (b,), _ in sock.send.call_args_list]

    def test_spatial_and_codec_writes_follow_an_app_session(self):
        # Time write before the setting, numbered frames, setting sent last
        # among the writes.
        self.read(self.HEADPHONES, build(p.BATTERY_RESP, [1, 6, 50]))
        for action, value, command in ((ctl.write_spatial, "cinema", p.SPATIAL_WRITE),
                                       (ctl.write_codec, "ldac", p.CODEC_WRITE)):
            with self.subTest(action=action.__name__):
                sent = self.write(action, value)
                cmds = [b[3] | b[4] << 8 for b in sent]
                self.assertEqual(cmds[0], p.BATTERY_READ)
                self.assertLess(cmds.index(p.TIME_WRITE), cmds.index(command))
                self.assertEqual([b[7] for b in sent], list(range(1, len(sent) + 1)))

    def test_custom_eq_read_and_bad_values(self):
        curve = p.custom_eq_write_payload(-2, 4, 6, m.CUSTOM_EQ_BANDS["B175"])
        state, sent = self.read(self.HEADPHONES, build(p.BATTERY_RESP, [1, 6, 50]) + build(p.CUSTOM_EQ_RESP, curve))
        self.assertIn(p.CUSTOM_EQ_READ, sent)
        self.assertEqual(state["custom_eq"], {"bass": -2, "mid": 4, "treble": 6})
        for value in ("7,0,0", "1,2", "a,b,c", None):
            with self.subTest(value=value), patch.object(ctl, "connect") as connect:
                with self.assertRaises(ctl.CtlError):
                    ctl.write_custom_eq(ADDRESS, value)
                connect.assert_not_called()

    def test_failed_write_is_recorded_for_diag(self):
        self.read(self.HEADPHONES, build(p.BATTERY_RESP, [1, 6, 50]))
        sock = Mock()
        sock.send.side_effect = [None, OSError(104, "Connection reset by peer")]
        with patch.object(ctl, "connect", return_value=sock), patch.object(ctl, "gather", return_value={}), \
                patch.object(ctl.time, "sleep"), self.assertRaises(ctl.CtlError):
            ctl.write_spatial(ADDRESS, "concert")
        text = "\n".join(f"{k} {v}" for k, v in ctl.last_write_rows())
        self.assertIn("set-spatial", text)
        self.assertIn("unreachable", text)
        self.assertIn("tx 55 60 01 07 c0", text)

    def readback(self, action, value, replies):
        """Runs a write whose read-backs answer `replies` in turn."""
        sock = Mock()
        answers = iter(replies)

        def gather(_sock, wait_cmds, **_kw):
            if p.SPATIAL_RESP in wait_cmds:
                reply = next(answers)
                return {p.SPATIAL_RESP: p.Frame(p.SPATIAL_RESP, 1, bytes(reply))} if reply is not None else {}
            return {}

        with patch.object(ctl, "connect", return_value=sock), patch.object(ctl, "gather", side_effect=gather), \
                patch.object(ctl.time, "sleep"):
            return action(ADDRESS, value)

    def test_write_the_headphones_ignore_fails_as_not_applied(self):
        self.read(self.HEADPHONES, build(p.BATTERY_RESP, [1, 6, 50]))
        with self.assertRaises(ctl.CtlError) as caught:
            self.readback(ctl.write_spatial, "cinema", [[2, 0], [2, 0]])
        self.assertEqual(caught.exception.code, "not_applied")
        text = "\n".join(f"{k} {v}" for k, v in ctl.last_write_rows())
        self.assertIn("not_applied", text)
        self.assertIn("tx 55 60 01 52 f0", text)

    def test_write_applied_late_or_unread_still_succeeds(self):
        self.read(self.HEADPHONES, build(p.BATTERY_RESP, [1, 6, 50]))
        self.assertEqual(self.readback(ctl.write_spatial, "cinema", [[2, 0], [3, 0]]),
                         {"ok": True, "spatial": "cinema"})
        self.assertEqual(self.readback(ctl.write_spatial, "cinema", [None]), {"ok": True})

    def test_recent_writes_are_kept_newest_first(self):
        self.read(self.HEADPHONES, build(p.BATTERY_RESP, [1, 6, 50]))
        for preset in (3, 1, 2, 4, 5, 6, 3):
            self.write(ctl.write_eq, preset)
        self.write(ctl.write_spatial, "off")
        heads = [v for k, v in ctl.last_write_rows() if k == "write"]
        self.assertEqual(len(heads), ctl.WRITES_KEPT)
        self.assertTrue(heads[0].startswith("set-spatial"))
        self.assertIn("ms)", heads[0])

    def test_headphone_writes_outside_the_model_are_refused(self):
        self.read(self.HEADPHONES, build(p.BATTERY_RESP, [1, 6, 50]))
        for action, args in (
            (ctl.write_bass, (3,)),
            (ctl.write_eq, (0,)),
            (ctl.write_spatial, ("game",)),
            (ctl.write_codec, ("lhdc",)),
        ):
            with self.subTest(action=action.__name__), patch.object(ctl, "connect") as connect:
                with self.assertRaises(ctl.CtlError):
                    action(ADDRESS, *args)
                connect.assert_not_called()

    def test_codec_switch_reports_restart_without_reading_back(self):
        self.read(self.HEADPHONES, build(p.BATTERY_RESP, [1, 6, 50]))
        sock = Mock()
        with patch.object(ctl, "connect", return_value=sock), patch.object(ctl, "gather", return_value={}), \
                patch.object(ctl.time, "sleep"):
            self.assertEqual(ctl.write_codec(ADDRESS, "ldac"), {"ok": True, "restarting": True})
        cmds = [b[3] | b[4] << 8 for (b,), _ in sock.send.call_args_list]
        self.assertEqual(cmds[-1], p.CODEC_WRITE)

    def test_earbuds_have_no_spatial_or_codec(self):
        _, sent = self.read(MODEL_B179, build(p.BATTERY_RESP, [1, 0x02, 0x50]))
        self.assertNotIn(p.SPATIAL_READ, sent)
        self.assertNotIn(p.CODEC_READ, sent)
        with self.assertRaises(ctl.CtlError):
            ctl.write_spatial(ADDRESS, "concert")

    def test_single_battery_push_and_unknown_ids(self):
        state, _ = self.read(build(p.MODEL_RESP, [0x75, 0xB1]) + build(p.SERIAL_RESP, []),
                             build(p.BATTERY_PUSH, [2, 0x99, 100, 6, 0]))
        self.assertEqual(state["battery"]["single"], {"level": 0, "charging": False})

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
