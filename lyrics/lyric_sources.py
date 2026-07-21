#!/usr/bin/env python3
"""Standalone, standard-library lyric source adapter for the Noctalia plugin."""

import base64
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


USER_AGENT = "Noctalia-Lyrics/1.0"
TIME_TAG = re.compile(r"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]")
KRC_LINE = re.compile(r"^\[(\d+),(\d+)\](.*)$")
PREFIX_WORD = re.compile(r"(?:<|\()(\d+),(\d+)(?:,\d+)?(?:>|\))([^<(]*)")
SUFFIX_WORD = re.compile(r"(.*?)<(\d+),(\d+)(?:,\d+)?>")
QRC_SUFFIX_WORD = re.compile(r"(.*?)[(](\d+),(\d+)[)]")
ENHANCED_WORD = re.compile(r"<(?:(\d+):)?(\d{1,2}(?:[.:]\d{1,3})?)>([^<]*)")
META_TAG = re.compile(r"^\[(ar|al|ti|by|re|ve|length|offset):", re.I)
CREDIT_LINE = re.compile(r"^(词|曲|作词|作曲|编曲|制作人|lyricist|composer|arranger)\s*[:：]", re.I)


def empty(source, *diag):
    return {"type": "none", "source": source, "lines": [], "diag": list(diag)}


def clean_text(value):
    if value is None:
        return ""
    return html.unescape(str(value)).replace("\ufeff", "").strip()


def number(value, default=0):
    try:
        return int(float(value))
    except (TypeError, ValueError, OverflowError):
        return default


def normalize(value):
    return "".join(c.lower() for c in clean_text(value) if c.isalnum())


def timestamp_ms(minutes, seconds):
    seconds = str(seconds).replace(":", ".")
    return int(round(number(minutes) * 60000 + float(seconds) * 1000))


def duration_ms(value):
    value = number(value, 0)
    if value <= 0:
        return 0
    # Track duration is commonly milliseconds, but MPRIS callers may send microseconds.
    return value // 1000 if value > 10_000_000 else value


def line(time=-1, duration=0, text="", translation="", romanization="", chars=None):
    return {
        "time": number(time, -1),
        "duration": max(0, number(duration)),
        "text": clean_text(text),
        "translation": clean_text(translation),
        "romanization": clean_text(romanization),
        "chars": [number(item) for item in (chars or [])],
    }


def splayer_transmitted_lines(data):
    if not isinstance(data, dict):
        return []

    def parse_lines(source_lines):
        if not isinstance(source_lines, list):
            return []
        result = []
        for line_index, source_line in enumerate(source_lines):
            if not isinstance(source_line, dict):
                continue
            start = number(source_line.get("startTime"), -1)
            end = number(source_line.get("endTime"), start)
            words = source_line.get("words") if isinstance(source_line.get("words"), list) else []
            text_parts, roman_parts, chars, word_timings = [], [], [], []
            for word in words:
                if not isinstance(word, dict):
                    continue
                text = html.unescape(str(word.get("word", ""))).replace("\ufeff", "")
                if not text:
                    continue
                word_start = number(word.get("startTime"), start)
                word_end = number(word.get("endTime"), word_start)
                text_parts.append(text)
                roman_word = clean_text(word.get("romanWord", word.get("romanization", "")))
                if roman_word:
                    roman_parts.append(roman_word)
                chars.extend(word_start + index * max(0, word_end - word_start) // max(1, len(text))
                             for index in range(len(text)))
                word_timings.append({"text": text, "start": word_start, "end": word_end,
                                     "romanization": roman_word})
            text = "".join(text_parts) or source_line.get("text", source_line.get("lyric", ""))
            item = line(start, max(0, end - start), text,
                        source_line.get("translatedLyric", source_line.get("translation", "")),
                        source_line.get("romanLyric", source_line.get("romanization", ""))
                        or " ".join(roman_parts), chars)
            item["words"] = word_timings
            item["is_background"] = source_line.get(
                "isBG", source_line.get("isBg", source_line.get("isBackground"))) is True
            item["is_duet"] = source_line.get("isDuet") is True
            next_line = source_lines[line_index + 1] if line_index + 1 < len(source_lines) else None
            next_start = number(next_line.get("startTime"), -1) if isinstance(next_line, dict) else -1
            if len(word_timings) == 1 and end - start >= 7000 and abs(next_start - end) <= 50:
                word = word_timings[0]
                if abs(word["start"] - start) <= 50 and abs(word["end"] - end) <= 50:
                    item["duration_inferred"] = True
                    item["chars"] = []
            if item["text"] or item["translation"] or item["romanization"]:
                result.append(item)
        return finalize(result, number(data.get("duration"), 0))

    for key in ("yrcData", "lrcData"):
        parsed = parse_lines(data.get(key))
        if parsed:
            return parsed
    return []


def finalize(lines, total_duration=0):
    cleaned = []
    for item in lines or []:
        if not isinstance(item, dict):
            continue
        normalized = line(
            item.get("time", item.get("start", item.get("startTimeMs", -1))),
            item.get("duration", item.get("durationMs", 0)),
            item.get("text", item.get("words", item.get("lyric", ""))),
            item.get("translation", item.get("translated", "")),
            item.get("romanization", item.get("romanized", item.get("romaji", ""))),
            item.get("chars", item.get("charTimes", [])),
        )
        if isinstance(item.get("words"), list):
            normalized["words"] = item["words"]
        if item.get("is_background") is True:
            normalized["is_background"] = True
        if item.get("is_duet") is True:
            normalized["is_duet"] = True
        if item.get("duration_inferred") is True:
            normalized["duration_inferred"] = True
        if normalized["text"] or normalized["translation"] or normalized["romanization"]:
            cleaned.append(normalized)
    cleaned.sort(key=lambda item: (item["time"] < 0, item["time"] if item["time"] >= 0 else 0))
    for index, item in enumerate(cleaned):
        if item["duration"] > 0 or item["time"] < 0:
            continue
        next_time = next(
            (other["time"] for other in cleaned[index + 1:] if other["time"] > item["time"]),
            total_duration if total_duration > item["time"] else 0,
        )
        if next_time:
            item["duration"] = max(0, next_time - item["time"])
            item["duration_inferred"] = True
    return cleaned


def merge_timed(primary, secondary, field, tolerance=500):
    if not primary or not secondary:
        return primary
    untimed = [item for item in secondary if item.get("time", -1) < 0]
    timed = [item for item in secondary if item.get("time", -1) >= 0]
    for index, target in enumerate(primary):
        value = ""
        if target.get("time", -1) >= 0 and timed:
            candidate = min(timed, key=lambda item: abs(item["time"] - target["time"]))
            if abs(candidate["time"] - target["time"]) <= tolerance:
                value = candidate.get("text", "")
        elif index < len(untimed):
            value = untimed[index].get("text", "")
        if value and not target.get(field):
            target[field] = value
    return primary


def parse_plain(text):
    return [line(-1, text=value) for value in str(text or "").splitlines() if clean_text(value)]


def parse_lrc(text):
    text = str(text or "").replace("\r\n", "\n").replace("\r", "\n")
    offset = 0
    match = re.search(r"\[offset:([+-]?\d+)\]", text, re.I)
    if match:
        offset = number(match.group(1))
    result = []
    for raw in text.splitlines():
        raw = raw.strip()
        if not raw or META_TAG.match(raw):
            continue
        krc = KRC_LINE.match(raw)
        if krc:
            start, duration, body = number(krc.group(1)), number(krc.group(2)), krc.group(3)
            words = PREFIX_WORD.findall(body) if re.match(r"^[<(]\d+,", body) else []
            absolute_word_times = body.startswith("(")
            if words:
                pieces = [(word, number(word_offset), number(word_duration))
                          for word_offset, word_duration, word in words]
            else:
                suffix_words = SUFFIX_WORD.findall(body)
                if not suffix_words:
                    suffix_words = QRC_SUFFIX_WORD.findall(body)
                    absolute_word_times = bool(suffix_words)
                pieces = [(word, number(word_offset), number(word_duration))
                          for word, word_offset, word_duration in suffix_words]
            if pieces:
                content, chars = "", []
                for word, word_offset, word_duration in pieces:
                    for index, character in enumerate(word):
                        content += character
                        word_start = word_offset if absolute_word_times else start + word_offset
                        chars.append(word_start + (index * word_duration // max(1, len(word))))
                if clean_text(content):
                    result.append(line(start + offset, duration, content, chars=chars))
                    continue
            if clean_text(body):
                result.append(line(start + offset, duration, body))
            continue
        tags = list(TIME_TAG.finditer(raw))
        if not tags:
            continue
        body = TIME_TAG.sub("", raw).strip()
        enhanced = list(ENHANCED_WORD.finditer(body))
        visible = clean_text(ENHANCED_WORD.sub(lambda item: item.group(3), body)) if enhanced else clean_text(body)
        if not visible:
            continue
        for tag in tags:
            start = timestamp_ms(tag.group(1), tag.group(2)) + offset
            if CREDIT_LINE.match(visible) or (start <= 1000 and " - " in visible):
                continue
            chars = []
            if enhanced:
                for word in enhanced:
                    word_time = timestamp_ms(word.group(1) or tag.group(1), word.group(2)) + offset
                    chars.extend([word_time] * len(word.group(3)))
            result.append(line(start, text=visible, chars=chars))
    return finalize(result)


def parse_time_expression(value):
    value = clean_text(value)
    if not value:
        return -1
    if value.endswith("ms"):
        return number(value[:-2], -1)
    if value.endswith("s"):
        try:
            return int(float(value[:-1]) * 1000)
        except ValueError:
            return -1
    parts = value.split(":")
    try:
        if len(parts) == 3:
            return int((float(parts[0]) * 3600 + float(parts[1]) * 60 + float(parts[2])) * 1000)
        if len(parts) == 2:
            return int((float(parts[0]) * 60 + float(parts[1])) * 1000)
        return int(float(value) * 1000)
    except ValueError:
        return -1


def parse_ttml(text):
    try:
        root = ET.fromstring(text)
    except (ET.ParseError, TypeError):
        return []
    result = []
    for node in root.iter():
        if node.tag.rsplit("}", 1)[-1] != "p":
            continue
        start = parse_time_expression(node.attrib.get("begin", ""))
        end = parse_time_expression(node.attrib.get("end", ""))
        content = clean_text("".join(node.itertext()))
        if not content:
            continue
        chars = []
        for child in node.iter():
            if child is node or child.tag.rsplit("}", 1)[-1] != "span":
                continue
            child_text = "".join(child.itertext())
            child_start = parse_time_expression(child.attrib.get("begin", ""))
            if child_text and child_start >= 0:
                chars.extend([child_start] * len(child_text))
        role = " ".join(str(value) for key, value in node.attrib.items() if "role" in key.lower()).lower()
        item = line(start, max(0, end - start) if end >= start >= 0 else 0, content, chars=chars)
        if "translation" in role:
            item["_kind"] = "translation"
        elif "roman" in role:
            item["_kind"] = "romanization"
        result.append(item)
    primary = [item for item in result if not item.get("_kind")]
    translations = [item for item in result if item.get("_kind") == "translation"]
    romanizations = [item for item in result if item.get("_kind") == "romanization"]
    if not primary:
        primary = translations or romanizations
    merge_timed(primary, translations, "translation")
    merge_timed(primary, romanizations, "romanization")
    for item in primary:
        item.pop("_kind", None)
    return finalize(primary)


def qrc_content(text):
    text = str(text or "").strip()
    if not text.startswith("<"):
        return text
    try:
        root = ET.fromstring(text)
        for node in root.iter():
            for key, value in node.attrib.items():
                if key.rsplit("}", 1)[-1].lower() == "lyriccontent":
                    return value
    except ET.ParseError:
        pass
    match = re.search(r'LyricContent\s*=\s*"([\s\S]*?)"\s*/?>', text, re.I)
    return html.unescape(match.group(1)) if match else text


def first_value(data, names):
    if isinstance(data, dict):
        for name in names:
            if name in data and data[name] not in (None, "", [], {}):
                return data[name]
        for value in data.values():
            found = first_value(value, names)
            if found not in (None, "", [], {}):
                return found
    elif isinstance(data, list):
        for value in data:
            found = first_value(value, names)
            if found not in (None, "", [], {}):
                return found
    return None


def parse_json_lines(value):
    if isinstance(value, str):
        stripped = value.strip()
        if stripped.startswith("<") and ("<tt" in stripped[:300] or "<p" in stripped[:300]):
            return parse_ttml(stripped)
        if "[" in stripped and (TIME_TAG.search(stripped) or KRC_LINE.search(stripped)):
            return parse_lrc(stripped)
        return parse_plain(stripped)
    if isinstance(value, dict):
        direct = first_value(value, ("lines", "lyricLines", "lyricsLines", "sentences"))
        if direct is not None and direct is not value:
            parsed = parse_json_lines(direct)
            if parsed:
                return parsed
        lyric = first_value(value, ("syncedLyrics", "synced_lyrics", "subtitle_body", "ttml", "lyric", "lyrics", "lrc", "content"))
        if lyric is not None and lyric is not value:
            return parse_json_lines(lyric)
        return []
    if not isinstance(value, list):
        return []
    result = []
    for item in value:
        if isinstance(item, str):
            result.append(line(-1, text=item))
            continue
        if not isinstance(item, dict):
            continue
        start = first_value(item, ("time", "start", "startTime", "startTimeMs", "start_time", "begin", "timestamp"))
        duration = first_value(item, ("duration", "durationMs", "duration_ms"))
        end = first_value(item, ("end", "endTime", "endTimeMs", "end_time"))
        text = first_value(item, ("text", "words", "lyric", "content", "line"))
        translation = first_value(item, ("translation", "translated", "translatedLyric"))
        romanization = first_value(item, ("romanization", "romanized", "romaji", "transliteration"))
        if isinstance(start, str) and (":" in start or start.endswith(("s", "ms"))):
            start = parse_time_expression(start)
        start = number(start, -1)
        duration = number(duration, 0)
        if not duration and end is not None:
            if isinstance(end, str) and (":" in end or end.endswith(("s", "ms"))):
                end = parse_time_expression(end)
            duration = max(0, number(end) - start)
        chars = first_value(item, ("chars", "charTimes", "syllables", "wordsTiming")) or []
        char_times = []
        if isinstance(chars, list):
            for char in chars:
                if isinstance(char, dict):
                    char_times.append(number(first_value(char, ("time", "start", "startTimeMs"))))
                elif isinstance(char, (int, float, str)):
                    char_times.append(number(char))
        result.append(line(start, duration, text, translation, romanization, char_times))
    return finalize(result)


def parse_payload(payload):
    if isinstance(payload, bytes):
        payload = payload.decode("utf-8", "replace")
    if isinstance(payload, str):
        stripped = payload.strip().lstrip("\ufeff")
        if stripped.startswith("<"):
            parsed = parse_ttml(stripped)
            if parsed:
                return parsed
        try:
            payload = json.loads(stripped)
        except (ValueError, TypeError):
            return parse_lrc(stripped) or parse_plain(stripped)
    return parse_json_lines(payload)


def request_data(url, headers=None, data=None, method=None, timeout=15):
    safe_headers = {"User-Agent": USER_AGENT, "Accept": "application/json, text/plain, application/xml, text/xml"}
    safe_headers.update(headers or {})
    body = None
    if data is not None:
        body = data if isinstance(data, bytes) else urllib.parse.urlencode(data).encode("utf-8")
    request = urllib.request.Request(url, data=body, headers=safe_headers, method=method)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read(), response.headers.get_content_charset() or "utf-8"


def request_json(url, headers=None, data=None, method=None, timeout=15):
    body, charset = request_data(url, headers, data, method, timeout)
    text = body.decode(charset, "replace").strip()
    if text.startswith("callback(") and text.endswith(")"):
        text = text[9:-1]
    return json.loads(text)


def query_url(base, params):
    return base + ("&" if "?" in base else "?") + urllib.parse.urlencode(params)


def best_match(items, track, title_key, artist_key, album_key=None):
    if not items:
        return None
    wanted_title, wanted_artist, wanted_album = map(normalize, (
        track.get("title"), track.get("artist"), track.get("album")
    ))
    best, best_score = None, -1
    for item in items:
        title = normalize(title_key(item))
        artist = normalize(artist_key(item))
        album = normalize(album_key(item)) if album_key else ""
        score = 0
        if wanted_title and title:
            title_score = 6 if title == wanted_title else 3 if wanted_title in title or title in wanted_title else 0
            if title_score == 0:
                continue
            score += title_score
        if wanted_artist and artist:
            score += 4 if artist == wanted_artist else 2 if wanted_artist in artist or artist in wanted_artist else 0
        if wanted_album and album:
            score += 2 if album == wanted_album else 1 if wanted_album in album or album in wanted_album else 0
        if score > best_score:
            best, best_score = item, score
    return best if best_score >= 3 else None


def first_cover(*values):
    for value in values:
        if isinstance(value, dict):
            nested = first_cover(
                value.get("url"), value.get("cover"), value.get("coverUrl"), value.get("picUrl"),
                value.get("img"), value.get("image"), value.get("artwork"), value.get("albumArt"),
            )
            if nested:
                return nested
            continue
        if isinstance(value, list):
            for item in value:
                nested = first_cover(item)
                if nested:
                    return nested
            continue
        text = clean_text(value)
        if text.startswith("//"):
            text = "https:" + text
        if text.startswith("http://") or text.startswith("https://") or text.startswith("file://"):
            return text
    return ""


def itunes_cover(track):
    term = " ".join(filter(None, (clean_text(track.get("title")), clean_text(track.get("artist")))))
    if not term:
        return ""
    try:
        data = request_json(query_url("https://itunes.apple.com/search", {
            "term": term, "media": "music", "entity": "song", "limit": 5,
        }))
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ValueError):
        return ""
    results = data.get("results") if isinstance(data, dict) else None
    if not isinstance(results, list):
        return ""
    best = best_match(
        results, track,
        lambda x: x.get("trackName", ""),
        lambda x: x.get("artistName", ""),
        lambda x: x.get("collectionName", ""),
    )
    if not best:
        return ""
    url = clean_text(best.get("artworkUrl100") or best.get("artworkUrl60"))
    if not url:
        return ""
    return re.sub(r"/\d+x\d+bb\.", "/400x400bb.", url)


def success(source, lines, diag, total=0, cover=""):
    lines = finalize(lines, total)
    if not lines:
        return empty(source, *diag)
    payload = {"type": "lyrics", "source": source, "lines": lines, "diag": diag}
    cover = clean_text(cover)
    if cover:
        payload["cover"] = cover
    return payload


def adapter_lrclib(track, credentials, options):
    source = "lrclib"
    params = {"track_name": track.get("title", ""), "artist_name": track.get("artist", "")}
    if track.get("album"):
        params["album_name"] = track["album"]
    data = request_json(query_url("https://lrclib.net/api/search", params))
    best = best_match(data, track, lambda x: x.get("trackName", ""), lambda x: x.get("artistName", ""),
                      lambda x: x.get("albumName", ""))
    if not best:
        return empty(source, "lrclib: no match")
    lyrics = best.get("syncedLyrics") or best.get("plainLyrics") or ""
    return success(
        source, parse_lrc(lyrics) or parse_plain(lyrics), ["lrclib: match"],
        duration_ms(track.get("duration")), itunes_cover(track),
    )


def adapter_netease(track, credentials, options):
    source = "netease"
    search = request_json(query_url("https://music.163.com/api/search/get", {
        "type": 1, "s": " ".join(filter(None, (track.get("title"), track.get("artist")))), "limit": 10
    }), {"Referer": "https://music.163.com/"})
    songs = search.get("result", {}).get("songs", [])
    best = best_match(songs, track, lambda x: x.get("name", ""),
                      lambda x: " ".join(a.get("name", "") for a in x.get("artists", [])),
                      lambda x: x.get("album", {}).get("name", ""))
    if not best:
        return empty(source, "netease: no match")
    album = best.get("album") if isinstance(best.get("album"), dict) else {}
    cover = first_cover(album.get("picUrl"), album.get("blurPicUrl"), best.get("picUrl"), best.get("albumPic"))
    if cover and "music.126.net" in cover:
        if re.search(r"[?&]param=\d+y\d+", cover):
            cover = re.sub(r"param=\d+y\d+", "param=400y400", cover)
        else:
            cover = cover + ("&" if "?" in cover else "?") + "param=400y400"
    data = request_json(query_url("https://music.163.com/api/song/lyric", {
        "id": best.get("id"), "lv": 1, "kv": 1, "tv": 1, "rv": 1, "yv": 1
    }), {"Referer": "https://music.163.com/"})
    lines = []
    for name in ("yrc", "klyric", "lrc"):
        main = data.get(name, {})
        main = main.get("lyric", "") if isinstance(main, dict) else main
        lines = parse_lrc(main) if main else []
        if lines:
            break
    translation = data.get("tlyric", {})
    romanization = data.get("romalrc", {})
    merge_timed(lines, parse_lrc(translation.get("lyric", "") if isinstance(translation, dict) else translation), "translation")
    merge_timed(lines, parse_lrc(romanization.get("lyric", "") if isinstance(romanization, dict) else romanization), "romanization")
    return success(source, lines, ["netease: match"], duration_ms(track.get("duration")), cover)


def adapter_qqmusic(track, credentials, options):
    source = "qqmusic"
    search = request_json(query_url("https://c.y.qq.com/soso/fcgi-bin/client_search_cp", {
        "format": "json", "p": 1, "n": 10, "w": " ".join(filter(None, (track.get("title"), track.get("artist"))))
    }), {"Referer": "https://y.qq.com/"})
    songs = search.get("data", {}).get("song", {}).get("list", [])
    best = best_match(songs, track, lambda x: x.get("songname", x.get("title", "")),
                      lambda x: " ".join(a.get("name", "") for a in x.get("singer", [])),
                      lambda x: x.get("albumname", ""))
    if not best:
        return empty(source, "qqmusic: no match")
    albummid = clean_text(best.get("albummid") or best.get("albumMid"))
    cover = ""
    if albummid:
        cover = "https://y.gtimg.cn/music/photo_new/T002R300x300M000" + albummid + ".jpg"
    cover = first_cover(cover, best.get("albumPic"), best.get("pic"), best.get("strAlbumPic"))
    data = request_json(query_url("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", {
        "songmid": best.get("songmid", best.get("mid", "")), "format": "json", "nobase64": 1,
        "g_tk": 5381
    }), {"Referer": "https://y.qq.com/portal/player.html"})
    def decoded(name):
        value = data.get(name, "")
        if not value:
            return ""
        try:
            return base64.b64decode(value).decode("utf-8", "replace") if not TIME_TAG.search(value) else value
        except (ValueError, TypeError):
            return value
    lines = parse_lrc(decoded("lyric"))
    merge_timed(lines, parse_lrc(decoded("trans")), "translation")
    merge_timed(lines, parse_lrc(decoded("roma")), "romanization")
    return success(source, lines, ["qqmusic: match"], duration_ms(track.get("duration")), cover)


def adapter_splayer(track, credentials, options):
    source = "splayer"
    base_url = clean_text(credentials.get("splayer_api_url")) or "http://127.0.0.1:25884"
    parsed_url = urllib.parse.urlsplit(base_url)
    if parsed_url.scheme not in ("http", "https") or not parsed_url.netloc:
        return empty(source, "splayer: invalid API URL")
    title = clean_text(track.get("title"))
    artist = clean_text(track.get("artist"))
    expected_duration = duration_ms(track.get("duration"))
    song_info_endpoint = base_url.rstrip("/") + "/api/control/song-info"
    last_state = "unavailable"
    for attempt in range(3):
        try:
            response = request_json(song_info_endpoint, timeout=1)
            current = response.get("data", {}) if isinstance(response, dict) else {}
            current_title = current.get("name", current.get("playName", ""))
            current_artist = current.get("artistName", current.get("artist", current.get("artists", "")))
            if isinstance(current_artist, list):
                current_artist = " ".join(
                    clean_text(item.get("name", item) if isinstance(item, dict) else item)
                    for item in current_artist
                )
            wanted_title = normalize(title)
            normalized_title = normalize(current_title)
            title_matches = normalized_title == wanted_title or (
                bool(normalized_title) and (normalized_title in wanted_title or wanted_title in normalized_title)
            )
            artist_matches = not artist or not current_artist or (
                normalize(artist) in normalize(current_artist) or normalize(current_artist) in normalize(artist)
            )
            if title_matches and artist_matches:
                lines = splayer_transmitted_lines(current)
                if lines:
                    cover = first_cover(
                        current.get("cover"), current.get("coverUrl"), current.get("picUrl"),
                        current.get("albumCover"), current.get("albumArt"), current.get("img"),
                        current.get("image"), current.get("al"),
                    )
                    return success(source, lines, ["splayer: transmitted lyrics"], expected_duration, cover)
                last_state = "loading" if current.get("lyricLoading") is True else "empty"
            else:
                last_state = "track not ready"
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ValueError):
            last_state = "API unavailable"
        if attempt < 2:
            time.sleep(0.4)
    return empty(source, "splayer: " + last_state)


def adapter_kugou(track, credentials, options):
    source = "kugou"
    keyword = " ".join(filter(None, (track.get("title"), track.get("artist"))))
    search = request_json(query_url("https://mobilecdn.kugou.com/api/v3/search/song", {
        "format": "json", "keyword": keyword, "page": 1, "pagesize": 10, "showtype": 1
    }))
    songs = search.get("data", {}).get("info", [])
    best = best_match(songs, track, lambda x: x.get("songname", x.get("filename", "")),
                      lambda x: x.get("singername", ""), lambda x: x.get("album_name", ""))
    if not best:
        return empty(source, "kugou: no match")
    cover = first_cover(best.get("album_sizable_cover"), best.get("imgUrl"), best.get("album_img"), best.get("cover"))
    if cover:
        cover = cover.replace("{size}", "400")
    candidates = request_json(query_url("https://lyrics.kugou.com/search", {
        "ver": 1, "man": "yes", "client": "pc", "keyword": keyword,
        "duration": best.get("duration", duration_ms(track.get("duration"))), "hash": best.get("hash", "")
    })).get("candidates", [])
    if not candidates:
        return empty(source, "kugou: lyrics unavailable")
    candidate = candidates[0]
    data = request_json(query_url("https://lyrics.kugou.com/download", {
        "ver": 1, "client": "pc", "id": candidate.get("id"), "accesskey": candidate.get("accesskey"),
        "fmt": "lrc", "charset": "utf8"
    }))
    content = data.get("content", "")
    try:
        content = base64.b64decode(content).decode("utf-8", "replace")
    except (ValueError, TypeError):
        pass
    return success(source, parse_lrc(content), ["kugou: match"], duration_ms(track.get("duration")), cover)


def adapter_qishui(track, credentials, options):
    source = "qishui"
    template = clean_text(credentials.get("qishui_api_url"))
    if not template:
        return empty(source, "qishui: endpoint required")
    replacements = {key: urllib.parse.quote(str(track.get(key, "")), safe="") for key in ("title", "artist", "album")}
    try:
        url = template.format(**replacements)
    except (KeyError, ValueError):
        return empty(source, "qishui: invalid endpoint template")
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        return empty(source, "qishui: invalid endpoint")
    headers = {}
    if credentials.get("qishui_token"):
        headers["Authorization"] = "Bearer " + str(credentials["qishui_token"])
    body, charset = request_data(url, headers)
    lines = parse_payload(body.decode(charset, "replace"))
    return success(
        source, lines, ["qishui: response parsed"],
        duration_ms(track.get("duration")), itunes_cover(track),
    )


def spotify_token(credentials):
    token = clean_text(credentials.get("spotify_access_token"))
    if token:
        return token
    cookie = clean_text(credentials.get("spotify_sp_dc"))
    if not cookie:
        return ""
    data = request_json("https://open.spotify.com/get_access_token?reason=transport&productType=web_player",
                        {"Cookie": "sp_dc=" + cookie, "Referer": "https://open.spotify.com/"})
    return clean_text(data.get("accessToken"))


def adapter_spotify(track, credentials, options):
    source = "spotify"
    token = spotify_token(credentials)
    if not token:
        return empty(source, "spotify: credentials required")
    headers = {"Authorization": "Bearer " + token}
    search = request_json(query_url("https://api.spotify.com/v1/search", {
        "q": " ".join(filter(None, (track.get("title"), track.get("artist")))), "type": "track", "limit": 10
    }), headers)
    items = search.get("tracks", {}).get("items", [])
    best = best_match(items, track, lambda x: x.get("name", ""),
                      lambda x: " ".join(a.get("name", "") for a in x.get("artists", [])),
                      lambda x: x.get("album", {}).get("name", ""))
    if not best:
        return empty(source, "spotify: no match")
    album = best.get("album") if isinstance(best.get("album"), dict) else {}
    images = album.get("images") if isinstance(album.get("images"), list) else []
    cover = first_cover(images, album.get("image"), best.get("image"))
    data = request_json(query_url("https://spclient.wg.spotify.com/color-lyrics/v2/track/" + urllib.parse.quote(best["id"]), {
        "format": "json", "market": "from_token"
    }), headers)
    lines = parse_json_lines(data.get("lyrics", {}).get("lines", []))
    alternatives = data.get("lyrics", {}).get("alternatives", [])
    if alternatives and isinstance(alternatives[0], dict):
        merge_timed(lines, parse_json_lines(alternatives[0].get("lines", [])), "translation")
    return success(source, lines, ["spotify: match"], duration_ms(track.get("duration")), cover)


def adapter_apple_music(track, credentials, options):
    source = "apple_music"
    developer = clean_text(credentials.get("apple_developer_token"))
    if not developer:
        return empty(source, "apple_music: developer token required")
    storefront = clean_text(credentials.get("apple_storefront")) or "us"
    if not re.fullmatch(r"[A-Za-z0-9-]+", storefront):
        return empty(source, "apple_music: invalid storefront")
    headers = {"Authorization": "Bearer " + developer, "Origin": "https://music.apple.com"}
    if credentials.get("apple_user_token"):
        headers["Music-User-Token"] = str(credentials["apple_user_token"])
    search = request_json(query_url("https://api.music.apple.com/v1/catalog/" + storefront + "/search", {
        "term": " ".join(filter(None, (track.get("title"), track.get("artist")))), "types": "songs", "limit": 10
    }), headers)
    songs = search.get("results", {}).get("songs", {}).get("data", [])
    best = best_match(songs, track, lambda x: x.get("attributes", {}).get("name", ""),
                      lambda x: x.get("attributes", {}).get("artistName", ""),
                      lambda x: x.get("attributes", {}).get("albumName", ""))
    if not best:
        return empty(source, "apple_music: no match")
    attrs = best.get("attributes") if isinstance(best.get("attributes"), dict) else {}
    artwork = attrs.get("artwork") if isinstance(attrs.get("artwork"), dict) else {}
    cover = ""
    template = clean_text(artwork.get("url"))
    if template:
        cover = template.replace("{w}", "400").replace("{h}", "400")
    cover = first_cover(cover, attrs.get("artworkUrl"), attrs.get("url"))
    body, charset = request_data(
        "https://amp-api.music.apple.com/v1/catalog/" + storefront + "/songs/" + urllib.parse.quote(str(best["id"])) + "/lyrics",
        headers,
    )
    text = body.decode(charset, "replace")
    try:
        payload = json.loads(text)
        lyric_data = first_value(payload, ("ttml", "syllableLyrics", "lyrics", "content"))
        lines = parse_payload(lyric_data) if lyric_data is not None else parse_json_lines(payload)
    except ValueError:
        lines = parse_ttml(text)
    return success(source, lines, ["apple_music: match"], duration_ms(track.get("duration")), cover)


def adapter_musixmatch(track, credentials, options):
    source = "musixmatch"
    token = clean_text(credentials.get("musixmatch_token"))
    if not token:
        return empty(source, "musixmatch: usertoken required")
    params = {
        "app_id": "web-desktop-app-v1.0", "usertoken": token,
        "q_track": track.get("title", ""), "q_artist": track.get("artist", ""),
        "q_album": track.get("album", ""), "subtitle_format": "lrc", "page_size": 5,
    }
    language = clean_text(options.get("translation_language"))
    if language:
        params["selected_language"] = language
    data = request_json(query_url("https://apic-desktop.musixmatch.com/ws/1.1/macro.subtitles.get", params),
                        {"Origin": "https://www.musixmatch.com", "Referer": "https://www.musixmatch.com/"})
    subtitle = first_value(data, ("subtitle_body",))
    if not subtitle:
        return empty(source, "musixmatch: lyrics unavailable")
    lines = parse_lrc(subtitle)
    translated = first_value(data, ("translation_list", "translations"))
    if isinstance(translated, list):
        translated_lines = []
        for item in translated:
            value = item.get("translation", item) if isinstance(item, dict) else item
            if isinstance(value, dict):
                text = value.get("description", value.get("translation", ""))
                time = value.get("time", value.get("matched_line", -1))
                translated_lines.append(line(time, text=text))
        merge_timed(lines, translated_lines, "translation")
    return success(
        source, lines, ["musixmatch: match"],
        duration_ms(track.get("duration")), itunes_cover(track),
    )


ADAPTERS = {
    "lrclib": adapter_lrclib,
    "netease": adapter_netease,
    "netease_public": adapter_netease,
    "qq": adapter_qqmusic,
    "qqmusic": adapter_qqmusic,
    "splayer": adapter_splayer,
    "kugou": adapter_kugou,
    "qishui": adapter_qishui,
    "apple": adapter_apple_music,
    "apple_music": adapter_apple_music,
    "spotify": adapter_spotify,
    "musixmatch": adapter_musixmatch,
}


def main():
    source = ""
    response = None
    if len(sys.argv) != 2:
        response = empty(source, "request: expected one file path")
    else:
        try:
            with open(sys.argv[1], "r", encoding="utf-8") as request_file:
                request = json.load(request_file)
            try:
                os.remove(sys.argv[1])
            except OSError:
                pass
        except FileNotFoundError:
            response = empty(source, "request: file not found")
        except (OSError, UnicodeError, json.JSONDecodeError):
            response = empty(source, "request: unreadable or invalid JSON")
        else:
            try:
                if not isinstance(request, dict):
                    response = empty(source, "request: invalid JSON object")
                else:
                    source = clean_text(request.get("source")).lower()
                    track = request.get("track") if isinstance(request.get("track"), dict) else {}
                    credentials = request.get("credentials") if isinstance(request.get("credentials"), dict) else {}
                    options = request.get("options") if isinstance(request.get("options"), dict) else {}
                    adapter = ADAPTERS.get(source)
                    if not adapter:
                        response = empty(source, "request: unknown source")
                    elif not clean_text(track.get("title")):
                        response = empty(source, "request: track title required")
                    else:
                        response = adapter(track, credentials, options)
            except urllib.error.HTTPError as error:
                response = empty(source, "source: HTTP " + str(error.code))
            except (urllib.error.URLError, TimeoutError):
                response = empty(source, "source: network failure")
            except (ValueError, ET.ParseError):
                response = empty(source, "source: invalid response")
            except Exception:
                response = empty(source, "source: unexpected failure")
    print(json.dumps(response or empty(source, "source: empty response"), ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
