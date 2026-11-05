#!/usr/bin/env python3

import unittest
from unittest import mock
import urllib.error

import lyric_sources


class LrclibAdapterTest(unittest.TestCase):
    def setUp(self):
        self.track = {
            "title": "Can't Stop",
            "artist": "Red Hot Chili Peppers",
            "album": "By the Way",
            "duration": 269_000_000,
        }
        self.results = [
            {
                "id": 10,
                "trackName": "Can't Stop",
                "artistName": "Red Hot Chili Peppers",
                "albumName": "By the Way",
                "duration": 269,
                "plainLyrics": "Plain line",
                "syncedLyrics": "",
            },
            {
                "id": 20,
                "trackName": "Can't Stop",
                "artistName": "Red Hot Chili Peppers",
                "albumName": "By the Way",
                "duration": 269,
                "plainLyrics": "Synced line",
                "syncedLyrics": "[00:01.00]Synced line",
            },
        ]

    @mock.patch("lyric_sources.itunes_cover", return_value="")
    @mock.patch("lyric_sources.request_json")
    def test_prefers_synced_candidate_and_returns_metadata(self, request_json, _itunes_cover):
        request_json.return_value = self.results

        result = lyric_sources.adapter_lrclib(self.track, {}, {})

        self.assertEqual(result["selected_candidate_id"], "20")
        self.assertEqual(result["lines"][0]["time"], 1000)
        self.assertEqual([item["id"] for item in result["candidates"]], ["20", "10"])
        self.assertNotIn("plainLyrics", result["candidates"][0])
        self.assertTrue(result["candidates"][0]["synced"])

    @mock.patch("lyric_sources.itunes_cover", return_value="")
    @mock.patch("lyric_sources.request_json")
    def test_honors_requested_candidate(self, request_json, _itunes_cover):
        request_json.return_value = self.results

        result = lyric_sources.adapter_lrclib(
            self.track, {}, {"lyrics_candidate_id": "10"}
        )

        self.assertEqual(result["selected_candidate_id"], "10")
        self.assertEqual(result["lines"][0]["time"], -1)
        self.assertEqual(result["lines"][0]["text"], "Plain line")

    @mock.patch("lyric_sources.request_json")
    def test_rejects_stale_requested_candidate(self, request_json):
        request_json.return_value = self.results

        result = lyric_sources.adapter_lrclib(
            self.track, {}, {"lyrics_candidate_id": "missing"}
        )

        self.assertEqual(result["type"], "none")
        self.assertEqual(result["diag"], ["lrclib: requested match unavailable"])

    def test_rejects_wrong_artist_even_when_synced(self):
        results = [
            {
                "id": 30,
                "trackName": "Can't Stop",
                "artistName": "Unrelated Artist",
                "duration": 269,
                "syncedLyrics": "[00:01.00]Wrong",
            },
            self.results[0],
        ]

        ranked = lyric_sources.lrclib_candidates(results, self.track)

        self.assertEqual([item["id"] for item in ranked], [10])

    def test_prefers_duration_bucket_before_sync_status(self):
        results = [
            {
                "id": 30,
                "trackName": "Can't Stop",
                "artistName": "Red Hot Chili Peppers",
                "albumName": "By the Way",
                "duration": 400,
                "syncedLyrics": "[00:01.00]Wrong version",
            },
            self.results[0],
        ]

        ranked = lyric_sources.lrclib_candidates(results, self.track)

        self.assertEqual([item["id"] for item in ranked], [10, 30])

    def test_filters_missing_and_duplicate_candidate_ids(self):
        duplicate = dict(self.results[1])
        duplicate["plainLyrics"] = "Duplicate"
        missing = dict(self.results[0])
        missing.pop("id")

        ranked = lyric_sources.lrclib_candidates(
            [missing, self.results[1], duplicate], self.track
        )

        self.assertEqual([item["id"] for item in ranked], [20])


class SPlayerLinesTest(unittest.TestCase):
    def test_preserves_timing_layers_and_markers(self):
        lines = lyric_sources.splayer_transmitted_lines({
            "duration": 5000,
            "yrcData": [{
                "startTime": 1000,
                "endTime": 3000,
                "translatedLyric": "Hello",
                "isBG": True,
                "isDuet": True,
                "words": [
                    {"word": "A", "startTime": 1000, "endTime": 1500, "romanWord": "ay"},
                    {"word": "B", "startTime": 1500, "endTime": 2000, "romanWord": "bee"},
                ],
            }],
        })

        self.assertEqual(lines[0]["text"], "AB")
        self.assertEqual(lines[0]["translation"], "Hello")
        self.assertEqual(lines[0]["romanization"], "ay bee")
        self.assertEqual(lines[0]["chars"], [1000, 1500])
        self.assertTrue(lines[0]["is_background"])
        self.assertTrue(lines[0]["is_duet"])
        self.assertEqual(lines[0]["words"][1]["end"], 2000)

    def test_falls_back_to_lrc_when_yrc_is_invalid(self):
        lines = lyric_sources.splayer_transmitted_lines({
            "yrcData": [{"unexpected": "value"}],
            "lrcData": [{"startTime": 2000, "endTime": 3000, "text": "fallback"}],
        })

        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["text"], "fallback")

    def test_single_word_line_is_not_word_timed(self):
        lines = lyric_sources.splayer_transmitted_lines({
            "yrcData": [{
                "startTime": 1000,
                "endTime": 3000,
                "words": [{"word": "hello", "startTime": 1000, "endTime": 3000}],
            }],
        })

        self.assertEqual(lines[0]["text"], "hello")
        self.assertEqual(lines[0]["chars"], [])

    def test_marks_stretched_single_word_as_inferred(self):
        lines = lyric_sources.splayer_transmitted_lines({
            "yrcData": [
                {
                    "startTime": 1000,
                    "endTime": 9000,
                    "words": [{"word": "line", "startTime": 1000, "endTime": 9000}],
                },
                {"startTime": 9000, "endTime": 10000, "text": "next"},
            ],
        })

        self.assertTrue(lines[0]["duration_inferred"])
        self.assertEqual(lines[0]["chars"], [])


class MusixmatchParserTest(unittest.TestCase):
    def test_removes_duplicate_subtitle_entries(self):
        lines = lyric_sources.dedupe_timed_lines(lyric_sources.parse_lrc(
            "[00:01.00]First\n[00:01.00]  first  \n[00:01.00]Second\n"
        ))

        self.assertEqual(
            [(item["time"], item["text"]) for item in lines],
            [(1000, "First")],
        )


class SPlayerAdapterTest(unittest.TestCase):
    @mock.patch("lyric_sources.time.sleep")
    @mock.patch("lyric_sources.request_json")
    def test_unavailable_api_uses_bounded_retries(self, request_json, sleep):
        request_json.side_effect = urllib.error.URLError("offline")

        result = lyric_sources.adapter_splayer(
            {"title": "Song", "artist": "Artist"},
            {"splayer_api_url": "http://127.0.0.1:25884"},
            {},
        )

        self.assertEqual(result["type"], "none")
        self.assertEqual(result["diag"], ["splayer: API unavailable"])
        self.assertEqual(request_json.call_count, 3)
        request_json.assert_called_with(
            "http://127.0.0.1:25884/api/control/song-info", timeout=1
        )
        self.assertEqual(sleep.call_count, 2)

    @mock.patch("lyric_sources.request_json")
    def test_matches_title_suffix_and_artist_list(self, request_json):
        request_json.return_value = {"data": {
            "name": "Song (Live)",
            "artists": [{"name": "Artist"}],
            "lrcData": [{"startTime": 0, "endTime": 1000, "text": "line"}],
        }}

        result = lyric_sources.adapter_splayer(
            {"title": "Song", "artist": "Artist"},
            {"splayer_api_url": "http://127.0.0.1:25884"},
            {},
        )

        self.assertEqual(result["type"], "lyrics")


class MetadataFilterTest(unittest.TestCase):
    def test_removes_credit_lines_in_several_languages(self):
        samples = [
            "作词 : 周杰伦",
            "词版权管理方：北京梦织音传媒有限公司",
            "录音作品及MV版权：EAS MUSIC LTD",
            "Lyrics by Diane Warren",
            "Music & Lyrics by Someone",
            "Written and composed by Someone",
            "Provided to YouTube by Label",
            "Songwriters: A, B",
            "Produced by Rick Rubin",
            "© 2023 Label",
            "作詞：某人",
            "작사: 누군가",
            "纯音乐，请欣赏",
        ]

        for sample in samples:
            self.assertTrue(lyric_sources.is_metadata_line(sample), sample)

    def test_keeps_real_lyric_lines(self):
        samples = [
            "作曲家的名字",
            "我写的歌词",
            "Guitar solo",
            "You are my music",
            "词不达意",
            "歌曲之王",
        ]

        for sample in samples:
            self.assertFalse(lyric_sources.is_metadata_line(sample), sample)

    def test_filters_yrc_credit_lines_but_keeps_sung_lines(self):
        payload = {"yrc": {"lyric": (
            '{"t":0,"c":[{"tx":"作词: "}]}\n'
            "[1,2000](1,200,0)词(200,200,0)版(400,200,0)权(600,200,0)管(800,200,0)理(1000,200,0)方(1200,200,0)：(1400,200,0)某(1600,200,0)司\n"
            "[5000,3000](5000,300,0)你(5300,300,0)好(5600,300,0)啊"
        )}}

        lines, format_name = lyric_sources.provider_lines_with_format(payload, "netease")

        self.assertEqual(format_name, "yrc")
        self.assertEqual([line["text"] for line in lines], ["你好啊"])

    def test_net_ease_lrc_fallback_is_used_when_yrc_is_absent(self):
        payload = {
            "lrc": {"lyric": "[00:01.00]第一句\n[00:03.00]第二句"},
            "klyric": {"lyric": ""},
        }

        lines, format_name = lyric_sources.provider_lines_with_format(payload, "netease")

        self.assertEqual(format_name, "lrc")
        self.assertEqual([line["text"] for line in lines], ["第一句", "第二句"])


class WordTimingValidationTest(unittest.TestCase):
    def test_drops_misaligned_char_timings(self):
        item = lyric_sources.line(0, 1000, "abc", chars=[1, 2])

        self.assertEqual(item["chars"], [])

    def test_drops_decreasing_char_timings(self):
        item = lyric_sources.line(0, 1000, "abc", chars=[3, 2, 1])

        self.assertEqual(item["chars"], [])

    def test_keeps_complete_char_timings(self):
        item = lyric_sources.line(0, 1000, "abc", chars=[100, 200, 300])

        self.assertEqual(item["chars"], [100, 200, 300])


class LyricQualityTest(unittest.TestCase):
    def test_reports_word_line_and_plain(self):
        word = [
            {"time": i * 1000, "duration": 900, "text": "ab",
             "chars": [i * 1000, i * 1000 + 300],
             "translation": "", "romanization": ""}
            for i in range(1, 5)
        ]
        self.assertEqual(lyric_sources.lyrics_quality(word)["sync"], "word")

        line_only = [dict(item, chars=[]) for item in word]
        self.assertEqual(lyric_sources.lyrics_quality(line_only)["sync"], "line")

        plain = [{"time": -1, "duration": 0, "text": "a", "chars": [],
                  "translation": "", "romanization": ""}]
        self.assertEqual(lyric_sources.lyrics_quality(plain)["sync"], "plain")

    def test_reports_translation_and_coverage(self):
        lines = [
            {"time": 1000, "duration": 500, "text": "ab", "chars": [1000, 1200],
             "translation": "译", "romanization": ""},
            {"time": 2000, "duration": 500, "text": "cd", "chars": [],
             "translation": "", "romanization": ""},
        ]

        stats = lyric_sources.lyrics_quality(lines)

        self.assertEqual(stats["word_lines"], 1)
        self.assertEqual(stats["timed_lines"], 2)
        self.assertEqual(stats["coverage"], 0.5)
        self.assertTrue(stats["has_translation"])
        self.assertFalse(stats["has_romanization"])


class FormatPriorityTest(unittest.TestCase):
    def test_global_chain_reorders_source_formats(self):
        order = lyric_sources.source_format_order("netease", {
            "format_priority": ["lrc", "yrc"],
        })

        self.assertEqual(order[:2], ["lrc", "yrc"])

    def test_per_source_override_wins(self):
        order = lyric_sources.source_format_order("netease", {
            "format_priority": ["yrc", "lrc"],
            "source_format_priority": {"netease": ["lrc", "yrc"]},
        })

        self.assertEqual(order[:2], ["lrc", "yrc"])

    def test_unsupported_formats_are_skipped(self):
        order = lyric_sources.source_format_order("lrclib", {
            "format_priority": ["yrc", "qrc", "lrc"],
        })

        self.assertNotIn("yrc", order)
        self.assertNotIn("qrc", order)
        self.assertIn("lrc", order)


class ProviderTranslationLayersTest(unittest.TestCase):
    def test_merges_partial_and_full_translation_layers(self):
        payload = {
            "yrc": {"lyric": "[1000,1000](1000,500,0)A\n[3000,1000](3000,500,0)B"},
            "ytlrc": {"lyric": "[00:01.00]甲"},
            "tlyric": {"lyric": "[00:01.00]甲\n[00:03.00]乙"},
        }

        lines, format_name = lyric_sources.provider_lines_with_format(payload, "netease", {})

        self.assertEqual(format_name, "yrc")
        self.assertEqual([item["translation"] for item in lines], ["甲", "乙"])


class TranslationMergeTest(unittest.TestCase):
    def test_pairs_equal_length_layers_by_order_when_times_drift(self):
        primary = [
            {"time": 1000, "text": "a", "translation": "", "romanization": ""},
            {"time": 3000, "text": "b", "translation": "", "romanization": ""},
            {"time": 5000, "text": "c", "translation": "", "romanization": ""},
        ]
        secondary = [
            {"time": 1900, "text": "甲", "translation": "", "romanization": ""},
            {"time": 3900, "text": "乙", "translation": "", "romanization": ""},
            {"time": 5900, "text": "丙", "translation": "", "romanization": ""},
        ]

        lyric_sources.merge_timed(primary, secondary, "translation")

        self.assertEqual([item["translation"] for item in primary], ["甲", "乙", "丙"])


class SPlayerNextAdapterTest(unittest.TestCase):
    def setUp(self):
        self.track = {"title": "Song", "artist": "Artist", "duration": 200_000}
        self.now_playing = {"track": {
            "title": "Song",
            "artists": [{"name": "Artist"}],
            "album": {"name": "Album", "cover": "https://example.test/cover.jpg"},
            "duration": 200_000,
        }}
        self.lyrics = {"lyric": [{
            "startTime": 1000,
            "endTime": 3000,
            "translatedLyric": "译",
            "isBG": False,
            "isDuet": False,
            "words": [
                {"word": "A", "startTime": 1000, "endTime": 1500},
                {"word": "B", "startTime": 1500, "endTime": 2000},
            ],
        }]}

    @mock.patch("lyric_sources.request_json")
    def test_parses_amll_word_timings(self, request_json):
        request_json.side_effect = [self.now_playing, self.lyrics]

        result = lyric_sources.adapter_splayer_next(
            self.track, {"splayer_next_api_url": "http://127.0.0.1:14558"}, {}
        )

        self.assertEqual(result["type"], "lyrics")
        self.assertEqual(result["format"], "yrc")
        self.assertEqual(result["sync"], "line")
        self.assertEqual(result["lines"][0]["text"], "AB")
        self.assertEqual(result["lines"][0]["chars"], [1000, 1500])
        self.assertEqual(result["lines"][0]["translation"], "译")
        self.assertEqual(result["cover"], "https://example.test/cover.jpg")
        self.assertEqual(request_json.call_args_list[0].args[0], "http://127.0.0.1:14558/api/now-playing")
        self.assertEqual(request_json.call_args_list[1].args[0], "http://127.0.0.1:14558/api/lyrics")

    @mock.patch("lyric_sources.request_json")
    def test_line_level_lyrics_do_not_synthesize_char_timings(self, request_json):
        request_json.side_effect = [self.now_playing, {
            "source": {"source": "online", "format": "lrc", "platform": "netease", "wordTimed": False},
            "lyric": [{
                "startTime": 1000,
                "endTime": 3000,
                "translatedLyric": "译",
                "words": [{"word": "hello", "startTime": 1000, "endTime": 3000}],
            }],
        }]

        result = lyric_sources.adapter_splayer_next(self.track, {}, {})

        self.assertEqual(result["type"], "lyrics")
        self.assertEqual(result["format"], "lrc")
        self.assertEqual(result["sync"], "line")
        self.assertEqual(result["lines"][0]["chars"], [])
        self.assertIn("splayer_next: wordTimed=false", result["diag"])

    @mock.patch("lyric_sources.request_json")
    def test_enriches_missing_layers_from_netease_by_track_id(self, request_json):
        request_json.side_effect = [
            self.now_playing,
            {
                "trackId": "123",
                "source": {"source": "online", "format": "yrc", "platform": "netease", "wordTimed": True},
                "lyric": [
                    {"startTime": 1000, "endTime": 2000, "translatedLyric": "", "romanLyric": "",
                     "words": [{"word": "A", "startTime": 1000, "endTime": 1500},
                               {"word": "B", "startTime": 1500, "endTime": 2000}]},
                    {"startTime": 3000, "endTime": 4000, "translatedLyric": "", "romanLyric": "",
                     "words": [{"word": "C", "startTime": 3000, "endTime": 3500},
                               {"word": "D", "startTime": 3500, "endTime": 4000}]},
                ],
            },
            {
                "yrc": {"lyric": "[1000,2000](1000,500,0)A(1500,500,0)B\n[3000,2000](3000,500,0)C(3500,500,0)D"},
                "tlyric": {"lyric": "[00:01.00]译一\n[00:03.00]译二"},
                "romalrc": {"lyric": ""},
            },
        ]

        result = lyric_sources.adapter_splayer_next(self.track, {}, {})

        self.assertEqual(result["type"], "lyrics")
        self.assertEqual([item["translation"] for item in result["lines"]], ["译一", "译二"])
        self.assertIn("splayer_next: netease layers +2", result["diag"])
        self.assertIn("/api/song/lyric/v1", request_json.call_args_list[2].args[0])

    @mock.patch("lyric_sources.request_json")
    def test_rejects_other_current_track(self, request_json):
        request_json.return_value = {"track": {"title": "Other", "artists": [{"name": "Someone"}]}}

        result = lyric_sources.adapter_splayer_next(self.track, {}, {})

        self.assertEqual(result["type"], "none")
        self.assertEqual(result["diag"], ["splayer_next: track not ready"])
        self.assertEqual(request_json.call_count, 1)

    @mock.patch("lyric_sources.request_json")
    def test_reports_disabled_external_api(self, request_json):
        request_json.side_effect = urllib.error.HTTPError(
            "http://127.0.0.1:14558/api/now-playing", 403, "Forbidden", None, None
        )

        result = lyric_sources.adapter_splayer_next(self.track, {}, {})

        self.assertEqual(result["type"], "none")
        self.assertIn("external API disabled", result["diag"][0])

    @mock.patch("lyric_sources.request_json")
    def test_falls_back_when_no_lyrics(self, request_json):
        request_json.side_effect = [self.now_playing, {"lyric": []}]

        result = lyric_sources.adapter_splayer_next(self.track, {}, {})

        self.assertEqual(result["type"], "none")
        self.assertEqual(result["diag"], ["splayer_next: lyrics unavailable"])


if __name__ == "__main__":
    unittest.main()
