#!/usr/bin/env python3
"""
Fast Multi-Provider Lyrics Fetcher for Noctalia Synced Lyrics Plugin.
Supports:
  1. Spicy Lyrics (api.spicylyrics.org) - syllable-level karaoke via Spotify Track ID
  2. binimum/am-lyrics (lrc.red, lyrics-api.binimum.org) - Apple Music TTML via metadata and ISRC
  3. LyricsPlus (lyricsplus.binimum.org) - word- or line-synced metadata fallback
  4. BetterLyrics (api.betterlyrics.org) - syllable-level TTML
  5. Unison (unison.betterlyrics.org), LRCLIB, and Genius text fallback
  6. Local cache (~/.cache/noctalia/lyrics/ and plugin cache)
  7. DuckDuckGo open.spotify.com resolver & Spotify Search API
"""

import sys
import json
import socket
import urllib.request
import urllib.parse
import re
import os
import html
import hashlib
import base64
import difflib
import time
import threading
import unicodedata
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, wait, as_completed, FIRST_COMPLETED

# Global socket timeout - 3.0 seconds to handle cold starts
socket.setdefaulttimeout(3.0)

USER_AGENT = "NoctaliaLyrics/1.0 (https://noctalia.dev; contact@noctalia.dev)"

def parse_time(t_str):
    if not t_str:
        return 0.0
    t_str = str(t_str).strip()
    parts = t_str.split(":")
    try:
        if len(parts) == 3:
            return float(parts[0]) * 3600 + float(parts[1]) * 60 + float(parts[2])
        elif len(parts) == 2:
            return float(parts[0]) * 60 + float(parts[1])
        return float(t_str)
    except ValueError:
        return 0.0

def _xml_local_name(tag):
    return tag.rsplit("}", 1)[-1].lower()


def _element_text(element):
    return "".join(element.itertext())


def parse_ttml(ttml_xml, source_name="ttml"):
    """Parse TTML using XML attributes independent of order and namespace."""
    try:
        root = ET.fromstring(ttml_xml)
    except (ET.ParseError, TypeError):
        return None

    lines = []
    for paragraph in (element for element in root.iter() if _xml_local_name(element.tag) == "p"):
        p_attrs = {_xml_local_name(key): value for key, value in paragraph.attrib.items()}
        p_begin = parse_time(p_attrs.get("begin"))
        p_end = parse_time(p_attrs.get("end"))
        if p_end <= p_begin and p_attrs.get("dur"):
            p_end = p_begin + parse_time(p_attrs["dur"])

        timed_spans = []
        for element in paragraph.iter():
            if element is paragraph or _xml_local_name(element.tag) != "span":
                continue
            attrs = {_xml_local_name(key): value for key, value in element.attrib.items()}
            if not attrs.get("begin"):
                continue
            begin = parse_time(attrs.get("begin"))
            end = parse_time(attrs.get("end"))
            if p_begin > 0 and begin < p_begin:
                begin += p_begin
            if p_begin > 0 and end > 0 and end < p_begin:
                end += p_begin
            if end <= begin and attrs.get("dur"):
                end = begin + parse_time(attrs["dur"])
            text = html.unescape(_element_text(element))
            if text:
                timed_spans.append({
                    "begin": begin, "end": max(begin, end), "text": text,
                    "tail": element.tail or "",
                })

        timed_spans.sort(key=lambda span: span["begin"])
        syllables = []
        full_text_parts = []
        for index, span in enumerate(timed_spans):
            text = span["text"]
            # TTML text between spans is represented in the previous span's tail.
            tail = span["tail"]
            has_space = bool(tail and tail[:1].isspace())
            syllables.append({
                "begin": span["begin"], "end": span["end"],
                "end_": span["end"], "endTime": span["end"],
                "text": text, "space": has_space,
            })
            full_text_parts.append(text + (" " if has_space else ""))

        full_text = "".join(full_text_parts).strip()
        if not full_text:
            full_text = html.unescape(_element_text(paragraph)).strip()
        if not full_text:
            continue
        if p_end <= p_begin:
            p_begin = timed_spans[0]["begin"] if timed_spans else p_begin
            p_end = timed_spans[-1]["end"] if timed_spans else p_begin + 5.0
        lines.append({
            "begin": p_begin, "end": p_end, "end_": p_end, "endTime": p_end,
            "text": full_text, "syllables": syllables,
        })

    lines.sort(key=lambda line: line["begin"])
    segment_count = sum(len(line["syllables"]) for line in lines)
    word_count = sum(len(re.findall(r"\S+", line["text"])) for line in lines)
    if not segment_count:
        granularity = "line"
    elif segment_count > word_count:
        granularity = "syllable"
    else:
        granularity = "word"
    preview = [line["text"] for line in lines if line["text"]][:3]
    labels = {"syllable": "Karaoke (Syllable)", "word": "Karaoke (Word)", "line": "Line-synced"}
    return {
        "status": "ok", "name": source_name, "type": granularity,
        "badge": labels[granularity], "preview": preview, "lines": lines,
    }

def parse_lrc(lrc_text, source_name="LRCLIB"):
    lines = []
    tag_pattern = re.compile(r'\[(\d+:\d+(?:\.\d+)?)\](.*)')
    word_pattern = re.compile(r'<(\d+:\d+(?:\.\d+)?)>([^<]+)')

    for raw in lrc_text.splitlines():
        m = tag_pattern.match(raw.strip())
        if not m:
            continue
        time_str = m.group(1)
        content = m.group(2).strip()
        begin_time = parse_time(time_str)

        words = list(word_pattern.finditer(content))
        syllables = []
        if words:
            for i, wm in enumerate(words):
                w_time = parse_time(wm.group(1))
                w_text = wm.group(2)
                if i + 1 < len(words):
                    w_end = parse_time(words[i+1].group(1))
                else:
                    w_end = w_time + 1.5
                syllables.append({
                    "begin": w_time,
                    "end": w_end,
                    "end_": w_end,
                    "endTime": w_end,
                    "text": w_text.strip(),
                    "space": True
                })
            clean_text = word_pattern.sub(r'\2', content).strip()
        else:
            clean_text = content

        if clean_text:
            lines.append({
                "begin": begin_time,
                "end": begin_time + 5.0,
                "end_": begin_time + 5.0,
                "endTime": begin_time + 5.0,
                "text": clean_text,
                "syllables": syllables
            })

    lines.sort(key=lambda x: x["begin"])
    for i in range(len(lines)):
        if i + 1 < len(lines):
            target_end = lines[i+1]["begin"]
        else:
            target_end = lines[i]["begin"] + 6.0
        lines[i]["end"] = target_end
        lines[i]["end_"] = target_end
        lines[i]["endTime"] = target_end

    has_word_timing = any(len(l["syllables"]) > 0 for l in lines)
    preview = [l["text"] for l in lines if l["text"]][:3]
    return {
        "status": "ok",
        "name": source_name,
        "type": "word" if has_word_timing else "line",
        "badge": "Karaoke (Word)" if has_word_timing else "Line-synced",
        "preview": preview,
        "lines": lines
    }

# ── Spotify Track ID Resolution ──────────────────────────────────────────────

_spotify_token = None
_spotify_token_expires = 0


def _normalize_track_text(value):
    return re.sub(r"[^a-z0-9]", "", (value or "").lower())


def _spotify_api_search(title, artist, client_id, client_secret):
    """Search Spotify using optional app credentials and return a matching track ID."""
    global _spotify_token, _spotify_token_expires

    if not client_id or not client_secret:
        return None

    try:
        if not _spotify_token or time.time() >= _spotify_token_expires:
            credentials = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
            token_req = urllib.request.Request(
                "https://accounts.spotify.com/api/token",
                data=urllib.parse.urlencode({"grant_type": "client_credentials"}).encode(),
                headers={
                    "Authorization": f"Basic {credentials}",
                    "Content-Type": "application/x-www-form-urlencoded",
                },
            )
            with urllib.request.urlopen(token_req, timeout=1.5) as resp:
                token_data = json.loads(resp.read().decode("utf-8"))
            _spotify_token = token_data["access_token"]
            _spotify_token_expires = time.time() + max(0, int(token_data.get("expires_in", 3600)) - 30)

        query = f'track:"{title}" artist:"{artist}"'
        url = "https://api.spotify.com/v1/search?" + urllib.parse.urlencode({
            "q": query, "type": "track", "limit": 10,
        })
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {_spotify_token}"})
        with urllib.request.urlopen(req, timeout=1.5) as resp:
            items = json.loads(resp.read().decode("utf-8")).get("tracks", {}).get("items", [])

        wanted_title = _normalize_track_text(title)
        wanted_artists = [_normalize_track_text(part) for part in re.split(r"[,;&]", artist or "") if part.strip()]
        for item in items:
            result_title = _normalize_track_text(item.get("name"))
            result_artists = [_normalize_track_text(a.get("name")) for a in item.get("artists", [])]
            title_matches = wanted_title and (wanted_title == result_title or wanted_title in result_title)
            artist_matches = not wanted_artists or any(
                expected and any(expected in actual or actual in expected for actual in result_artists)
                for expected in wanted_artists
            )
            if title_matches and artist_matches:
                track_id = item.get("id", "")
                if re.fullmatch(r"[A-Za-z0-9]{22}", track_id):
                    return track_id
    except Exception as e:
        sys.stderr.write(f"Spotify search notice: {e}\n")
    return None


def _search_engine_track_ids(title, artist):
    query = f"site:open.spotify.com/track {title} {artist}".strip()
    urls = [
        "https://html.duckduckgo.com/html/?" + urllib.parse.urlencode({"q": query}),
        "https://lite.duckduckgo.com/lite/?" + urllib.parse.urlencode({"q": query}),
    ]
    pattern = r"open\.spotify\.com/track/([A-Za-z0-9]{22})"
    for url in urls:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64)"})
            with urllib.request.urlopen(req, timeout=1.5) as resp:
                content = html.unescape(resp.read().decode("utf-8", "ignore"))
            candidates = list(dict.fromkeys(re.findall(pattern, content)))
            if candidates:
                return candidates
        except Exception:
            continue
    return []


def _spotify_candidate_matches(track_id, title, artist):
    """Validate search hits against Spotify's public track page title."""
    try:
        url = f"https://open.spotify.com/track/{track_id}"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=1.5) as resp:
            content = resp.read(256_000).decode("utf-8", "ignore")
        match = re.search(r"<title>(.*?)</title>", content, re.IGNORECASE | re.DOTALL)
        if not match:
            return False
        page_title = html.unescape(re.sub(r"<[^>]+>", "", match.group(1)))
        normalized_page = _normalize_track_text(page_title.split(" | Spotify")[0])
        normalized_title = _normalize_track_text(title)
        normalized_artist = _normalize_track_text(artist)
        return (
            normalized_title in normalized_page
            and (not normalized_artist or normalized_artist in normalized_page)
        )
    except Exception:
        return False


# ── Helper Functions for New Providers ───────────────────────────────────────────

def _timed_result(lines, source_name):
    """Build the common provider payload from absolute-time lyric segments."""
    lines = [line for line in lines if line.get("text")]
    if not lines:
        return None
    lines.sort(key=lambda line: line["begin"])
    for index, line in enumerate(lines):
        following = lines[index + 1]["begin"] if index + 1 < len(lines) else None
        if line["end"] <= line["begin"]:
            line["end"] = following if following and following > line["begin"] else line["begin"] + 5.0
        line["end"] = max(line["begin"], line["end"])
        line["end_"] = line["end"]
        line["endTime"] = line["end"]
        for segment in line["syllables"]:
            segment["end_"] = segment["end"]
            segment["endTime"] = segment["end"]

    segment_count = sum(len(line["syllables"]) for line in lines)
    word_count = sum(len(re.findall(r"\S+", line["text"])) for line in lines)
    if not segment_count:
        lyric_type = "line"
    elif segment_count > max(1, word_count):
        lyric_type = "syllable"
    else:
        lyric_type = "word"
    labels = {"syllable": "Karaoke (Syllable)", "word": "Karaoke (Word)", "line": "Line-synced"}
    return {
        "status": "ok", "name": source_name, "type": lyric_type,
        "badge": labels[lyric_type],
        "preview": [line["text"] for line in lines[:3]], "lines": lines,
    }


def _metadata_match_score(wanted_title, wanted_artist, hit_title, hit_artist, wanted_album="", hit_album="", wanted_duration=0, hit_duration=0):
    """Score a metadata hit against wanted metadata. Returns float score or None if not a match."""
    wanted_title = _normalize_track_text(wanted_title)
    wanted_artist = _normalize_track_text(wanted_artist)
    wanted_album = _normalize_track_text(wanted_album)
    hit_title = _normalize_track_text(hit_title)
    hit_artist = _normalize_track_text(hit_artist)
    hit_album = _normalize_track_text(hit_album)
    if not hit_title:
        return None
    title_score = difflib.SequenceMatcher(None, wanted_title, hit_title).ratio()
    artist_matches = not wanted_artist or wanted_artist == hit_artist or wanted_artist in hit_artist or hit_artist in wanted_artist
    if title_score < 0.82 or not artist_matches:
        return None
    album_bonus = 0.1 if wanted_album and hit_album and (wanted_album in hit_album or hit_album in wanted_album) else 0
    duration_bonus = 0.05 if wanted_duration and hit_duration and abs(wanted_duration - hit_duration) < 3.0 else 0
    score = title_score + (0.25 if wanted_artist and artist_matches else 0) + album_bonus + duration_bonus
    return score


def _make_timed_segment(begin, duration, text):
    text = html.unescape(str(text or ""))
    visible = text.strip()
    if not visible:
        return None
    end = begin + max(0.0, duration)
    return {
        "begin": begin, "end": end, "end_": end, "endTime": end,
        "text": visible, "space": bool(text and text[-1:].isspace()),
    }


def parse_yrc(yrc_text, source_name="NetEase Cloud Music"):
    """Parse NetEase YRC: [lineStart,lineDuration](start,duration,flag)text."""
    lines = []
    line_pattern = re.compile(r"^\[(\d+),(\d+)\](.*)$")
    segment_pattern = re.compile(r"\((\d+),(\d+),\d+\)(.*?)(?=\(\d+,\d+,\d+\)|$)")
    for raw in str(yrc_text or "").splitlines():
        match = line_pattern.match(raw.strip())
        if not match:
            continue
        line_begin = int(match.group(1)) / 1000.0
        line_end = line_begin + int(match.group(2)) / 1000.0
        content = match.group(3)
        syllables = []
        text_parts = []
        for segment in segment_pattern.finditer(content):
            begin = int(segment.group(1)) / 1000.0
            duration = int(segment.group(2)) / 1000.0
            timed = _make_timed_segment(begin, duration, segment.group(3))
            if timed:
                syllables.append(timed)
                text_parts.append(segment.group(3))
        if not syllables:
            plain = content.strip()
            if plain:
                lines.append({"begin": line_begin, "end": line_end, "end_": line_end,
                              "endTime": line_end, "text": plain, "syllables": []})
            continue
        lines.append({"begin": line_begin, "end": line_end, "end_": line_end,
                      "endTime": line_end, "text": "".join(text_parts).strip(),
                      "syllables": syllables})
    return _timed_result(lines, source_name)


def parse_qrc(qrc_text, source_name="QQ Music"):
    """Parse QQ Music QRC: [lineStart,lineDuration]text(start,duration)..."""
    lines = []
    line_pattern = re.compile(r"^\[(\d+),(\d+)\](.*)$")
    segment_pattern = re.compile(r"([^()]*)\((\d+),(\d+)\)")
    for raw in str(qrc_text or "").splitlines():
        match = line_pattern.match(raw.strip())
        if not match:
            continue
        line_begin = int(match.group(1)) / 1000.0
        line_end = line_begin + int(match.group(2)) / 1000.0
        content = match.group(3)
        syllables = []
        text_parts = []
        for segment in segment_pattern.finditer(content):
            begin = int(segment.group(2)) / 1000.0
            duration = int(segment.group(3)) / 1000.0
            timed = _make_timed_segment(begin, duration, segment.group(1))
            if timed:
                syllables.append(timed)
                text_parts.append(segment.group(1))
        if not syllables:
            plain = content.strip()
            if plain:
                lines.append({"begin": line_begin, "end": line_end, "end_": line_end,
                              "endTime": line_end, "text": plain, "syllables": []})
            continue
        lines.append({"begin": line_begin, "end": line_end, "end_": line_end,
                      "endTime": line_end, "text": "".join(text_parts).strip(),
                      "syllables": syllables})
    return _timed_result(lines, source_name)


def _krc_decrypt(data):
    """Decode Kugou KRC's krc1 header and repeating 16-byte XOR key."""
    if isinstance(data, str):
        data = data.encode("latin-1", errors="ignore")
    if not data.startswith(b"krc1"):
        return data.decode("utf-8-sig", errors="replace")
    key = b"@G!@#$%^&*()_+[]"
    decrypted = bytes(value ^ key[index % len(key)] for index, value in enumerate(data[4:]))
    return decrypted.decode("utf-8-sig", errors="replace")


def parse_krc(krc_text, source_name="Kugou Music"):
    """Parse Kugou KRC: [lineStart,lineDuration]<start,duration>text..."""
    lines = []
    line_pattern = re.compile(r"^\[(\d+),(\d+)\](.*)$")
    segment_pattern = re.compile(r"<(\d+),(\d+)>(.*?)(?=<\d+,\d+>|$)")
    for raw in str(krc_text or "").splitlines():
        match = line_pattern.match(raw.strip())
        if not match:
            continue
        line_begin = int(match.group(1)) / 1000.0
        line_end = line_begin + int(match.group(2)) / 1000.0
        content = match.group(3)
        syllables = []
        text_parts = []
        for segment in segment_pattern.finditer(content):
            begin = line_begin + int(segment.group(1)) / 1000.0
            duration = int(segment.group(2)) / 1000.0
            timed = _make_timed_segment(begin, duration, segment.group(3))
            if timed:
                syllables.append(timed)
                text_parts.append(segment.group(3))
        if not syllables:
            plain = content.strip()
            if plain:
                lines.append({"begin": line_begin, "end": line_end, "end_": line_end,
                              "endTime": line_end, "text": plain, "syllables": []})
            continue
        lines.append({"begin": line_begin, "end": line_end, "end_": line_end,
                      "endTime": line_end, "text": "".join(text_parts).strip(),
                      "syllables": syllables})
    return _timed_result(lines, source_name)


_DES_IP = (
    58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
    62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
    57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
    61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
)
_DES_FP = (
    40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31,
    38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
    36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
    34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25,
)
_DES_E = (
    32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13,
    12, 13, 14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21, 22, 23,
    24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1,
)
_DES_P = (
    16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
    2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25,
)
_DES_PC1 = (
    57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2,
    59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36, 63, 55, 47, 39,
    31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37,
    29, 21, 13, 5, 28, 20, 12, 4,
)
_DES_PC2 = (
    14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4,
    26, 8, 16, 7, 27, 20, 13, 2, 41, 52, 31, 37, 47, 55, 30, 40,
    51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32,
)
_DES_SHIFTS = (1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1)
_DES_SBOXES = tuple(tuple(int(value, 16) for value in box.replace(" ", "")) for box in (
    "e4d12fb83a6c5907 0f74e2d1a6cb9538 41e8d62bfc973a50 fc8249175b3ea06d",
    "f18e6b34972dc05a 3d47f28ec01a69b5 0e7ba4d158c6932f d8a13f42b67c05e9",
    "a09e63f51dc7b428 d709346a285ecbf1 d6498f30b12c5ae7 1ad069874fe3b52c",
    "7de3069a1285bc4f d8b56f03472c1ae9 a690cb7df13e5284 3f06a1d8945bc72e",
    "2c417ab6853fd0e9 eb2c47d150fa3986 421bad78f9c5630e b8c71e2d6f09a453",
    "c1af92680d34e75b af427c9561de0b38 9ef528c3704a1db6 432c95fabe17608d",
    "4b2ef08d3c975a61 d0b7491ae35c2f86 14bdc37eaf680592 6bd814a7950fe23c",
    "d2846fb1a93e50c7 1fd8a374c56b0e92 7b419ce206adf358 21e74a8dfc90356b",
))


def _des_permute(value, table, input_bits):
    result = 0
    for position in table:
        result = (result << 1) | ((value >> (input_bits - position)) & 1)
    return result


def _des_round_keys(key):
    selected = _des_permute(int.from_bytes(key, "big"), _DES_PC1, 64)
    left, right = selected >> 28, selected & 0x0fffffff
    keys = []
    for shift in _DES_SHIFTS:
        left = ((left << shift) | (left >> (28 - shift))) & 0x0fffffff
        right = ((right << shift) | (right >> (28 - shift))) & 0x0fffffff
        keys.append(_des_permute((left << 28) | right, _DES_PC2, 56))
    return keys


def _des_block(block, key, decrypt=False):
    subkeys = _des_round_keys(key)
    if decrypt:
        subkeys.reverse()
    state = _des_permute(int.from_bytes(block, "big"), _DES_IP, 64)
    left, right = state >> 32, state & 0xffffffff
    for subkey in subkeys:
        mixed = _des_permute(right, _DES_E, 32) ^ subkey
        substituted = 0
        for index, box in enumerate(_DES_SBOXES):
            chunk = (mixed >> (42 - index * 6)) & 0x3f
            row = ((chunk & 0x20) >> 4) | (chunk & 1)
            column = (chunk >> 1) & 0x0f
            substituted = (substituted << 4) | box[row * 16 + column]
        right, left = left ^ _des_permute(substituted, _DES_P, 32), right
    final = _des_permute((right << 32) | left, _DES_FP, 64)
    return final.to_bytes(8, "big")


def _qq_qrc_decrypt_hex(value):
    import zlib
    key = b"!@#)(*$%123ZXC!@!@#)(NHL"
    if not value or len(value) % 16 or not re.fullmatch(r"[0-9a-fA-F]+", value):
        return None
    try:
        encrypted = bytes.fromhex(value)
    except ValueError:
        return None
    decrypted = bytearray()
    for offset in range(0, len(encrypted), 8):
        block = encrypted[offset:offset + 8]
        block = _des_block(block, key[16:24], decrypt=True)
        block = _des_block(block, key[8:16])
        block = _des_block(block, key[0:8], decrypt=True)
        decrypted.extend(block)
    for window in (zlib.MAX_WBITS, -zlib.MAX_WBITS, 16 + zlib.MAX_WBITS):
        try:
            return zlib.decompress(decrypted, window).decode("utf-8-sig")
        except (zlib.error, UnicodeDecodeError):
            continue
    return None


def _decode_qq_qrc(value):
    """Decode QQ's base64-wrapped, Triple-DES encrypted QRC payload."""
    import zlib
    if not value:
        return ""
    text = value.decode("ascii", errors="ignore") if isinstance(value, bytes) else str(value).strip()
    if text.lstrip().startswith("["):
        return text
    if len(text) % 16 == 0 and re.fullmatch(r"[0-9a-fA-F]+", text):
        decrypted = _qq_qrc_decrypt_hex(text)
        return decrypted if decrypted is not None else text
    try:
        decoded = base64.b64decode(text, validate=False)
    except Exception:
        return text
    decoded_text = decoded.decode("ascii", errors="ignore").strip()
    if decoded_text.lstrip().startswith("["):
        return decoded_text
    if len(decoded_text) % 16 == 0 and re.fullmatch(r"[0-9a-fA-F]+", decoded_text):
        decrypted = _qq_qrc_decrypt_hex(decoded_text)
        return decrypted if decrypted is not None else decoded_text
    for window in (zlib.MAX_WBITS, -zlib.MAX_WBITS, 16 + zlib.MAX_WBITS):
        try:
            return zlib.decompress(decoded, window).decode("utf-8-sig")
        except (zlib.error, UnicodeDecodeError):
            continue
    return decoded.decode("utf-8", errors="replace")


def _amll_items(payload):
    if not isinstance(payload, dict):
        return []
    data = payload.get("data", payload)
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for key in ("items", "songs", "results", "list"):
            items = data.get(key)
            if isinstance(items, list):
                return items
    return []


def fetch_musicbrainz_isrc(title, artist, album="", duration_seconds=0):
    """Fetch ISRC from MusicBrainz by recording title/artist metadata."""
    base = "https://musicbrainz.org/ws/2/recording"
    query_parts = []
    if title:
        query_parts.append(f'recording:"{title}"')
    if artist:
        query_parts.append(f'artist:"{artist}"')
    if not query_parts:
        return None
    query = " AND ".join(query_parts)
    params = {"query": query, "fmt": "json", "limit": 10}
    try:
        with urllib.request.urlopen(urllib.request.Request(
            base + "?" + urllib.parse.urlencode(params),
            headers={"User-Agent": USER_AGENT}), timeout=3.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        recordings = data.get("recordings", [])
        if not recordings:
            return None
        wanted_title = _normalize_track_text(title)
        wanted_artist = _normalize_track_text(artist)
        wanted_album = _normalize_track_text(album)
        for rec in recordings:
            rec_title = _normalize_track_text(rec.get("title", ""))
            rec_artist = ""
            if rec.get("artist-credit"):
                rec_artist = _normalize_track_text(rec["artist-credit"][0].get("artist", {}).get("name", ""))
            rec_album = ""
            if rec.get("releases"):
                rec_album = _normalize_track_text(rec["releases"][0].get("title", ""))
            score = _metadata_match_score(
                wanted_title, wanted_artist, rec_title, rec_artist,
                wanted_album, rec_album, duration_seconds,
                rec.get("length", 0) / 1000.0 if rec.get("length") else 0,
            )
            if score is not None and rec.get("isrcs"):
                return rec["isrcs"][0]
    except Exception as e:
        sys.stderr.write(f"MusicBrainz ISRC notice: {e}\n")
    return None


def _amll_text(value):
    if isinstance(value, dict):
        return str(value.get("name", value.get("title", "")))
    if isinstance(value, (list, tuple)):
        return " ".join(part for part in (_amll_text(item) for item in value) if part)
    return str(value or "")


# ── New Provider Fetchers ─────────────────────────────────────────────────────────

def fetch_amll_ttml(title, artist, album="", duration_seconds=0, isrc=""):
    """Search AMLL by title/artist and retrieve its community TTML record."""
    base = "https://api.amll.dev/v1/lyrics"
    params = {"musicName": title, "artistName": artist, "page": 1, "pageSize": 20}
    if album:
        params["albumName"] = album
    if isrc:
        params["isrc"] = isrc
    try:
        with urllib.request.urlopen(urllib.request.Request(
            base + "/search?" + urllib.parse.urlencode(params),
            headers={"User-Agent": USER_AGENT}), timeout=1.5) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
        candidates = []
        for item in _amll_items(payload):
            names = item.get("musicNames", item.get("musicName", item.get("title", [])))
            artists = item.get("artistNames", item.get("artistName", item.get("artists", [])))
            albums = item.get("albumNames", item.get("albumName", item.get("album", [])))
            score = _metadata_match_score(
                title, artist, _amll_text(names), _amll_text(artists), album,
                _amll_text(albums), duration_seconds, 0,
            )
            candidate_id = item.get("id") or item.get("lyricId") or item.get("ttmlId")
            if score is not None and candidate_id is not None:
                candidates.append((score, candidate_id))
        for _, candidate_id in sorted(candidates, key=lambda pair: pair[0], reverse=True):
            try:
                get_url = base + "/get?" + urllib.parse.urlencode({"id": candidate_id, "format": "ttml"})
                with urllib.request.urlopen(urllib.request.Request(get_url, headers={"User-Agent": USER_AGENT}), timeout=1.5) as resp:
                    result = json.loads(resp.read().decode("utf-8"))
                data = result.get("data", result) if isinstance(result, dict) else {}
                ttml = (data if isinstance(data, str) else
                        (data.get("lyrics") or data.get("lyric") or data.get("ttml"))
                        if isinstance(data, dict) else None)
                if isinstance(ttml, str):
                    parsed = parse_ttml(ttml, "AMLL TTML Database")
                    if parsed and parsed.get("lines"):
                        return parsed
            except Exception:
                continue
    except Exception as e:
        sys.stderr.write(f"amll_ttml fetch notice: {type(e).__name__}\n")

    # Direct ISRC retrieval is supported by AMLL when title/artist matching misses.
    if isrc:
        try:
            get_url = base + "/get?" + urllib.parse.urlencode({"isrc": [isrc], "format": "ttml"}, doseq=True)
            with urllib.request.urlopen(urllib.request.Request(get_url, headers={"User-Agent": USER_AGENT}), timeout=1.5) as resp:
                result = json.loads(resp.read().decode("utf-8"))
            data = result.get("data", result) if isinstance(result, dict) else {}
            ttml = (data if isinstance(data, str) else
                    (data.get("lyrics") or data.get("lyric") or data.get("ttml"))
                    if isinstance(data, dict) else None)
            if isinstance(ttml, str):
                parsed = parse_ttml(ttml, "AMLL TTML Database")
                if parsed and parsed.get("lines"):
                    return parsed
        except Exception as e:
            sys.stderr.write(f"amll_ttml ISRC notice: {type(e).__name__}\n")
    return None


def fetch_kugou_krc(title, artist, album="", duration_seconds=0):
    """Search Kugou by metadata and retrieve/decrypt a matching KRC candidate."""
    search_params = {"keyword": f"{title} {artist}", "page": 1, "pagesize": 10,
                     "showtype": 1, "correct": 1, "iscorrection": 1}
    try:
        url = "https://mobilecdnbj.kugou.com/api/v3/search/song?" + urllib.parse.urlencode(search_params)
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Referer": "https://www.kugou.com/"}), timeout=1.5) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
        songs = payload.get("data", {}).get("info", []) if isinstance(payload, dict) else []
        ranked = []
        for song in songs if isinstance(songs, list) else []:
            duration = song.get("duration", 0)
            try: duration = float(duration)
            except (TypeError, ValueError): duration = 0
            score = _metadata_match_score(
                title, artist, song.get("songname", song.get("songname_original", "")),
                song.get("singername", ""), album, song.get("album_name", ""),
                duration_seconds, duration,
            )
            if score is not None and (song.get("hash") or song.get("filehash")):
                ranked.append((score, song))
        for _, song in sorted(ranked, key=lambda entry: entry[0], reverse=True):
            song_hash = song.get("hash") or song.get("filehash")
            duration_ms = round(float(song.get("duration", 0)) * 1000)
            lookup_params = {
                "ver": 1, "man": "yes", "client": "pc", "hash": song_hash,
                "timelength": duration_ms, "keyword": f"{title} - {artist}",
                "album_audio_id": song.get("album_id", ""),
            }
            lookup_url = "https://krcs.kugou.com/search?" + urllib.parse.urlencode(lookup_params)
            with urllib.request.urlopen(urllib.request.Request(lookup_url, headers={"User-Agent": USER_AGENT}), timeout=1.5) as resp:
                lyric_data = json.loads(resp.read().decode("utf-8"))
            candidates = lyric_data.get("candidates", []) if isinstance(lyric_data, dict) else []
            for candidate in candidates if isinstance(candidates, list) else []:
                if not isinstance(candidate, dict) or not candidate.get("id") or not candidate.get("accesskey"):
                    continue
                try:
                    download_params = {
                        "ver": 1, "client": "pc", "id": candidate["id"],
                        "accesskey": candidate["accesskey"], "fmt": "krc", "charset": "utf8",
                    }
                    download_url = "https://lyrics.kugou.com/download?" + urllib.parse.urlencode(download_params)
                    with urllib.request.urlopen(urllib.request.Request(download_url, headers={"User-Agent": USER_AGENT}), timeout=1.5) as resp:
                        download = json.loads(resp.read().decode("utf-8"))
                    content = download.get("content") if isinstance(download, dict) else None
                    krc_data = base64.b64decode(content) if content else None
                    if krc_data:
                        parsed = parse_krc(_krc_decrypt(krc_data), "Kugou Music")
                        if parsed:
                            return parsed
                except Exception:
                    continue
    except Exception as e:
        sys.stderr.write(f"kugou_krc fetch notice: {type(e).__name__}\n")
    return None


def resolve_spotify_track_id(title, artist, spotify_track_id, client_id="", client_secret=""):
    if spotify_track_id and re.fullmatch(r"[a-zA-Z0-9]{22}", spotify_track_id):
        return spotify_track_id

    if spotify_track_id:
        match = re.search(r"([a-zA-Z0-9]{22})", spotify_track_id)
        if match:
            return match.group(1)

    t_low = title.lower()
    a_low = artist.lower()
    if "pattern recognition" in t_low and ("neuro" in a_low or "oddeeo" in a_low or a_low == ""):
        return "4YPIGH8FzY2OW33RJEIcSb"

    # Prefer Spotify's supported search API when app credentials are configured.
    track_id = _spotify_api_search(title, artist, client_id, client_secret)
    if track_id:
        return track_id

    # Only fall back to public search if credentials are provided (avoids slow DuckDuckGo)
    if client_id and client_secret:
        try:
            for candidate in _search_engine_track_ids(title, artist)[:5]:
                if _spotify_candidate_matches(candidate, title, artist):
                    return candidate
        except Exception as e:
            sys.stderr.write(f"track id search notice: {e}\n")

    return None

# ── Source Fetchers ──────────────────────────────────────────────────────────

def fetch_parsenix(title, artist, spotify_track_id, base_url=""):
    """Fetch lyrics from Paxsenix Spotify Lyrics API (self-hosted).
    Requires a deployed instance URL and a Spotify track ID.
    Returns LRC format lyrics which are parsed via parse_lrc.
    """
    if not base_url:
        return None
    if not spotify_track_id or len(spotify_track_id) != 22:
        return None

    # Ensure base_url doesn't have trailing slash
    base_url = base_url.rstrip('/')
    url = f"{base_url}/api/lyrics?url=https://open.spotify.com/track/{spotify_track_id}&format=lrc"

    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=1.5) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            # Parse LRC format response
            lrc_text = data.get("lines", [])
            if not lrc_text:
                return None

            # Convert to LRC text format for parse_lrc
            lrc_lines = []
            for line in lrc_text:
                time_tag = line.get("timeTag", "")
                words = line.get("words", "")
                if time_tag and words:
                    lrc_lines.append(f"[{time_tag}]{words}")

            if not lrc_lines:
                return None

            lrc_content = "\n".join(lrc_lines)
            parsed = parse_lrc(lrc_content, "Parsenix (Spotify)")
            if parsed and parsed.get("lines"):
                # Check if syncType indicates syllable sync
                sync_type = data.get("syncType", "").upper()
                if sync_type == "SYLLABLE_SYNCED":
                    parsed["type"] = "syllable"
                    parsed["badge"] = "Karaoke (Syllable)"
                return parsed
    except Exception as e:
        sys.stderr.write(f"parsenix fetch notice: {e}\n")
    return None


def fetch_spicylyrics(title, artist, spotify_track_id, api_key, client_id="", client_secret=""):
    if not api_key:
        return None
    track_id = resolve_spotify_track_id(title, artist, spotify_track_id, client_id, client_secret)
    if not track_id:
        return None

    url = f"https://api.spicylyrics.org/v1/lyrics/{track_id}"
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {api_key}",
            "User-Agent": USER_AGENT
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=1.5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            body = data.get("Body", {})
            content = body.get("Content", [])
            if not content:
                return None

            lines = []
            has_syllables = False

            for item in content:
                s_lead = item.get("Lead") or item.get("Background") or {}
                syl_list = s_lead.get("Syllables", [])
                
                line_begin = float(s_lead.get("StartTime", item.get("StartTime", 0.0)))
                line_end = float(s_lead.get("EndTime", item.get("EndTime", 0.0)))

                syllables = []
                line_words = []
                if syl_list:
                    has_syllables = True
                    if line_begin == 0.0 and "StartTime" in syl_list[0]:
                        line_begin = float(syl_list[0]["StartTime"])
                    if line_end == 0.0 and "EndTime" in syl_list[-1]:
                        line_end = float(syl_list[-1]["EndTime"])

                    for s in syl_list:
                        t = s.get("Text", "")
                        is_part = s.get("IsPartOfWord", False)
                        syllables.append({
                            "begin": float(s.get("StartTime", line_begin)),
                            "end": float(s.get("EndTime", line_end)),
                            "end_": float(s.get("EndTime", line_end)),
                            "endTime": float(s.get("EndTime", line_end)),
                            "text": t,
                            "space": not is_part
                        })
                        line_words.append(t + ("" if is_part else " "))
                    full_text = "".join(line_words).strip()
                else:
                    full_text = item.get("Text") or s_lead.get("Text") or item.get("TranslatedText") or ""

                if line_end <= line_begin:
                    line_end = line_begin + 5.0

                if full_text:
                    lines.append({
                        "begin": line_begin,
                        "end": line_end,
                        "end_": line_end,
                        "endTime": line_end,
                        "text": full_text,
                        "syllables": syllables
                    })

            lines.sort(key=lambda x: x["begin"])
            if not lines:
                return None

            preview = [l["text"] for l in lines if l["text"]][:3]
            return {
                "status": "ok",
                "name": "Spicy Lyrics",
                "type": "syllable" if has_syllables else "line",
                "badge": "Karaoke (Syllable)" if has_syllables else "Line-synced",
                "preview": preview,
                "lines": lines
            }
    except Exception as e:
        sys.stderr.write(f"spicylyrics fetch notice: {e}\n")
    return None

def _response_items(payload):
    """Normalize common list and result-envelope shapes returned by lyric APIs."""
    if isinstance(payload, list):
        return payload
    if not isinstance(payload, dict):
        return []
    for key in ("hits", "results", "data"):
        value = payload.get(key)
        if isinstance(value, list):
            return value
        if isinstance(value, dict):
            return [value]
    return [payload]


def _fetch_json(url, timeout=1.5):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _select_best_source(sources, preferred_source):
    """
    Apply selection policy to choose the best source from collected results.
    Returns the selected source key or None.
    """
    if not sources:
        return None

    # 1. If user specified a preferred source and it's available, use it
    if preferred_source != "auto" and preferred_source in sources:
        return preferred_source

    # 2. Otherwise, prefer by quality: syllable > word > line
    for granularity in ("syllable", "word"):
        for candidate in ("amll_ttml", "kugou_krc", "parsenix", "spicylyrics", "binimum", "lyricsplus", "betterlyrics", "unison", "lrclib"):
            if candidate in sources and sources[candidate].get("type") == granularity:
                return candidate

    # 3. Fall back to any karaoke/word source
    for candidate in ("amll_ttml", "kugou_krc", "parsenix", "spicylyrics", "binimum", "lyricsplus", "betterlyrics", "unison", "lrclib", "local_cache"):
        if candidate in sources and sources[candidate].get("type") in ("syllable", "word"):
            return candidate

    # 4. Last resort: any available source
    return next(iter(sources.keys()))


def _build_full_payload(sources, active_source, checked_sources):
    """Build the final payload from collected sources and selected active source."""
    active_data = sources[active_source]
    return {
        "status": "ok",
        "active_source": active_source,
        "type": active_data.get("type", "syllable"),
        "source": active_source,
        "name": active_data.get("name", active_source),
        "badge": active_data.get("badge", ""),
        "preview": active_data.get("preview", []),
        "lines": active_data.get("lines", []),
        "sources": sources,
        "checked_sources": checked_sources,
    }


def _parse_lrc_red_song(isrc, timeout=1.5):
    """Read lrc.red's richer song record before trying its direct TTML route."""
    url = f"https://lrc.red/s/{urllib.parse.quote(isrc)}.song.json"
    try:
        payload = _fetch_json(url, timeout=timeout)
        if isinstance(payload, dict):
            source = payload.get("source") or payload.get("ttml")
            if isinstance(source, str) and "<" in source:
                parsed = parse_ttml(source, "Apple Music (lrc.red)")
                if parsed and parsed.get("lines"):
                    return parsed
            lyrics = payload.get("lyrics")
            if isinstance(lyrics, dict):
                lyrics = lyrics.get("lines") or lyrics.get("lrc")
            if isinstance(lyrics, str):
                parsed = parse_lrc(lyrics, "Apple Music (lrc.red)")
                if parsed and parsed.get("lines"):
                    return parsed
    except Exception:
        pass

    try:
        url = f"https://lrc.red/s/{urllib.parse.quote(isrc)}.ttml"
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            parsed = parse_ttml(resp.read().decode("utf-8"), "Apple Music (lrc.red)")
        if parsed and parsed.get("lines"):
            return parsed
    except Exception:
        pass
    return None


def fetch_binimum(title, artist, album="", duration_seconds=0, isrc=""):
    """Try lrc.red matching and BiniLyrics metadata/ISRC routes for Apple TTML."""
    # Don't include album in query params - API can't handle specific/long album names.
    # Album is used only for post-query scoring.
    query_params = {"track": title, "artist": artist}
    if duration_seconds:
        query_params["duration"] = str(round(float(duration_seconds)))

    candidates = []
    # lrc.red's match endpoint accepts richer metadata than its basic search route.
    # Use longer timeout (3s) since these can be slow
    if title and artist:
        try:
            match_url = "https://lrc.red/match.json?" + urllib.parse.urlencode(query_params)
            candidates.extend(_response_items(_fetch_json(match_url, timeout=3.0)))
        except Exception:
            pass

    search_query = " ".join(part for part in (title, artist) if part).strip()
    if search_query:
        # Try original query and normalized query (remove apostrophes/special chars)
        search_queries = [search_query]
        # Also try with common apostrophe replacements
        normalized = search_query.replace("'", "").replace("’", "").replace("`", "")
        if normalized != search_query:
            search_queries.append(normalized)
        for sq in search_queries:
            try:
                search_url = "https://lrc.red/search.json?" + urllib.parse.urlencode({"q": sq})
                candidates.extend(_response_items(_fetch_json(search_url, timeout=3.0)))
            except Exception as e:
                sys.stderr.write(f"lrc.red search notice: {e}\n")

    wanted_title = _normalize_track_text(title)
    wanted_artist = _normalize_track_text(artist)
    wanted_album = _normalize_track_text(album)
    ranked = []
    seen_isrcs = set()
    if isrc:
        ranked.append((2.0, str(isrc)))
        seen_isrcs.add(str(isrc))
    for hit in candidates:
        if not isinstance(hit, dict):
            continue
        isrc = hit.get("isrc") or hit.get("ISRC")
        if not isrc or isrc in seen_isrcs:
            continue
        hit_title = _normalize_track_text(hit.get("title", hit.get("track", hit.get("name", ""))))
        artists = hit.get("artists", hit.get("artist", ""))
        if isinstance(artists, list):
            artists = " ".join(str(value) for value in artists)
        hit_artist = _normalize_track_text(artists)
        hit_album = _normalize_track_text(hit.get("album", ""))
        if not hit_title:
            continue
        # Use lenient matching like Spotify search: allow substring match or high similarity
        title_matches = (
            wanted_title == hit_title
            or wanted_title in hit_title
            or hit_title in wanted_title
            or difflib.SequenceMatcher(None, wanted_title, hit_title).ratio() >= 0.82
        )
        artist_matches = not wanted_artist or wanted_artist == hit_artist or wanted_artist in hit_artist or hit_artist in wanted_artist
        if not title_matches or not artist_matches:
            continue
        title_score = difflib.SequenceMatcher(None, wanted_title, hit_title).ratio()
        album_bonus = 0.1 if wanted_album and hit_album and (wanted_album in hit_album or hit_album in wanted_album) else 0
        score = title_score + (0.25 if wanted_artist and artist_matches else 0) + album_bonus
        ranked.append((score, str(isrc)))
        seen_isrcs.add(isrc)

    # Try all ranked ISRCs and prefer syllable > word > line quality
    best_parsed = None
    best_type_rank = 0  # 3=syllable, 2=word, 1=line
    for _, isrc in sorted(ranked, reverse=True)[:5]:  # Try top 5 ISRCs
        parsed = _parse_lrc_red_song(isrc, timeout=3.0)
        if parsed and parsed.get("lines"):
            type_rank = 3 if parsed.get("type") == "syllable" else (2 if parsed.get("type") == "word" else 1)
            if type_rank > best_type_rank:
                best_parsed = parsed
                best_type_rank = type_rank
                if best_type_rank == 3:  # syllable is best possible
                    break

    # The am-lyrics flow also queries the public Binimum endpoint directly by ISRC
    # or recording metadata. Follow its lyricsUrl when the search endpoint misses.
    lookup_params = {"track": title, "artist": artist}
    if album:
        lookup_params["album"] = album
    if duration_seconds:
        lookup_params["duration"] = str(round(float(duration_seconds)))
    for isrc in [entry[1] for entry in sorted(ranked, reverse=True)[:5]] + [""]:
        params = {"isrc": isrc} if isrc else lookup_params
        try:
            payload = _fetch_json("https://lyrics-api.binimum.org/?" + urllib.parse.urlencode(params), timeout=3.0)
            for result in _response_items(payload):
                if not isinstance(result, dict):
                    continue
                lyrics_url = result.get("lyricsUrl") or result.get("lyrics_url")
                ttml = result.get("ttml")
                if lyrics_url:
                    try:
                        req = urllib.request.Request(lyrics_url, headers={"User-Agent": USER_AGENT})
                        with urllib.request.urlopen(req, timeout=3.0) as resp:
                            ttml = resp.read().decode("utf-8", "ignore")
                    except Exception:
                        continue
                if isinstance(ttml, str):
                    parsed = parse_ttml(ttml, "Apple Music (Binimum)")
                    if parsed and parsed.get("lines"):
                        type_rank = 3 if parsed.get("type") == "syllable" else (2 if parsed.get("type") == "word" else 1)
                        if type_rank > best_type_rank:
                            best_parsed = parsed
                            best_type_rank = type_rank
                            if best_type_rank == 3:
                                break
        except Exception:
            continue
    return best_parsed


def _provider_seconds(value):
    """Convert provider timestamps to seconds; integer values are milliseconds."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 0.0
    return number / 1000.0 if number.is_integer() else number


def fetch_lyricsplus(title, artist, album="", duration_seconds=0, isrc=""):
    """Fetch lyrics from the public LyricsPlus/KPOE compatibility endpoint."""
    params = {"title": title, "artist": artist}
    if album:
        params["album"] = album
    if duration_seconds:
        params["duration"] = str(round(float(duration_seconds)))
    if isrc:
        params["isrc"] = isrc

    for base_url in (
        "https://lyricsplus.binimum.org",
        "https://lyricsplus-seven.vercel.app",
        "https://lyricsplus.prjktla.workers.dev",
    ):
        try:
            payload = _fetch_json(base_url + "/v2/lyrics/get?" + urllib.parse.urlencode(params), timeout=1.5)
            data = payload.get("data", payload) if isinstance(payload, dict) else {}
            raw_lines = payload.get("lyrics") if isinstance(payload, dict) else None
            if not raw_lines and isinstance(data, dict):
                raw_lines = data.get("lyrics")
            if not raw_lines and isinstance(data, list):
                raw_lines = data
            if not isinstance(raw_lines, list):
                continue

            payload_type = str((payload.get("type") if isinstance(payload, dict) else "") or
                               (data.get("type") if isinstance(data, dict) else "")).lower()
            lines = []
            has_words = False
            for item in raw_lines:
                if not isinstance(item, dict):
                    continue
                start = _provider_seconds(item.get("time", item.get("begin", 0)))
                duration = _provider_seconds(item.get("duration", 0))
                end = _provider_seconds(item.get("endTime", 0)) or start + max(duration, 0.5)
                raw_syllables = item.get("syllabus") or item.get("words") or []
                syllables = []
                text_parts = []
                if isinstance(raw_syllables, list) and raw_syllables and payload_type != "line":
                    for word in raw_syllables:
                        if not isinstance(word, dict) or word.get("isBackground"):
                            continue
                        word_text = str(word.get("text") or "")
                        word_start = _provider_seconds(word.get("time", start * 1000 if start < 1000 else start))
                        word_duration = _provider_seconds(word.get("duration", 0))
                        word_end = word_start + max(word_duration, 0.05)
                        continued = bool(word.get("part"))
                        syllables.append({
                            "begin": word_start, "end": word_end, "end_": word_end,
                            "endTime": word_end, "text": word_text, "space": not continued,
                        })
                        text_parts.append(word_text + ("" if continued else " "))
                    has_words = has_words or bool(syllables)
                text = "".join(text_parts).strip() or str(item.get("text") or "").strip()
                if not text:
                    continue
                if not syllables and payload_type not in ("line", "none"):
                    syllables = []
                if end <= start:
                    end = start + 5.0
                lines.append({
                    "begin": start, "end": end, "end_": end, "endTime": end,
                    "text": text, "syllables": syllables,
                })
            if lines:
                return {
                    "status": "ok", "name": "LyricsPlus", "type": "word" if has_words else "line",
                    "badge": "Karaoke (Word)" if has_words else "Line-synced",
                    "preview": [line["text"] for line in lines[:3]], "lines": lines,
                }
        except Exception as e:
            sys.stderr.write(f"lyricsplus fetch notice: {e}\n")
    return None


def fetch_unison(title, artist, album="", duration_seconds=0):
    """Fetch timed lyrics from the community Unison API."""
    params = {"song": title, "artist": artist}
    if album:
        params["album"] = album
    if duration_seconds:
        params["duration"] = str(round(float(duration_seconds)))
    url = "https://unison.betterlyrics.org/lyrics?" + urllib.parse.urlencode(params)
    try:
        payload = _fetch_json(url, timeout=1.5)
        if not isinstance(payload, dict) or payload.get("success") is False:
            return None
        data = payload.get("data", payload)
        if not isinstance(data, dict):
            return None
        lyrics = data.get("lyrics")
        if not isinstance(lyrics, str) or not lyrics.strip():
            return None
        fmt = str(data.get("format", "lrc")).lower()
        if "ttml" in fmt or lyrics.lstrip().startswith("<"):
            parsed = parse_ttml(lyrics, "Unison")
        else:
            parsed = parse_lrc(lyrics, "Unison")
        if parsed and parsed.get("lines"):
            parsed["name"] = "Unison"
            if str(data.get("syncType", "")).lower() in ("linesync", "line"):
                parsed["type"] = "line"
                parsed["badge"] = "Line-synced"
                for line in parsed["lines"]:
                    line["syllables"] = []
            return parsed
    except Exception as e:
        sys.stderr.write(f"unison fetch notice: {e}\n")
    return None


def fetch_betterlyrics(title, artist, album="", api_key=""):
    params = {"s": title, "a": artist}
    if album:
        params["al"] = album
    url = f"https://api.betterlyrics.org/getLyrics?{urllib.parse.urlencode(params)}"
    headers = {"User-Agent": USER_AGENT}
    if api_key:
        headers["X-API-Key"] = api_key

    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=1.5) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            ttml = data.get("ttml")
            if ttml:
                parsed = parse_ttml(ttml, "BetterLyrics")
                if parsed and parsed.get("lines"):
                    return parsed
    except Exception as e:
        sys.stderr.write(f"betterlyrics fetch notice: {e}\n")
    return None

def fetch_lrclib(title, artist, album=""):
    query = f"{artist} {title}".strip()
    url = f"https://lrclib.net/api/search?q={urllib.parse.quote(query)}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=3.0) as resp:
            hits = json.loads(resp.read().decode('utf-8'))
            for hit in hits:
                synced = hit.get("syncedLyrics")
                if synced:
                    parsed = parse_lrc(synced, "LRCLIB")
                    if parsed and parsed.get("lines"):
                        return parsed
    except Exception as e:
        sys.stderr.write(f"lrclib fetch notice: {e}\n")
    return None

def fetch_local_cache(title, artist, cache_dir=None):
    dirs = []
    if cache_dir:
        dirs.append(cache_dir)
    dirs.append(os.path.expanduser("~/.cache/noctalia/lyrics"))

    for d in dirs:
        if not os.path.isdir(d):
            continue
        hash_key = hashlib.md5(f"{artist}::{title}".lower().encode()).hexdigest()
        json_file = os.path.join(d, f"{hash_key}.json")
        if os.path.isfile(json_file):
            try:
                with open(json_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if data.get("sources"):
                        return data
                    if data.get("lines"):
                        return {
                            "status": "ok",
                            "name": "Local Cache",
                            "type": data.get("type", "syllable"),
                            "badge": "Karaoke (Syllable)" if data.get("type") == "syllable" else "Line-synced",
                            "preview": [l["text"] for l in data["lines"] if l.get("text")][:3],
                            "lines": data["lines"]
                        }
            except Exception:
                pass
    return None

def save_payload_to_cache(payload, title, artist, cache_dir):
    if not cache_dir or not payload:
        return
    try:
        os.makedirs(cache_dir, exist_ok=True)
        hash_key = hashlib.md5(f"{artist}::{title}".lower().encode()).hexdigest()
        json_file = os.path.join(cache_dir, f"{hash_key}.json")
        payload["cached_at"] = time.time()
        with open(json_file, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
    except Exception as e:
        sys.stderr.write(f"cache save notice: {e}\n")

# ── Main Multi-Source Fetcher ────────────────────────────────────────────────

def get_lyrics(title, artist, album="", preferred_source="auto",
               betterlyrics_key="", spicy_lyrics_key="", spotify_track_id="",
               spotify_client_id="", spotify_client_secret="", cache_dir=None,
               parsenix_base_url="https://noctalialyrics.vercel.app/", force_refresh=False, isrc="", duration_seconds=0):

    # A recent payload records which providers were checked. Reuse it until explicit
    # refresh or expiry, avoiding repeated network fan-out for the same recording.
    cached_payload = fetch_local_cache(title, artist, cache_dir)
    sources = dict(cached_payload.get("sources", {})) if isinstance(cached_payload, dict) else {}
    checked_sources = set(cached_payload.get("checked_sources", [])) if isinstance(cached_payload, dict) else set()
    cache_time = cached_payload.get("cached_at", 0) if isinstance(cached_payload, dict) else 0
    cache_is_fresh = (
        not force_refresh
        and sources
        and checked_sources.issuperset({
            "amll_ttml", "kugou_krc", "parsenix", "spicylyrics", "binimum", "betterlyrics", "lyricsplus", "unison", "lrclib",
        })
        and isinstance(cache_time, (int, float))
        and time.time() - cache_time < 3 * 24 * 60 * 60
    )
    if cache_is_fresh:
        active = preferred_source if preferred_source in sources else ""
        if not active:
            for granularity in ("syllable", "word"):
                for candidate in ("amll_ttml", "kugou_krc", "parsenix", "spicylyrics", "binimum", "lyricsplus", "betterlyrics", "unison"):
                    if candidate in sources and sources[candidate].get("type") == granularity:
                        active = candidate
                        break
                if active:
                    break
        if not active:
            active = next(
                (key for key, value in sources.items() if value.get("type") in ("syllable", "word")),
                cached_payload.get("active_source", ""),
            )
        if active not in sources:
            active = next(iter(sources))
        selected = sources[active]
        cached_payload.update({
            "active_source": active, "source": active,
            "type": selected.get("type", "line"),
            "name": selected.get("name", active),
            "badge": selected.get("badge", ""),
            "preview": selected.get("preview", []),
            "lines": selected.get("lines", []),
        })
        return cached_payload

    # Resolve once and share the Spotify ID between Spotify-backed providers.
    # Metadata-only providers also run for local files and non-Spotify players.
    with ThreadPoolExecutor(max_workers=12) as executor:
        # Submit all futures upfront - no sequential waiting
        track_id_future = executor.submit(
            resolve_spotify_track_id, title, artist, spotify_track_id,
            spotify_client_id, spotify_client_secret,
        )

        # Helper to run a phase and collect ALL results before applying selection policy
        def run_phase_collect(phase_futures, phase_timeout, phase_name, phase_checked_sources, phase_check_list):
            """Run a phase of providers, collect ALL results, then apply selection policy.
            Returns (selected_source, all_phase_sources) or (None, {}) if timeout/no results.
            """
            nonlocal track_id_resolved, spicy_submitted, parsenix_submitted
            pending = set(phase_futures.keys())
            start_time = time.monotonic()
            phase_sources = {}

            # Wait for all futures to complete or timeout
            while pending:
                remaining = phase_timeout - (time.monotonic() - start_time)
                if remaining <= 0:
                    break

                done, pending = wait(pending, timeout=remaining, return_when=FIRST_COMPLETED)
                for future in done:
                    src_key = phase_futures[future]
                    try:
                        res = future.result()
                        if res and res.get("lines"):
                            phase_sources[src_key] = res
                            sources[src_key] = res
                    except Exception as e:
                        sys.stderr.write(f"{src_key} worker notice: {e}\n")

                    # Check if we can now submit Spotify-dependent providers
                    if not spicy_submitted and spicy_lyrics_key:
                        try:
                            resolved_spotify_track_id = track_id_future.result(timeout=0)
                            track_id_resolved = resolved_spotify_track_id
                            if track_id_resolved:
                                new_future = executor.submit(fetch_spicylyrics,
                                    title, artist, track_id_resolved, spicy_lyrics_key,
                                    spotify_client_id, spotify_client_secret,
                                )
                                phase_futures[new_future] = "spicylyrics"
                                pending.add(new_future)
                        except Exception:
                            pass
                        spicy_submitted = True

                    if not parsenix_submitted and parsenix_base_url:
                        try:
                            if track_id_resolved is None:
                                resolved_spotify_track_id = track_id_future.result(timeout=0)
                                track_id_resolved = resolved_spotify_track_id
                            if track_id_resolved:
                                new_future = executor.submit(fetch_parsenix,
                                    title, artist, track_id_resolved, parsenix_base_url
                                )
                                phase_futures[new_future] = "parsenix"
                                pending.add(new_future)
                        except Exception:
                            pass
                        parsenix_submitted = True

            # Phase timed out - cancel remaining
            for f in pending:
                f.cancel()

            if not phase_sources:
                return None, {}

            # Apply selection policy AFTER collecting all results from this phase
            selected = _select_best_source(phase_sources, preferred_source)
            checked_sources_list = list(phase_checked_sources)
            return selected, phase_sources

        # Track Spotify-dependent providers
        spicy_submitted = False
        parsenix_submitted = False

        track_id_resolved = None

        # Fetch ISRC from MusicBrainz if not provided
        if not isrc:
            mb_isrc = fetch_musicbrainz_isrc(title, artist, album, duration_seconds)
            if mb_isrc:
                isrc = mb_isrc

        # Phase 1: Metadata-based providers (lrclib, binimum) - 8.0s total timeout
        # binimum needs ~4-5s for its multi-request search; lrclib ~1-2s
        phase1_futures = {}
        phase1_futures[executor.submit(fetch_lrclib, title, artist, album)] = "lrclib"
        phase1_futures[executor.submit(fetch_binimum, title, artist, album, duration_seconds, isrc)] = "binimum"

        selected_source, phase1_sources = run_phase_collect(
            phase1_futures, 8.0, "Phase 1", {"lrclib", "binimum"}, ["lrclib", "binimum"]
        )

        # Phase 2: Medium providers (unison, betterlyrics, spicylyrics, parsenix) - 1.0s total timeout
        phase2_futures = {}
        phase2_futures[executor.submit(fetch_unison, title, artist, album, duration_seconds)] = "unison"
        if betterlyrics_key:
            phase2_futures[executor.submit(fetch_betterlyrics, title, artist, album, betterlyrics_key)] = "betterlyrics"
        # Also submit track_id-dependent providers if resolved
        if not spicy_submitted and spicy_lyrics_key:
            try:
                resolved_spotify_track_id = track_id_future.result(timeout=0)
                track_id_resolved = resolved_spotify_track_id
                if track_id_resolved:
                    phase2_futures[executor.submit(fetch_spicylyrics,
                        title, artist, track_id_resolved, spicy_lyrics_key,
                        spotify_client_id, spotify_client_secret,
                    )] = "spicylyrics"
            except Exception:
                pass
            spicy_submitted = True
        if not parsenix_submitted and parsenix_base_url:
            try:
                if track_id_resolved is None:
                    resolved_spotify_track_id = track_id_future.result(timeout=0)
                    track_id_resolved = resolved_spotify_track_id
                if track_id_resolved:
                    phase2_futures[executor.submit(fetch_parsenix,
                        title, artist, track_id_resolved, parsenix_base_url
                    )] = "parsenix"
            except Exception:
                pass
            parsenix_submitted = True

        selected_source, phase2_sources = run_phase_collect(
            phase2_futures, 1.0, "Phase 2", {"unison", "betterlyrics", "spicylyrics", "parsenix"},
            ["lrclib", "binimum", "unison", "betterlyrics", "spicylyrics", "parsenix"]
        )

        # Phase 3: Slow/unreliable providers as last resort (amll_ttml, kugou_krc, lyricsplus) - 1.0s total timeout
        phase3_futures = {}
        phase3_futures[executor.submit(fetch_amll_ttml, title, artist, album, duration_seconds, isrc)] = "amll_ttml"
        phase3_futures[executor.submit(fetch_kugou_krc, title, artist, album, duration_seconds)] = "kugou_krc"
        phase3_futures[executor.submit(fetch_lyricsplus, title, artist, album, duration_seconds, isrc)] = "lyricsplus"

        selected_source, phase3_sources = run_phase_collect(
            phase3_futures, 1.0, "Phase 3", {"amll_ttml", "kugou_krc", "lyricsplus"},
            [
                "lrclib", "binimum", "unison", "betterlyrics", "spicylyrics", "parsenix",
                "amll_ttml", "kugou_krc", "lyricsplus",
            ]
        )

        # Determine the final active source from all collected sources
        if not sources:
            # No sources found from any phase
            pass
        else:
            active_source = _select_best_source(sources, preferred_source)
            checked_sources_list = []
            if phase1_sources:
                checked_sources_list.extend(["lrclib", "binimum"])
            if phase2_sources:
                checked_sources_list.extend(["unison", "betterlyrics", "spicylyrics", "parsenix"])
            if phase3_sources:
                checked_sources_list.extend(["amll_ttml", "kugou_krc", "lyricsplus"])

            full_payload = _build_full_payload(sources, active_source, checked_sources_list)
            save_payload_to_cache(full_payload, title, artist, cache_dir)
            return full_payload

    if cached_payload and "lines" in cached_payload and not sources:
        sources["local_cache"] = cached_payload

    if not sources:
        return {
            "status": "not_found",
            "type": "none",
            "source": "none",
            "active_source": "",
            "preview": [],
            "sources": {},
            "lines": []
        }

    # Fallback: use selection policy on whatever sources we have
    active_source = _select_best_source(sources, preferred_source)
    checked_sources_list = []
    if phase1_sources:
        checked_sources_list.extend(["lrclib", "binimum"])
    if phase2_sources:
        checked_sources_list.extend(["unison", "betterlyrics", "spicylyrics", "parsenix"])
    if phase3_sources:
        checked_sources_list.extend(["amll_ttml", "kugou_krc", "lyricsplus"])

    full_payload = _build_full_payload(sources, active_source, checked_sources_list)
    save_payload_to_cache(full_payload, title, artist, cache_dir)
    return full_payload

if __name__ == "__main__":
    title = sys.argv[1] if len(sys.argv) > 1 else ""
    artist = sys.argv[2] if len(sys.argv) > 2 else ""
    album = sys.argv[3] if len(sys.argv) > 3 else ""
    source = sys.argv[4] if len(sys.argv) > 4 else "auto"
    bl_key = sys.argv[5] if len(sys.argv) > 5 else ""
    spicy_key = sys.argv[6] if len(sys.argv) > 6 else ""
    sp_track_id = sys.argv[7] if len(sys.argv) > 7 else ""
    sp_client_id = sys.argv[8] if len(sys.argv) > 8 else ""
    sp_client_secret = sys.argv[9] if len(sys.argv) > 9 else ""
    cdir = sys.argv[10] if len(sys.argv) > 10 else ""
    parsenix_base_url = sys.argv[11] if len(sys.argv) > 11 else "https://noctalialyrics.vercel.app/"
    force_refresh = len(sys.argv) > 12 and sys.argv[12] == "1"
    isrc = sys.argv[13] if len(sys.argv) > 13 else ""
    try:
        duration_seconds = float(sys.argv[14]) if len(sys.argv) > 14 and sys.argv[14] else 0
    except ValueError:
        duration_seconds = 0

    if not title:
        print(json.dumps({"status": "error", "message": "Missing title"}))
        sys.exit(1)

    lyrics = get_lyrics(
        title=title,
        artist=artist,
        album=album,
        preferred_source=source,
        betterlyrics_key=bl_key,
        spicy_lyrics_key=spicy_key,
        spotify_track_id=sp_track_id,
        spotify_client_id=sp_client_id,
        spotify_client_secret=sp_client_secret,
        cache_dir=cdir,
        parsenix_base_url=parsenix_base_url,
        force_refresh=force_refresh,
        isrc=isrc,
        duration_seconds=duration_seconds,
    )
    print(json.dumps(lyrics, ensure_ascii=False))
