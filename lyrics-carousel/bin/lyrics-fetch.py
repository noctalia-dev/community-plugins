#!/usr/bin/env python3
"""Fetch synced lyrics for a track and print them as JSON.

The plugin needs two things the declarative UI cannot do on its own: talk HTTP
and parse LRC. This adapter does both and prints a stable JSON document, so the
Luau side never sees a provider's format:

    {"ok": true, "source": "lrclib", "synced": true, "cached": false,
     "lines": [{"start": 12.34, "end": 15.2, "text": "hello",
                "chars": [12.34, 12.5, 12.7, 12.9]}]}

`chars` is absent when the line carries no word timings: the renderer then
fills the whole line at once. A line whose text is empty is an explicit
instrumental marker; the renderer shows the placeholder for it.

Usage:
    python3 lyrics-fetch.py --title T --artist A --duration 215 [--force]

The exit code is always 0: a failure is data ({"ok": false, "error": ...}),
not something the caller has to interpret from a status.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

APP = "lyrics-carousel"
VERSION = "3.0.0"
USER_AGENT = f"{APP}/{VERSION} (Noctalia plugin)"

LRCLIB_GET = "https://lrclib.net/api/get"
LRCLIB_SEARCH = "https://lrclib.net/api/search"
CACHE_TTL = 24 * 3600
DEFAULT_TIMEOUT = 8.0

# [mm:ss.xx] and [mm:ss:xx]: both show up in the wild.
TIMESTAMP = re.compile(r"\[(\d+):(\d+(?:[.:]\d+)?)\]")
# <mm:ss.xx>: word timing of the character group that follows.
ANGLE = re.compile(r"<(\d+):(\d+(?:[.:]\d+)?)>")

FULLWIDTH = str.maketrans(
    {
        "，": ",",
        "。": ".",
        "、": ",",
        "：": ":",
        "；": ";",
        "！": "!",
        "？": "?",
        "（": "(",
        "）": ")",
        "【": "[",
        "】": "]",
        "「": '"',
        "」": '"',
        "“": '"',
        "”": '"',
        "‘": "'",
        "’": "'",
        "—": "-",
        "…": "...",
        "　": " ",
    }
)


def normalize_text(value: str) -> str:
    """Fold full-width punctuation to ASCII, as the old renderer did.

    Providers mix Chinese punctuation into Latin lyrics; the label renders
    those glyphs at a different width and the line jumps.
    """
    if not value:
        return ""
    return value.translate(FULLWIDTH).strip()


def _seconds(minutes: str, seconds: str) -> float:
    return int(minutes) * 60 + float(seconds.replace(":", "."))


def split_word_timings(body: str):
    """Split an enhanced LRC line into plain text and one time per character.

    Returns (text, chars) where chars has the same length as text. Tags that
    do not open a new group do not create characters, so the two stay aligned;
    a tag at the very start sets the time of the first character.
    """
    text = []
    chars = []
    current = None
    position = 0
    for match in ANGLE.finditer(body):
        # Characters before the tag keep the previous time.
        chunk = body[position : match.start()]
        for character in chunk:
            text.append(character)
            chars.append(current)
        current = _seconds(match.group(1), match.group(2))
        position = match.end()
    for character in body[position:]:
        text.append(character)
        chars.append(current)
    text = "".join(text)
    if any(value is None for value in chars):
        return text, None
    return text, chars


def parse_lrc(text: str):
    """Parse LRC into [{start, end, text, chars?}], ordered by start.

    Lines with an empty text are kept: they are how a provider marks a gap.
    `end` is the start of the next line, with no artificial cap: a 90 second
    instrumental break is a 90 second break, and the renderer decides what to
    do with it.
    """
    lines = []
    for raw in (text or "").splitlines():
        stamps = list(TIMESTAMP.finditer(raw))
        if not stamps:
            continue
        body = raw[stamps[-1].end() :]
        plain, chars = split_word_timings(body)
        plain = normalize_text(plain)
        for stamp in stamps:
            lines.append(
                {
                    "start": _seconds(stamp.group(1), stamp.group(2)),
                    "text": plain,
                    "chars": chars,
                }
            )
    lines.sort(key=lambda item: item["start"])
    for index, item in enumerate(lines):
        if index + 1 < len(lines):
            item["end"] = lines[index + 1]["start"]
        else:
            item["end"] = item["start"]
    return lines


def plain_lines(text: str, duration: float):
    """Evenly spaced lines for providers that only return plain lyrics."""
    rows = [normalize_text(row) for row in (text or "").splitlines() if row.strip()]
    if not rows:
        return []
    step = duration / len(rows) if duration and duration > 0 else 4.0
    lines = []
    for index, row in enumerate(rows):
        start = index * step
        lines.append({"start": start, "end": start + step, "text": row})
    return lines


def cache_dir() -> str:
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(
        os.path.expanduser("~"), ".cache"
    )
    return os.path.join(base, APP)


def cache_key(title: str, artist: str, duration: float) -> str:
    seed = f"{title}\x1f{artist}\x1f{int(duration or 0)}".lower()
    return hashlib.sha1(seed.encode("utf-8")).hexdigest()


def read_cache(path: str):
    try:
        if time.time() - os.path.getmtime(path) > CACHE_TTL:
            return None
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        if isinstance(data, dict) and data.get("ok") and data.get("lines"):
            return data
    except (OSError, ValueError):
        return None
    return None


def write_cache(path: str, data) -> None:
    """Write atomically: a half written cache entry is worse than none."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        temporary = path + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False)
        os.replace(temporary, path)
    except OSError:
        pass


def _get(url: str, timeout: float):
    request = urllib.request.Request(
        url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8", "replace"))


def _query(title: str, artist: str, duration: float) -> str:
    params = {"track_name": title, "artist_name": artist}
    if duration and duration > 0:
        params["duration"] = str(int(round(duration)))
    return urllib.parse.urlencode(params)


def fetch(title: str, artist: str, duration: float, timeout: float = DEFAULT_TIMEOUT):
    """Return a result dict, never raising on a network or format problem."""
    if not title.strip():
        return {"ok": False, "error": "no track title"}
    # Some players put "Title - Artist" in the title and report no artist at
    # all. Splitting it is the difference between finding the lyrics and not.
    if not artist.strip() and " - " in title:
        title, artist = (part.strip() for part in title.rsplit(" - ", 1))

    payload = None
    if artist.strip():
        try:
            payload = _get(f"{LRCLIB_GET}?{_query(title, artist, duration)}", timeout)
        except urllib.error.HTTPError as error:
            if error.code != 404:
                return {"ok": False, "error": f"lrclib get: HTTP {error.code}"}
        except (urllib.error.URLError, OSError, ValueError) as error:
            return {"ok": False, "error": f"lrclib get: {error}"}
    # Some MPRIS players expose no artist at all. /api/get demands one, so go
    # straight to the search endpoint, which is happy with the title alone.

    if not isinstance(payload, dict) or not payload.get("syncedLyrics"):
        # /api/get only answers an exact match. The search endpoint is more
        # forgiving and returns a list ordered by relevance.
        try:
            results = _get(f"{LRCLIB_SEARCH}?{_query(title, artist, duration)}", timeout)
        except (urllib.error.HTTPError, urllib.error.URLError, OSError, ValueError) as error:
            results = None
            if payload is None:
                return {"ok": False, "error": f"lrclib search: {error}"}
        chosen = None
        for candidate in results or []:
            if isinstance(candidate, dict) and candidate.get("syncedLyrics"):
                chosen = candidate
                break
        if chosen is not None:
            payload = chosen
        elif isinstance(results, list) and results:
            for candidate in results:
                if isinstance(candidate, dict) and candidate.get("plainLyrics"):
                    payload = candidate
                    break

    if not isinstance(payload, dict):
        return {"ok": False, "error": "not found"}

    synced_text = payload.get("syncedLyrics") or ""
    lines = parse_lrc(synced_text)
    if lines:
        return {
            "ok": True,
            "source": "lrclib",
            "synced": True,
            "lines": lines,
        }

    plain = plain_lines(payload.get("plainLyrics") or "", duration)
    if plain:
        return {
            "ok": True,
            "source": "lrclib",
            "synced": False,
            "lines": plain,
        }
    return {"ok": False, "error": "not found"}


def result_for(title: str, artist: str, duration: float, force: bool, timeout: float):
    path = os.path.join(cache_dir(), cache_key(title, artist, duration) + ".json")
    if not force:
        cached = read_cache(path)
        if cached is not None:
            cached["cached"] = True
            return cached
    result = fetch(title, artist, duration, timeout)
    if result.get("ok"):
        write_cache(path, result)
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Fetch synced lyrics as JSON.")
    parser.add_argument("--title", default="")
    parser.add_argument("--artist", default="")
    parser.add_argument("--duration", type=float, default=0.0)
    parser.add_argument("--force", action="store_true", help="ignore the cache")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    parser.add_argument("--version", action="version", version=f"{APP} {VERSION}")
    args = parser.parse_args(argv)

    try:
        result = result_for(
            args.title, args.artist, args.duration, args.force, args.timeout
        )
    except Exception as error:  # noqa: BLE001 - the caller reads `ok`
        result = {"ok": False, "error": str(error)}
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
