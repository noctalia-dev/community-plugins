import base64
import json
import unittest
import urllib.error
from unittest import mock

import lyric_sources as lyrics
import music_sources as sources


TRACK = {"title": "晴天", "artist": "周杰伦", "album": "叶惠美", "duration": 269_000_000}
NCM_SONG = {"id": 123, "name": "晴天", "ar": [{"name": "周杰伦"}], "dt": 269000,
            "al": {"name": "叶惠美", "picUrl": "https://example.test/cover.jpg"}}
QQ_SONG = {"id": 97773, "mid": "0039MnYb0qxYhV", "name": "晴天", "interval": 269,
           "singer": [{"name": "周杰伦"}], "album": {"name": "叶惠美", "mid": "000MkMni19ClKG"}}


class CatalogueMatchingTest(unittest.TestCase):
    def test_rejects_other_artist_and_live_version(self):
        wrong = {**QQ_SONG, "id": 2, "mid": "wrong", "singer": [{"name": "别人"}]}
        live = {**QQ_SONG, "id": 3, "mid": "live", "subtitle": "Live"}
        result = sources.ranked_songs([wrong, live, QQ_SONG], TRACK, "qqmusic")
        self.assertEqual([song["id"] for song in result], ["97773"])

    def test_prefers_duration_over_album(self):
        wrong = {**NCM_SONG, "id": 2, "dt": 289000}
        right = {**NCM_SONG, "al": {"name": "精选集"}}
        result = sources.ranked_songs([wrong, right], TRACK, "netease")
        self.assertEqual(result[0]["id"], "123")

    def test_recognizes_catalogue_artist_alias(self):
        song = {**NCM_SONG, "ar": [{"name": "周杰伦(Jay Chou)"}]}
        self.assertEqual(len(sources.ranked_songs([song], TRACK, "netease")), 1)

    def test_rejects_large_duration_mismatch(self):
        song = {**NCM_SONG, "dt": 400000}
        self.assertEqual(sources.ranked_songs([song], TRACK, "netease"), [])

    def test_uses_only_provider_scoped_media_urls(self):
        for url in ("https://music.163.com/song?id=123", "https://music.163.com/#/song?id=123", "orpheus://song/123"):
            self.assertEqual(sources.direct_song({"mediaUrl": url}, "netease")["id"], "123")
        self.assertIsNone(sources.direct_song({"mediaUrl": "https://example.com/song?id=123"}, "netease"))
        self.assertEqual(sources.direct_song({"mediaUrl": "https://y.qq.com/n/ryqq/songDetail/0039MnYb0qxYhV"}, "qqmusic")["mid"], QQ_SONG["mid"])


class ProviderParsingTest(unittest.TestCase):
    def test_yrc_absolute_words_offset_and_layers(self):
        result = lyrics.provider_lines({
            "yrc": {"lyric": "[offset:200]\n[1000,1000](1000,400,0)你(1400,600,0)好"},
            "ytlrc": {"lyric": "[00:01.20]Hello"},
            "yromalrc": {"lyric": "[00:01.20]ni hao"},
        }, "netease")
        self.assertEqual(result[0]["text"], "你好")
        self.assertEqual(result[0]["chars"], [1200, 1600])
        self.assertEqual(result[0]["translation"], "Hello")
        self.assertEqual(result[0]["romanization"], "ni hao")

    def test_qrc_xml_base64_and_relative_word_timing(self):
        qrc = '<QrcInfos><LyricInfo><Lyric_1 LyricContent="[1000,1000]你(1000,400)好(1400,600)"/></LyricInfo></QrcInfos>'
        result = lyrics.provider_lines({"qrc": base64.b64encode(qrc.encode()).decode()}, "qqmusic")
        self.assertEqual(result[0]["chars"], [1000, 1400])
        self.assertEqual(result[0]["text"], "你好")

    def test_numeric_qrc_flag_falls_back_to_base64_lrc(self):
        result = lyrics.provider_lines({"qrc": 0, "lyric": base64.b64encode(b"[00:01.00]hello").decode()}, "qqmusic")
        self.assertEqual(result[0]["text"], "hello")

    def test_trims_timing_with_visible_text(self):
        result = lyrics.parse_lrc("[1000,1000](1000,300,0) (1300,300,0)A(1600,400,0) ")
        self.assertEqual(result[0]["text"], "A")
        self.assertEqual(result[0]["chars"], [1300])

    def test_metadata_and_html_are_not_lyrics(self):
        for payload in ("<html>unavailable</html>", "[ar:Artist]\n[ti:Title]"):
            self.assertEqual(lyrics.provider_lines({"lyric": payload}, "qqmusic"), [])

    @mock.patch("lyric_sources.request_data")
    def test_jsonp_callback_and_semicolon(self, request):
        request.return_value = (b'\xef\xbb\xbfMusicJsonCallback({"code":0});', "utf-8")
        self.assertEqual(lyrics.request_json("https://example.test"), {"code": 0})


class ProviderRequestsTest(unittest.TestCase):
    @mock.patch("lyric_sources.request_json")
    def test_malformed_netease_envelope_uses_fallback(self, request):
        request.side_effect = [{"code": 200, "result": []},
                               {"code": 200, "result": {"songs": [NCM_SONG]}},
                               {"code": 200, "lrc": {"lyric": "[00:01]fallback"}}]
        self.assertEqual(lyrics.adapter_netease(TRACK, {}, {})["type"], "lyrics")

    @mock.patch("lyric_sources.itunes_cover", return_value="")
    @mock.patch("lyric_sources.request_json")
    def test_keeps_installed_musixmatch_deduplication(self, request, _cover):
        request.return_value = {"subtitle_body": "[00:01]Line\n[00:01]Line\n[00:02]Next"}
        result = lyrics.adapter_musixmatch(TRACK, {"musixmatch_token": "test-token"}, {})
        self.assertEqual([item["text"] for item in result["lines"]], ["Line", "Next"])

    @mock.patch("lyric_sources.request_json")
    def test_netease_modern_search_and_lyric(self, request):
        request.side_effect = [{"code": 200, "result": {"songs": [NCM_SONG]}},
                               {"code": 200, "lrc": {"lyric": "[00:01]hello"}}]
        result = lyrics.adapter_netease(TRACK, {}, {})
        self.assertEqual(result["type"], "lyrics")
        self.assertIn("/api/cloudsearch/pc", request.call_args_list[0].args[0])
        self.assertIn("/api/song/lyric/v1", request.call_args_list[1].args[0])

    @mock.patch("lyric_sources.request_json")
    def test_netease_empty_first_candidate_tries_next(self, request):
        request.side_effect = [{"code": 200, "result": {"songs": [NCM_SONG, {**NCM_SONG, "id": 124}]}},
                               {"code": 200}, {"code": 200},
                               {"code": 200, "lrc": {"lyric": "[00:01]next match"}}]
        self.assertEqual(lyrics.adapter_netease(TRACK, {}, {})["lines"][0]["text"], "next match")

    @mock.patch("lyric_sources.request_json")
    def test_netease_direct_id_skips_search(self, request):
        request.return_value = {"code": 200, "lrc": {"lyric": "[00:01]direct"}}
        result = lyrics.adapter_netease({**TRACK, "mediaUrl": "https://music.163.com/song?id=123"}, {}, {})
        self.assertEqual(result["lines"][0]["text"], "direct")
        self.assertEqual(request.call_count, 1)

    @mock.patch("lyric_sources.request_json")
    def test_netease_endpoint_failure_falls_back(self, request):
        request.side_effect = [urllib.error.URLError("offline"),
                               {"code": 200, "result": {"songs": [NCM_SONG]}},
                               {"code": 403}, {"code": 200, "lrc": {"lyric": "[00:01]fallback"}}]
        self.assertEqual(lyrics.adapter_netease(TRACK, {}, {})["type"], "lyrics")

    @mock.patch("lyric_sources.request_json")
    def test_qq_desktop_search_and_musicu_lyrics(self, request):
        request.side_effect = [{"code": 0, sources.QQ_SEARCH: {"code": 0, "data": {"body": {"song": {"list": [QQ_SONG]}}}}},
                               {"code": 0, "lyric": {"code": 0, "data": {"lyric": "[00:01]hello"}}}]
        self.assertEqual(lyrics.adapter_qqmusic(TRACK, {}, {})["type"], "lyrics")
        payload = json.loads(request.call_args_list[0].kwargs["data"])
        self.assertEqual(payload[sources.QQ_SEARCH]["method"], "DoSearchForQQMusicDesktop")
        self.assertNotIn("comm", payload)

    @mock.patch("lyric_sources.request_json")
    def test_qq_old_response_shape_and_lyric_fallback(self, request):
        old = {"songid": 97773, "songmid": QQ_SONG["mid"], "songname": "晴天", "interval": 269,
               "singer": QQ_SONG["singer"], "albummid": "album", "albumname": "叶惠美"}
        request.side_effect = [{"code": 500}, {"code": 0, "data": {"song": {"list": [old]}}},
                               {"code": 0, "lyric": {"code": 1}}, {"code": 0, "lyric": "[00:01]old"}]
        self.assertEqual(lyrics.adapter_qqmusic(TRACK, {}, {})["lines"][0]["text"], "old")

    @mock.patch("lyric_sources.request_json")
    def test_total_deadline_prevents_more_network_calls(self, request):
        client = sources.CatalogueClient(request, "netease", budget=-1)
        self.assertEqual(client.search(TRACK), [])
        self.assertEqual(list(client.lyric_responses({"id": "123"})), [])
        request.assert_not_called()

    @mock.patch("lyric_sources.request_json", side_effect=urllib.error.URLError("secret URL"))
    def test_source_errors_remain_recoverable_and_sanitized(self, request):
        result = lyrics.adapter_qqmusic(TRACK, {}, {})
        self.assertEqual(result["type"], "none")
        self.assertNotIn("secret", str(result["diag"]))
        self.assertLessEqual(request.call_count, 4)


if __name__ == "__main__":
    unittest.main()
