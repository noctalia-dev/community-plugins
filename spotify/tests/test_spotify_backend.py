"""Isolated Spotify HTTP and filesystem regression tests; no real credentials or playback."""
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import ExitStack
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from unittest.mock import Mock, patch

import spotify_backend as backend


class SpotifyBackendTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.token_path = self.root / "token.json"
        self.write_token(datetime.now(timezone.utc) + timedelta(hours=1))
        self.config_path = self.root / "app.toml"
        self.config_path.write_text('client_id = "fixture-application"\n')
        self.calls = []
        self.responses = []
        self.authorized_client_id = None
        self.maximum_search_limit = None
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def respond(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                owner.calls.append((self.command, self.path, body))
                path = urlsplit(self.path)
                if (
                    self.command == "POST"
                    and path.path == "/token"
                    and owner.authorized_client_id is not None
                    and parse_qs(body.decode()).get("client_id") != [owner.authorized_client_id]
                ):
                    status, payload, headers, delay = 400, {"error": "invalid_client"}, {}, 0
                elif (
                    path.path == "/search"
                    and owner.maximum_search_limit is not None
                    and int(parse_qs(path.query).get("limit", ["0"])[0]) > owner.maximum_search_limit
                ):
                    status, payload, headers, delay = (
                        400, {"error": {"message": "Search limit exceeds development-mode maximum"}}, {}, 0
                    )
                else:
                    status, payload, headers, delay = (
                        owner.responses.pop(0) if owner.responses else (200, {}, {}, 0)
                    )
                time.sleep(delay)
                content = json.dumps(payload).encode()
                try:
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(content)))
                    for name, value in headers.items():
                        self.send_header(name, value)
                    self.end_headers()
                    self.wfile.write(content)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            do_GET = respond
            do_POST = respond
            do_PUT = respond

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True
        )
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.cache = self.root / "noctalia-spotify"
        self.covers = self.cache / "covers"
        self.covers.mkdir(parents=True)
        for name, value in (
            ("SPOTIFY_API", self.url),
            ("SPOTIFY_TOKEN_URL", self.url + "/token"),
            ("TOKEN_PATH", self.token_path),
            ("PLAYER_CONFIG_PATH", self.config_path),
            ("COVER_CACHE", self.covers),
            ("RATE_LIMIT_PATH", self.cache / "rate-limit.json"),
        ):
            self.stack.enter_context(patch.object(backend, name, value, create=True))

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def write_token(self, expiry):
        self.token_path.write_text(json.dumps({
            "access_token": "fixture-access",
            "refresh_token": "fixture-refresh",
            "expires_at": expiry.isoformat(),
        }))

    def limited_response(self, retry_after="60"):
        headers = {} if retry_after is None else {"Retry-After": retry_after}
        return 429, {"error": {"message": "API rate limit exceeded"}}, headers, 0

    def test_rate_limit_blocks_a_separate_helper_before_authentication(self):
        self.responses.append(self.limited_response("86400"))
        started = time.time()
        with self.assertRaises(backend.SpotifyApiError) as failure:
            backend.api_request("GET", "/search")
        self.assertEqual(failure.exception.status, 429)
        self.assertGreaterEqual(backend.rate_limit_deadline(), started + 86400)
        # An expired token must not cause another request during the cooldown.
        self.write_token(datetime.now(timezone.utc) - timedelta(hours=1))
        code = '''import json, sys
from pathlib import Path
import spotify_backend as backend
backend.SPOTIFY_API = sys.argv[1]
backend.SPOTIFY_TOKEN_URL = sys.argv[1] + '/token'
backend.TOKEN_PATH = Path(sys.argv[2])
try:
    backend.api_request('GET', '/search')
except backend.SpotifyApiError as error:
    print(json.dumps({'status': error.status}))
else:
    print(json.dumps({'status': 200}))
'''
        result = subprocess.run(
            [sys.executable, "-c", code, self.url, str(self.token_path)],
            cwd=Path(backend.__file__).parent,
            env={**os.environ, "XDG_CACHE_HOME": str(self.root)},
            capture_output=True, text=True, check=True, timeout=5,
        )
        self.assertEqual(json.loads(result.stdout)["status"], 429)
        self.assertEqual([path for _, path, _ in self.calls], ["/search"])

    def test_expired_cooldown_allows_a_new_request(self):
        self.responses.extend([self.limited_response(), (200, {"tracks": {"items": []}}, {}, 0)])
        with self.assertRaises(backend.SpotifyApiError):
            backend.api_request("GET", "/search")
        backend.RATE_LIMIT_PATH.write_text(json.dumps({"retry_at": time.time() - 1}))
        self.assertEqual(backend.search("anything"), [])
        self.assertEqual(len(self.calls), 2)

    def test_bad_retry_after_still_blocks_immediate_requests(self):
        for header in (None, "invalid", "-5", "0"):
            with self.subTest(header=header):
                backend.RATE_LIMIT_PATH.unlink(missing_ok=True)
                count = len(self.calls)
                self.responses.append(self.limited_response(header))
                for _ in range(2):
                    with self.assertRaises(backend.SpotifyApiError) as failure:
                        backend.api_request("GET", "/search")
                    self.assertEqual(failure.exception.status, 429)
                retry_at = backend.rate_limit_deadline()
                self.assertTrue(math.isfinite(retry_at))
                self.assertGreater(retry_at, time.time())
                self.assertEqual(len(self.calls), count + 1)

    def test_overlapping_helpers_cannot_shorten_a_cooldown(self):
        deadlines = [time.time() + 3600, time.time() + 5]
        code = "import sys, spotify_backend as b; b.rate_limit_deadline(float(sys.argv[1]))"
        processes = [subprocess.Popen(
            [sys.executable, "-c", code, str(deadline)],
            cwd=Path(backend.__file__).parent,
            env={**os.environ, "XDG_CACHE_HOME": str(self.root)},
        ) for deadline in deadlines]
        for process in processes:
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual(backend.rate_limit_deadline(), max(deadlines))
        with self.assertRaises(backend.SpotifyApiError) as failure:
            backend.api_request("GET", "/search")
        self.assertEqual(failure.exception.status, 429)
        self.assertEqual(self.calls, [])

    def test_token_endpoint_rate_limit_also_blocks_followup_requests(self):
        self.write_token(datetime.now(timezone.utc) - timedelta(hours=1))
        self.responses.append(self.limited_response())
        for _ in range(2):
            with self.assertRaises(backend.SpotifyApiError) as failure:
                backend.api_request("GET", "/search")
            self.assertEqual(failure.exception.status, 429)
        self.assertEqual([(method, path) for method, path, _ in self.calls], [("POST", "/token")])

    def test_search_works_with_development_mode_result_limit(self):
        self.maximum_search_limit = 10
        self.responses.append((200, {"tracks": {"items": [{
            "id": "track1", "name": "One track", "artists": [{"name": "Artist"}],
            "album": {"id": "album1", "name": "Album", "images": []},
        }]}}, {}, 0))
        self.assertEqual(backend.search("one track"), [
            {"id": "track1", "title": "One track", "subtitle": "Artist — Album"},
        ])

    def test_expired_token_uses_the_configured_application(self):
        self.authorized_client_id = "personal-application"
        self.config_path.write_text('client_id = "personal-application"\n')
        self.write_token(datetime.now(timezone.utc) - timedelta(hours=1))
        self.responses.extend([
            (200, {"access_token": "renewed-access", "expires_in": 3600}, {}, 0),
            (200, {"tracks": {"items": [{
                "id": "track1", "name": "One track", "artists": [{"name": "Artist"}],
                "album": {"id": "album1", "name": "Album", "images": []},
            }]}}, {}, 0),
        ])
        self.assertEqual(backend.search("one track"), [
            {"id": "track1", "title": "One track", "subtitle": "Artist — Album"},
        ])
        saved_token = json.loads(self.token_path.read_text())
        self.assertEqual(saved_token["access_token"], "renewed-access")
        self.assertEqual(saved_token["refresh_token"], "fixture-refresh")

    def test_missing_application_configuration_does_not_send_refresh_credentials(self):
        self.config_path.unlink()
        self.write_token(datetime.now(timezone.utc) - timedelta(hours=1))
        with self.assertRaises(backend.SpotifyApiError) as failure:
            backend.search("one track")
        self.assertEqual(failure.exception.status, 401)
        self.assertEqual(self.calls, [])

    def test_disappearing_cache_entry_does_not_discard_search_results(self):
        self.responses.append((200, {"tracks": {"items": [{
            "id": "track1", "name": "One track", "artists": [{"name": "Artist"}],
            "album": {"id": "album1", "name": "Album", "images": []},
        }]}}, {}, 0))
        vanished = Mock(spec=Path)
        vanished.is_file.return_value = True
        vanished.stat.side_effect = FileNotFoundError("concurrent cache deletion")
        original_iterdir = Path.iterdir
        covers = self.covers
        def snapshot(path):
            return iter([vanished]) if path == covers else original_iterdir(path)
        with patch.object(Path, "iterdir", snapshot):
            results = backend.search("one track")
        self.assertEqual(results, [{"id": "track1", "title": "One track", "subtitle": "Artist — Album"}])

    def test_cache_expiration_and_size_limit_preserve_newest_artwork(self):
        old, older, newest = [self.covers / name for name in ("expired.webp", "older.webp", "newest.webp")]
        for path in (old, older, newest):
            path.write_bytes(b"cover")
        now = time.time()
        os.utime(old, (now - backend.COVER_MAX_AGE_SECONDS - 1,) * 2)
        os.utime(older, (now - 10,) * 2)
        with patch.object(backend, "COVER_LIMIT_BYTES", 5):
            backend.prune_cover_cache()
        self.assertFalse(old.exists())
        self.assertFalse(older.exists())
        self.assertEqual(newest.read_bytes(), b"cover")

    def test_late_device_is_not_played_after_discovery_deadline(self):
        self.responses.append((200, {"devices": [{"id": "late-device", "is_active": True}]}, {}, 0.2))
        with patch.object(backend, "DEVICE_WAIT_SECONDS", 0.05, create=True):
            with self.assertRaises(backend.SpotifyApiError) as failure:
                backend.play("track1")
        self.assertEqual(failure.exception.status, 404)
        self.assertEqual([(method, path) for method, path, _ in self.calls], [("GET", "/me/player/devices")])

    def test_token_refresh_uses_the_same_discovery_deadline(self):
        self.write_token(datetime.now(timezone.utc) - timedelta(hours=1))
        self.responses.append((200, {"access_token": "refreshed", "expires_in": 3600}, {}, 0.2))
        with patch.object(backend, "DEVICE_WAIT_SECONDS", 0.05, create=True):
            with self.assertRaises(backend.SpotifyApiError) as failure:
                backend.play("track1")
        self.assertEqual(failure.exception.status, 404)
        self.assertEqual([(method, path) for method, path, _ in self.calls], [("POST", "/token")])


if __name__ == "__main__":
    unittest.main()
