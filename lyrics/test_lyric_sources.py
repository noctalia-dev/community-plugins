#!/usr/bin/env python3

import unittest
from unittest import mock
import urllib.error

import lyric_sources


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


if __name__ == "__main__":
    unittest.main()
