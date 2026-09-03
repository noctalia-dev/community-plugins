#!/usr/bin/env python3
"""Spotify Web API backend for the Noctalia artwork launcher plugin."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

SPOTIFY_DESKTOP = "com.spotify.Client"
SPOTIFY_API = "https://api.spotify.com/v1"
SPOTIFY_TOKEN_URL = "https://accounts.spotify.com/api/token"
SPOTIFY_CLIENT_ID = "d420a117a32841c2b3474932e49fb54b"
TOKEN_PATH = Path.home() / ".cache/spotify-player/user_client_token.json"
COVER_CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "noctalia-spotify" / "covers"
COVER_LIMIT_BYTES = 100 * 1024 * 1024
COVER_MAX_AGE_SECONDS = 30 * 24 * 60 * 60


class SpotifyApiError(RuntimeError):
    def __init__(self, status: int, detail: str) -> None:
        super().__init__(detail)
        self.status = status


def notify(summary: str, body: str) -> None:
    subprocess.run(
        ["notify-send", "--app-name=Spotify", summary, body],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def display(value: Any) -> str:
    return str(value).replace("\t", " ").replace("\n", " ").strip()


def token_expiring(token: dict[str, Any]) -> bool:
    expires_at = token.get("expires_at")
    if not isinstance(expires_at, str):
        return True
    try:
        expiry = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
    except ValueError:
        return True
    return expiry <= datetime.now(timezone.utc) + timedelta(seconds=30)


def save_token(token: dict[str, Any]) -> None:
    TOKEN_PATH.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=TOKEN_PATH.parent, delete=False
    ) as temporary:
        json.dump(token, temporary)
        temporary.write("\n")
        temporary.flush()
        os.fchmod(temporary.fileno(), 0o600)
        temporary_path = Path(temporary.name)
    temporary_path.replace(TOKEN_PATH)


def refresh_token(token: dict[str, Any]) -> dict[str, Any]:
    refresh = token.get("refresh_token")
    if not isinstance(refresh, str) or not refresh:
        raise SpotifyApiError(401, "Spotify authorization expired. Run spotify_player authenticate.")
    data = urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": SPOTIFY_CLIENT_ID,
        }
    ).encode()
    request = Request(SPOTIFY_TOKEN_URL, data=data, method="POST")
    request.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urlopen(request, timeout=15) as response:
            refreshed = json.load(response)
    except HTTPError as error:
        raise SpotifyApiError(error.code, "Spotify authorization could not be refreshed.") from error
    except URLError as error:
        raise SpotifyApiError(0, f"Could not reach Spotify: {error.reason}") from error

    token.update(refreshed)
    token["refresh_token"] = refreshed.get("refresh_token", refresh)
    token["expires_at"] = (
        datetime.now(timezone.utc) + timedelta(seconds=int(token.get("expires_in", 3600)))
    ).isoformat()
    save_token(token)
    return token


def access_token() -> str:
    try:
        token = json.loads(TOKEN_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SpotifyApiError(401, "Spotify is not authorized. Run spotify_player authenticate.") from error
    if token_expiring(token):
        token = refresh_token(token)
    access = token.get("access_token")
    if not isinstance(access, str) or not access:
        raise SpotifyApiError(401, "Spotify is not authorized. Run spotify_player authenticate.")
    return access


def api_request(
    method: str,
    path: str,
    *,
    query: dict[str, str] | None = None,
    payload: dict[str, Any] | None = None,
) -> Any:
    url = SPOTIFY_API + path
    if query:
        url += "?" + urlencode(query)
    data = json.dumps(payload).encode() if payload is not None else None
    request = Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {access_token()}")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urlopen(request, timeout=20) as response:
            return None if response.status == 204 else json.load(response)
    except HTTPError as error:
        detail = "Spotify rejected the request."
        try:
            body = json.load(error)
            detail = body.get("error", {}).get("message", detail)
        except (json.JSONDecodeError, AttributeError):
            pass
        raise SpotifyApiError(error.code, detail) from error
    except URLError as error:
        raise SpotifyApiError(0, f"Could not reach Spotify: {error.reason}") from error


def cache_cover(album_id: str, image_url: str) -> str | None:
    if not album_id.isalnum() or not image_url.startswith("https://"):
        return None
    COVER_CACHE.mkdir(parents=True, exist_ok=True)
    destination = COVER_CACHE / f"{album_id}-{hashlib.sha256(image_url.encode()).hexdigest()[:16]}.webp"
    if destination.exists():
        destination.touch()
        return str(destination)

    request = Request(image_url, headers={"Accept": "image/webp,image/*"})
    try:
        with urlopen(request, timeout=15) as response:
            content = response.read(2 * 1024 * 1024 + 1)
        if not content or len(content) > 2 * 1024 * 1024:
            return None
        with tempfile.NamedTemporaryFile(dir=COVER_CACHE, delete=False) as temporary:
            temporary.write(content)
            temporary_path = Path(temporary.name)
        temporary_path.replace(destination)
        return str(destination)
    except (HTTPError, URLError, OSError):
        return None


def prune_cover_cache() -> None:
    if not COVER_CACHE.exists():
        return
    now = time.time()
    files = [path for path in COVER_CACHE.iterdir() if path.is_file()]
    for path in files:
        try:
            if now - path.stat().st_mtime > COVER_MAX_AGE_SECONDS:
                path.unlink()
        except OSError:
            pass
    files = [path for path in COVER_CACHE.iterdir() if path.is_file()]
    sized = sorted(
        ((path.stat().st_mtime, path.stat().st_size, path) for path in files),
        key=lambda item: item[0],
    )
    total = sum(size for _, size, _ in sized)
    for _, size, path in sized:
        if total <= COVER_LIMIT_BYTES:
            break
        try:
            path.unlink()
            total -= size
        except OSError:
            pass


def search(query: str) -> list[dict[str, str]]:
    response = api_request(
        "GET",
        "/search",
        query={"q": query, "type": "track", "limit": "50"},
    )
    selected_tracks: list[dict[str, Any]] = []
    selected_albums: set[str] = set()
    for track in response.get("tracks", {}).get("items", []):
        if not isinstance(track, dict):
            continue
        album = track.get("album")
        track_id = track.get("id")
        album_id = album.get("id") if isinstance(album, dict) else None
        if (
            not isinstance(track_id, str)
            or not track_id
            or not isinstance(album_id, str)
            or not album_id
            or album_id in selected_albums
        ):
            continue
        selected_tracks.append(track)
        selected_albums.add(album_id)
        if len(selected_tracks) == 12:
            break

    covers: dict[str, tuple[str, str]] = {}
    for track in selected_tracks:
        album = track["album"]
        album_id = album["id"]
        images = album.get("images") or []
        if images:
            image_url = images[0].get("url")
            if isinstance(image_url, str):
                covers[album_id] = (album_id, image_url)

    with ThreadPoolExecutor(max_workers=4) as executor:
        cover_paths = dict(
            zip(covers, executor.map(lambda pair: cache_cover(*pair), covers.values()))
        )

    results: list[dict[str, str]] = []
    for track in selected_tracks:
        album = track["album"]
        album_id = album["id"]
        artists = ", ".join(
            display(artist.get("name", ""))
            for artist in track.get("artists", [])
            if isinstance(artist, dict) and artist.get("name")
        )
        result = {
            "id": track["id"],
            "title": display(track.get("name", "Unknown track")),
            "subtitle": " — ".join(
                part for part in (artists, display(album.get("name", ""))) if part
            ),
        }
        cover_path = cover_paths.get(album_id)
        if cover_path:
            result["icon"] = cover_path
        results.append(result)
    prune_cover_cache()
    return results


def choose_playback_device() -> str | None:
    devices = api_request("GET", "/me/player/devices").get("devices", [])
    valid = [device for device in devices if isinstance(device, dict) and device.get("id")]
    for device in valid:
        if device.get("is_active"):
            return str(device["id"])
    for device in valid:
        if device.get("type") == "Computer":
            return str(device["id"])
    return str(valid[0]["id"]) if valid else None


def spotify_desktop_running() -> bool:
    return subprocess.run(
        ["pgrep", "-x", "spotify"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0


def ensure_playback_device() -> str | None:
    device = choose_playback_device()
    if device:
        return device
    if not spotify_desktop_running():
        subprocess.Popen(
            ["gtk-launch", SPOTIFY_DESKTOP],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    for _ in range(30):
        time.sleep(1)
        device = choose_playback_device()
        if device:
            return device
    return None


def play(track_id: str) -> None:
    if not track_id.isalnum():
        raise SpotifyApiError(400, "Invalid Spotify track identifier.")
    device = ensure_playback_device()
    if not device:
        raise SpotifyApiError(404, "No Spotify playback device is available.")
    api_request(
        "PUT",
        "/me/player/play",
        query={"device_id": device},
        payload={"uris": [f"spotify:track:{track_id}"]},
    )


def main(arguments: list[str]) -> int:
    try:
        if len(arguments) == 2 and arguments[0] == "search":
            print(json.dumps(search(arguments[1]), ensure_ascii=False))
            return 0
        if len(arguments) == 2 and arguments[0] == "play":
            play(arguments[1])
            return 0
    except (SpotifyApiError, OSError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print("Usage: spotify_backend.py {search QUERY|play TRACK_ID}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
