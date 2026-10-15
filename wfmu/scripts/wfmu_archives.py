#!/usr/bin/env python3
"""Build the WFMU stream list the Noctalia WFMU plugin reads.

Network access (all over HTTPS to wfmu.org and its stream hosts):
  * https://wfmu.org/playlists            - the show index, to discover archive feeds
  * https://wfmu.org/archivefeed/mp3/*.xml - one RSS feed per show
  * each show's latest episode link       - resolved to a direct audio URL

The output is a tab-separated file of "<label>\\t<url>" lines: the WFMU live
streams first, then the most recent archive of every show, sorted by name.
Nothing is executed from the network; the fetched bytes are only parsed.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime
import email.utils
import hashlib
import html as htmlmod
import os
import re
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

PLAYLISTS_URL = "https://wfmu.org/playlists"
FEED_URL = "https://wfmu.org/archivefeed/mp3/{code}.xml"
USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) noctalia-wfmu-plugin"

# Public WFMU live streams. mpv accepts the .pls playlists directly.
LIVE_STREAMS = (
    ("WFMU 91.1 East Orange, NJ", "http://stream2.wfmu.org/freeform-128k"),
    ("WFMU Give the Drummer Radio", "http://stream0.wfmu.org/drummer"),
    ("WFMU Rock'n'Soul Radio", "https://wfmu.org/wfmu_rock.pls"),
    ("WFMU Sheena's Jungle Room", "https://wfmu.org/wfmu_sheena.pls"),
)

DEFAULT_CACHE_TTL = 3600
DEFAULT_MAX_AGE_DAYS = 30
WORKERS = 6
# Cap a single response so a misbehaving host cannot make us read forever.
MAX_BYTES = 8 * 1024 * 1024
# Drop cache files older than this, so the cache cannot grow without bound.
CACHE_MAX_AGE = 7 * 24 * 3600


class Fetcher:
    """HTTP GETs with a small on-disk cache and a few retries."""

    def __init__(self, cache_dir: str | None, ttl: int) -> None:
        self.cache_dir = cache_dir
        self.ttl = ttl
        if cache_dir:
            os.makedirs(cache_dir, exist_ok=True)
            self._prune()

    def _prune(self) -> None:
        """Drop cache files that are far too old to ever be reused."""
        cutoff = time.time() - CACHE_MAX_AGE
        try:
            names = os.listdir(self.cache_dir)
        except OSError:
            return
        for name in names:
            path = os.path.join(self.cache_dir, name)
            try:
                if os.path.getmtime(path) < cutoff:
                    os.remove(path)
            except OSError:
                pass

    def _cached(self, url: str) -> bytes | None:
        if not self.cache_dir or self.ttl <= 0:
            return None
        path = os.path.join(self.cache_dir, hashlib.sha256(url.encode()).hexdigest())
        if os.path.exists(path) and time.time() - os.path.getmtime(path) < self.ttl:
            with open(path, "rb") as handle:
                return handle.read()
        return None

    def _store(self, url: str, body: bytes) -> None:
        if not self.cache_dir or self.ttl <= 0:
            return
        path = os.path.join(self.cache_dir, hashlib.sha256(url.encode()).hexdigest())
        tmp = path + ".tmp"
        with open(tmp, "wb") as handle:
            handle.write(body)
        os.replace(tmp, path)

    def get(self, url: str, attempts: int = 3) -> bytes | None:
        cached = self._cached(url)
        if cached is not None:
            return cached
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        for attempt in range(attempts):
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    body = response.read(MAX_BYTES + 1)
                if body and len(body) <= MAX_BYTES:
                    self._store(url, body)
                    return body
            except (urllib.error.URLError, TimeoutError, OSError):
                pass
            time.sleep(1 + attempt)
        return None


def parse_shows(page: str) -> dict[str, dict[str, str]]:
    """Map each show code to its display name and mp3 archive feed id."""
    shows: dict[str, dict[str, str]] = {}
    spans = re.split(r'<span class="KDBFavIcon KDBprogram" id="KDBprogram-([A-Za-z0-9]+)">', page)
    for index in range(1, len(spans), 2):
        code = spans[index]
        body = spans[index + 1]
        name_match = re.search(r"<b>([^<]*)</b>", body)
        name = (
            htmlmod.unescape(re.sub(r"\s+", " ", name_match.group(1)).strip())
            if name_match
            else code
        )
        feed = re.search(r"/archivefeed/mp3/([A-Za-z0-9]+)\.xml", body)
        if feed and code not in shows:
            shows[code] = {"name": name, "feed": feed.group(1)}
    return shows


def latest_episode(feed_bytes: bytes) -> dict[str, str] | None:
    # Refuse any feed that declares entities: those enable "billion laughs"
    # style expansion, which a plain ElementTree parser would happily run.
    if b"<!ENTITY" in feed_bytes:
        return None
    root = ET.fromstring(feed_bytes)
    items = root.findall(".//item")
    if not items:
        return None
    item = items[0]
    return {
        "title": (item.findtext("title") or "").strip(),
        "link": (item.findtext("link") or "").strip(),
        "pubdate": (item.findtext("pubDate") or "").strip(),
    }


def resolve_stream(fetcher: Fetcher, listen_url: str) -> str | None:
    """Follow a show's listen link to the first line that is a direct URL."""
    if listen_url.endswith((".mp3", ".mp4")):
        return listen_url
    body = fetcher.get(listen_url, attempts=4)
    if body is None:
        return None
    text = body.decode("utf-8", "replace").strip()
    if not text:
        return None
    first = text.splitlines()[0].strip()
    if first.startswith(("http://", "https://")):
        return first
    return None


def episode_date(episode: dict[str, str]) -> datetime.datetime | None:
    match = re.search(r"([A-Z][a-z]{2} \d{1,2}, \d{4})\s*\)?\s*$", episode["title"])
    if match:
        try:
            return datetime.datetime.strptime(match.group(1), "%b %d, %Y")
        except ValueError:
            pass
    try:
        parsed = email.utils.parsedate_to_datetime(episode["pubdate"])
    except (TypeError, ValueError):
        return None
    if parsed is None:
        return None
    return parsed.replace(tzinfo=None)


def collect(fetcher: Fetcher, max_age_days: int) -> list[tuple[str, str, str]]:
    """Return (name, date, url) for the latest fresh archive of every show."""
    page = fetcher.get(PLAYLISTS_URL)
    if page is None:
        raise SystemExit("failed to fetch the WFMU playlists page")
    shows = parse_shows(page.decode("utf-8", "replace"))
    print(f"shows with an mp3 archive feed: {len(shows)}", file=sys.stderr, flush=True)

    cutoff = datetime.datetime.now() - datetime.timedelta(days=max_age_days)
    results: list[tuple[str, str, str]] = []

    def one(code: str, info: dict[str, str]) -> tuple[str, str, str] | None:
        feed = fetcher.get(FEED_URL.format(code=info["feed"]))
        if feed is None:
            return None
        try:
            episode = latest_episode(feed)
        except ET.ParseError:
            return None
        if not episode:
            return None
        aired = episode_date(episode)
        if aired is not None and aired < cutoff:
            return None
        stream = resolve_stream(fetcher, episode["link"])
        if not stream:
            return None
        date = aired.strftime("%b %-d, %Y") if aired is not None else ""
        return (info["name"], date, stream)

    with cf.ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = [pool.submit(one, code, info) for code, info in shows.items()]
        for future in cf.as_completed(futures):
            try:
                entry = future.result()
            except Exception:  # a single bad feed must not sink the run
                entry = None
            if entry:
                results.append(entry)

    results.sort(key=lambda row: row[0].lower())
    print(f"resolved archives: {len(results)}", file=sys.stderr, flush=True)
    return results


def build_tsv(archives: list[tuple[str, str, str]]) -> str:
    lines: list[str] = []
    for name, url in LIVE_STREAMS:
        lines.append(f"{name}\t{url}")
    for name, date, url in archives:
        label = f"{name} ({date})" if date else name
        lines.append(f"{label}\t{url}")
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", help="TSV file to write (default: stdout)")
    parser.add_argument(
        "--cache",
        default=os.path.join(
            os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
            "noctalia-wfmu",
        ),
        help="cache directory for fetched pages",
    )
    parser.add_argument("--cache-ttl", type=int, default=DEFAULT_CACHE_TTL, help="cache TTL in seconds")
    parser.add_argument("--no-cache", action="store_true", help="ignore and do not write the cache")
    parser.add_argument(
        "--max-age-days",
        type=int,
        default=DEFAULT_MAX_AGE_DAYS,
        help="skip shows whose latest episode is older than this",
    )
    args = parser.parse_args(argv)

    fetcher = Fetcher(None if args.no_cache else args.cache, args.cache_ttl)
    output = build_tsv(collect(fetcher, args.max_age_days))

    if args.out:
        directory = os.path.dirname(os.path.abspath(args.out))
        os.makedirs(directory, exist_ok=True)
        tmp = args.out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(output)
        os.replace(tmp, args.out)
        print(f"wrote {args.out}", file=sys.stderr, flush=True)
    else:
        sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
