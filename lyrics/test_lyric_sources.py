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
