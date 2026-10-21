"""Bounded public catalogue requests for NetEase and QQ Music."""

import base64
import binascii
import json
import re
import time
import unicodedata
import urllib.error
import urllib.parse


BROWSER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36"
QQ_RPC = "https://u.y.qq.com/cgi-bin/musicu.fcg"
QQ_SEARCH = "music.search.SearchCgiService"
VERSION = re.compile(r"(?<![a-z])(?:live|remix|instrumental|karaoke|cover|acoustic)(?![a-z])|现场|伴奏|翻唱", re.I)


def text(value):
    return str(value or "").strip()


def mapping(value):
    return value if isinstance(value, dict) else {}


def normalized(value):
    return "".join(c for c in unicodedata.normalize("NFKC", text(value)).casefold() if c.isalnum())


def track_duration(track):
    value = float(track.get("duration") or 0)
    return value / 1000 if value > 10_000_000 else value


def artist_names(value):
    if isinstance(value, list):
        return " / ".join(text(item.get("name")) if isinstance(item, dict) else text(item) for item in value)
    return text(value)


def versions(value):
    aliases = {"现场": "live", "伴奏": "instrumental", "karaoke": "instrumental", "翻唱": "cover"}
    return {aliases.get(item, item) for item in VERSION.findall(text(value).lower())}


def song_metadata(song, source):
    if source == "netease":
        album = song.get("al", song.get("album", {})) or {}
        album = album if isinstance(album, dict) else {}
        return {
            "id": text(song.get("id")), "title": song.get("name", ""),
            "artist": artist_names(song.get("ar", song.get("artists", []))),
            "album": album.get("name", ""),
            "duration": song.get("dt", song.get("duration", 0)),
            "cover": album.get("picUrl", album.get("blurPicUrl", "")),
        }
    album = song.get("album") if isinstance(song.get("album"), dict) else {}
    album_mid = text(album.get("mid") or song.get("albummid") or song.get("albumMid"))
    return {
        "id": text(song.get("id", song.get("songid"))),
        "mid": text(song.get("mid", song.get("songmid"))),
        "title": song.get("name", song.get("songname", song.get("title", ""))),
        "subtitle": song.get("subtitle", ""),
        "artist": artist_names(song.get("singer", [])),
        "album": album.get("name", song.get("albumname", "")),
        "duration": float(song.get("interval") or song.get("duration") or 0) * 1000,
        "cover": "https://y.gtimg.cn/music/photo_new/T002R300x300M000" + album_mid + ".jpg" if album_mid else "",
    }


def ranked_songs(songs, track, source):
    wanted_title = normalized(track.get("title"))
    wanted_artist = normalized(track.get("artist"))
    wanted_album = normalized(track.get("album"))
    wanted_version = versions(track.get("title"))
    wanted_duration = track_duration(track)
    ranked, seen = [], set()
    for index, raw in enumerate(songs if isinstance(songs, list) else []):
        if not isinstance(raw, dict):
            continue
        try:
            song = song_metadata(raw, source)
        except (ValueError, TypeError):
            continue
        identity = song.get("mid") or song["id"]
        if not identity or identity in seen:
            continue
        title, artist = normalized(song["title"]), normalized(song["artist"])
        if not wanted_title or not title:
            continue
        title_score = 6 if title == wanted_title else 3 if wanted_title in title or title in wanted_title else 0
        if not title_score:
            continue
        if wanted_artist and artist and wanted_artist not in artist and artist not in wanted_artist:
            # Multi-artist MPRIS metadata may use different separators from the catalogue.
            names = [normalized(part) for part in re.split(r"\s*[/;&、]\s*|\s+feat\.?\s+", text(track.get("artist")), flags=re.I)]
            if not any(name and name in artist for name in names):
                continue
        version = versions(text(song["title"]) + " " + text(song.get("subtitle")))
        if version != wanted_version:
            continue
        try:
            difference = abs(float(song["duration"] or 0) - wanted_duration) if wanted_duration and song["duration"] else float("inf")
        except (TypeError, ValueError):
            continue
        if difference != float("inf") and difference > max(20000, wanted_duration * 0.1):
            continue
        artist_score = 4 if wanted_artist and artist == wanted_artist else 2 if wanted_artist and artist else 0
        album_score = int(bool(wanted_album and normalized(song["album"]) == wanted_album))
        ranked.append((-title_score, -artist_score, difference // 5000, -album_score, difference, index, song))
        seen.add(identity)
    ranked.sort(key=lambda item: item[:-1])
    return [item[-1] for item in ranked[:3]]


def direct_song(track, source):
    url = text(track.get("mediaUrl"))
    parsed = urllib.parse.urlsplit(url)
    query = urllib.parse.parse_qs(parsed.query or urllib.parse.urlsplit(parsed.fragment).query)
    host = (parsed.hostname or "").lower()
    if source == "netease":
        if host == "music.163.com" and ("song" in parsed.path or "song" in parsed.fragment):
            song_id = (query.get("id") or [""])[0]
        elif parsed.scheme == "orpheus":
            match = re.search(r"song[:/](\d+)", url)
            song_id = match.group(1) if match else ""
        else:
            song_id = ""
        return {"id": song_id, "cover": ""} if re.fullmatch(r"[1-9]\d*", song_id) else None
    if host not in ("y.qq.com", "i.y.qq.com", "c.y.qq.com"):
        return None
    match = re.search(r"/(?:songDetail|song)/(\w+)", parsed.path)
    mid = (query.get("songmid") or query.get("mid") or [match.group(1) if match else ""])[0]
    return {"mid": mid, "id": "", "cover": ""} if re.fullmatch(r"[A-Za-z0-9]{14}", mid) else None


def decode_lyric(value):
    if not isinstance(value, str) or not value.strip():
        return ""
    value = value.strip()
    if value.startswith(("[", "<", "{")) or "\n" in value:
        return value
    try:
        return base64.b64decode(value, validate=True).decode("utf-8")
    except (binascii.Error, UnicodeError, ValueError):
        return value


class CatalogueClient:
    def __init__(self, request_json, source, budget=24):
        self.request_json = request_json
        self.source = source
        self.deadline = time.monotonic() + budget
        self.diag = []
        self.headers = {"User-Agent": BROWSER_AGENT, "Referer": "https://music.163.com/" if source == "netease" else "https://y.qq.com/"}

    def request(self, url, params=None, payload=None):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            return {}
        if params:
            url += "?" + urllib.parse.urlencode(params)
        headers = dict(self.headers)
        body = None
        if payload is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        try:
            result = self.request_json(url, headers, data=body, timeout=min(5, remaining))
            return result if isinstance(result, dict) else {}
        except urllib.error.HTTPError as error:
            self.diag.append("HTTP " + str(error.code))
        except (urllib.error.URLError, TimeoutError, OSError):
            self.diag.append("network failure")
        except (ValueError, UnicodeError):
            self.diag.append("invalid response")
        return {}

    def search(self, track):
        title = text(track.get("title"))
        queries = list(dict.fromkeys(filter(None, (title + " " + text(track.get("artist")), title))))
        for query in queries:
            if self.source == "netease":
                for endpoint in ("/api/cloudsearch/pc", "/api/search/get"):
                    result = self.request("https://music.163.com" + endpoint, {"s": query.strip(), "type": 1, "limit": 20, "offset": 0})
                    songs = mapping(result.get("result")).get("songs", []) if result.get("code") == 200 else []
                    ranked = ranked_songs(songs, track, self.source)
                    if ranked:
                        return ranked
            else:
                result = self.request(QQ_RPC, payload={QQ_SEARCH: {
                    "module": QQ_SEARCH, "method": "DoSearchForQQMusicDesktop",
                    "param": {"query": query.strip(), "num_per_page": 20, "page_num": 1, "search_type": 0},
                }})
                packet = mapping(result.get(QQ_SEARCH))
                songs = mapping(mapping(mapping(packet.get("data")).get("body")).get("song")).get("list", []) if result.get("code") == 0 and packet.get("code") == 0 else []
                ranked = ranked_songs(songs, track, self.source)
                if ranked:
                    return ranked
                result = self.request("https://c.y.qq.com/soso/fcgi-bin/client_search_cp", {"format": "json", "p": 1, "n": 20, "w": query.strip()})
                songs = mapping(mapping(result.get("data")).get("song")).get("list", []) if result.get("code") == 0 else []
                ranked = ranked_songs(songs, track, self.source)
                if ranked:
                    return ranked
        return []

    def lyric_responses(self, song):
        if self.source == "netease":
            for endpoint in ("/api/song/lyric/v1", "/api/song/lyric"):
                result = self.request("https://music.163.com" + endpoint, {
                    "id": song["id"], "cp": "false", "lv": 0, "kv": 0, "tv": 0, "rv": 0,
                    "yv": 0, "ytv": 0, "yrv": 0,
                })
                if result.get("code") == 200:
                    yield result
        else:
            param = {}
            if song.get("mid"):
                param["songMID"] = song["mid"]
            if song.get("id", "").isdigit():
                param["songID"] = int(song["id"])
            result = self.request(QQ_RPC, payload={"comm": {"ct": 24, "cv": 0}, "lyric": {
                "module": "music.musichallSong.PlayLyricInfo", "method": "GetPlayLyricInfo", "param": param,
            }})
            packet = mapping(result.get("lyric"))
            if result.get("code") == 0 and packet.get("code") == 0 and isinstance(packet.get("data"), dict):
                yield packet["data"]
            if song.get("mid"):
                result = self.request("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", {
                    "songmid": song["mid"], "format": "json", "nobase64": 1, "g_tk": 5381,
                })
                if result.get("code") == 0:
                    yield result
