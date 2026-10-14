#!/usr/bin/env python3
"""Bangumi OAuth companion. Stdout contains metadata only, never credentials.

Client configuration is supplied by the plugin maintainer. No configurable
network endpoints or executable commands are accepted by the production CLI.
Credentials live in oauth-session.json, protected by a private directory and
0600 atomic writes. This is local protection, not protection from the same user.
"""

import argparse
import contextlib
import fcntl
import hashlib
import http.server
import io
import json
import math
import os
import re
import secrets
import stat
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

AUTHORIZE_URL = "https://bgm.tv/oauth/authorize"
TOKEN_URL = "https://bgm.tv/oauth/access_token"
ME_URL = "https://api.bgm.tv/v0/me"
USER_AGENT = "Noctalia-Bangumi-Progress/1.2.0 (https://github.com/noctalia-dev/community-plugins)"
ATTEMPT_PATTERN = re.compile(r"[A-Za-z0-9_-]{16,128}\Z")
CALLBACK_REQUEST_TIMEOUT = 2
CALLBACK_POLL_INTERVAL = 0.2
CALLBACK_HEADER_LIMIT = 64 * 1024


class OAuthError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def error(code):
    return {"ok": False, "error": code}


def request_json(method, url, data=None, token=None):
    """Fixed HTTPS endpoints; disallow redirects which could disclose tokens."""
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None

    headers = {"Accept": "application/json", "User-Agent": USER_AGENT}
    body = None
    if data is not None:
        body = urllib.parse.urlencode(data).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.build_opener(NoRedirect).open(req, timeout=20) as response:
            raw = response.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            raise ValueError("oversized response")
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise ValueError("invalid response")
        if value.get("error"):
            raise OAuthError("oauth_invalid_grant" if value["error"] == "invalid_grant"
                             else "oauth_exchange_failed")
        return value
    except urllib.error.HTTPError as exc:
        # Inspect only the stable OAuth error, never expose body or exception text.
        try:
            value = json.loads(exc.read(16384))
        except (ValueError, OSError):
            value = {}
        finally:
            exc.close()
        if isinstance(value, dict) and value.get("error") == "invalid_grant":
            raise OAuthError("oauth_invalid_grant") from None
        raise OAuthError("oauth_exchange_failed") from None
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        raise OAuthError("oauth_network_error") from None


def open_browser(url):
    """Launch without waiting: some xdg-open implementations stay with the browser."""
    try:
        process = subprocess.Popen(["xdg-open", url], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
    except OSError:
        return False
    # Reap eventual exit while the helper lives, without blocking callbacks or
    # terminating a launcher which may itself have become the user's browser.
    threading.Thread(target=process.wait, daemon=True).start()
    return process


class Store:
    def __init__(self, directory):
        self.directory = os.path.abspath(directory)
        os.makedirs(self.directory, mode=0o700, exist_ok=True)
        info = os.lstat(self.directory)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise OAuthError("oauth_storage_error")
        os.chmod(self.directory, 0o700)

    def path(self, name):
        return os.path.join(self.directory, name)

    @contextlib.contextmanager
    def lock(self, name="oauth-control.lock", blocking=True):
        fd = os.open(self.path(name), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            if os.fstat(fd).st_uid != os.getuid():
                raise OAuthError("oauth_storage_error")
            os.fchmod(fd, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
            except BlockingIOError:
                raise OAuthError("oauth_busy") from None
            yield
        finally:
            os.close(fd)

    def read(self, name):
        try:
            fd = os.open(self.path(name), os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            return None
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise OAuthError("oauth_storage_error")
            os.fchmod(stream.fileno(), 0o600)
            raw = stream.read(1024 * 1024 + 1)
        try:
            value = json.loads(raw)
        except ValueError:
            raise OAuthError("oauth_storage_error") from None
        if len(raw) > 1024 * 1024 or not isinstance(value, dict):
            raise OAuthError("oauth_storage_error")
        return value

    def write(self, name, value):
        fd, temporary = tempfile.mkstemp(prefix=".oauth-", dir=self.directory)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                os.fchmod(stream.fileno(), 0o600)
                json.dump(value, stream, separators=(",", ":"))
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path(name))
            # Persist the rename too: a rotated refresh token must not revert to
            # the old directory entry after a sudden shutdown.
            directory_fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def control(self):
        return self.read("oauth-control.json") or {"generation": secrets.token_hex(16)}

    def remove_session(self):
        try:
            os.unlink(self.path("oauth-session.json"))
        except FileNotFoundError:
            pass


def read_client(filename):
    try:
        with open(filename, encoding="utf-8") as stream:
            config = json.load(stream)
    except (OSError, ValueError):
        raise OAuthError("oauth_not_configured") from None
    fields = ("client_id", "client_secret", "redirect_uri")
    if not isinstance(config, dict) or any(not isinstance(config.get(k), str)
                                          or not config[k].strip() for k in fields):
        raise OAuthError("oauth_not_configured")
    try:
        uri = urllib.parse.urlsplit(config["redirect_uri"])
        port = uri.port
    except ValueError:
        raise OAuthError("oauth_not_configured") from None
    if (uri.scheme != "http" or uri.hostname != "127.0.0.1" or not port
            or uri.username or uri.password or uri.path != "/callback"
            or uri.query or uri.fragment or uri.netloc != "127.0.0.1:" + str(port)):
        raise OAuthError("oauth_not_configured")
    config = {k: config[k] for k in fields}
    config["port"] = port
    config["fingerprint"] = hashlib.sha256(json.dumps(
        [config[k] for k in fields], separators=(",", ":")).encode()).hexdigest()
    return config


class Helper:
    def __init__(self, directory, client_file, *, transport=request_json,
                 browser=open_browser, clock=time.time, monotonic=time.monotonic,
                 login_timeout=180):
        self.store = Store(directory)
        self.client_file = client_file
        self.transport = transport
        self.browser = browser
        self.clock = clock
        self.monotonic = monotonic
        self.login_timeout = login_timeout

    def status(self):
        try:
            config = read_client(self.client_file)
        except OAuthError:
            return {"ok": True, "configured": False, "authenticated": False}
        with self.store.lock():
            session = self.store.read("oauth-session.json")
        if not session:
            return {"ok": True, "configured": True, "authenticated": False}
        if session.get("client_fingerprint") != config["fingerprint"]:
            return {"ok": False, "configured": True, "authenticated": False,
                    "error": "oauth_client_changed"}
        expired = float(session.get("expires_at", 0)) <= self.clock()
        return {"ok": True, "configured": True, "authenticated": True, "expired": expired,
                "expires_at": session["expires_at"], "user_id": session["user_id"],
                "username": session.get("username", ""),
                "nickname": session.get("nickname", ""),
                "relogin_required": bool(session.get("relogin_required", False))}

    def cancel(self, attempt_id=None):
        with self.store.lock():
            control = self.store.control()
            target = attempt_id or control.get("attempt_id")
            session = self.store.read("oauth-session.json")
            # Commit and cancel share this lock. If commit won the race, its
            # atomic session write identifies the completed attempt so callers
            # can adopt that session instead of claiming it was cancelled.
            if target and session and session.get("login_attempt_id") == target:
                return {"ok": True, "cancelled": False, "completed": True,
                        "authenticated": True}
            cancelled = control.get("cancelled_attempts", [])
            if target:
                cancelled = (cancelled + [target])[-32:]
                control["cancelled_attempts"] = cancelled
                if control.get("attempt_id") == target:
                    control["generation"] = secrets.token_hex(16)
                    control.pop("attempt_id", None)
            self.store.write("oauth-control.json", control)
        return {"ok": True, "cancelled": bool(target)}

    def logout(self):
        with self.store.lock():
            control = self.store.control()
            if control.get("attempt_id"):
                control["cancelled_attempts"] = (control.get("cancelled_attempts", [])
                                                  + [control["attempt_id"]])[-32:]
            control["generation"] = secrets.token_hex(16)
            control.pop("attempt_id", None)
            self.store.write("oauth-control.json", control)
            self.store.remove_session()
        return {"ok": True, "authenticated": False}

    def active(self, generation, attempt_id=None):
        with self.store.lock():
            control = self.store.control()
            return (control["generation"] == generation and
                    (attempt_id is None or control.get("attempt_id") == attempt_id))

    def commit(self, session, generation, attempt_id=None):
        with self.store.lock():
            control = self.store.control()
            if (control["generation"] != generation or
                    (attempt_id is not None and control.get("attempt_id") != attempt_id)):
                raise OAuthError("oauth_cancelled")
            self.store.write("oauth-session.json", session)

    @staticmethod
    def identity(user_id, username, nickname=""):
        if (isinstance(user_id, bool) or not isinstance(user_id, int) or user_id <= 0
                or not isinstance(username, str) or not username.strip()):
            raise OAuthError("oauth_profile_failed")
        return {"user_id": user_id, "username": username.strip(),
                "nickname": nickname if isinstance(nickname, str) else ""}

    def credential(self, response, config, previous=None):
        token = response.get("access_token")
        # Preserve the prior refresh token only if the field was omitted. An
        # explicitly empty or invalid replacement is an incomplete response.
        refresh = response.get("refresh_token", (previous or {}).get("refresh_token"))
        expiry = response.get("expires_in")
        if (not isinstance(token, str) or not token or "\n" in token or "\r" in token
                or not isinstance(refresh, str) or not refresh
                or isinstance(expiry, bool) or not isinstance(expiry, (int, float))
                or not math.isfinite(expiry) or expiry <= 0):
            raise OAuthError("oauth_exchange_failed")
        expires_at = int(self.clock() + expiry)
        if previous is not None:
            # The refresh grant belongs to the identity verified at login. A
            # second /me request could fail after the server already rotated
            # refresh tokens, so preserve that identity without another request.
            identity = self.identity(previous.get("user_id"), previous.get("username"),
                                     previous.get("nickname"))
            if "user_id" in response:
                user_id = response["user_id"]
                if (isinstance(user_id, bool) or not isinstance(user_id, int)
                        or user_id != identity["user_id"]):
                    raise OAuthError("oauth_profile_failed")
        else:
            try:
                me = self.transport("GET", ME_URL, token=token)
            except OAuthError:
                raise OAuthError("oauth_profile_failed") from None
            identity = self.identity(me.get("id"), me.get("username"), me.get("nickname"))
        credential = {"version": 1, "access_token": token, "refresh_token": refresh,
                      "expires_at": expires_at, **identity,
                      "client_fingerprint": config["fingerprint"], "relogin_required": False}
        if previous is not None and isinstance(previous.get("login_attempt_id"), str):
            credential["login_attempt_id"] = previous["login_attempt_id"]
        return credential

    def login(self, attempt_id=None):
        config = read_client(self.client_file)
        attempt_id = attempt_id or secrets.token_urlsafe(24)
        if not ATTEMPT_PATTERN.fullmatch(attempt_id):
            raise OAuthError("oauth_invalid_attempt")
        with self.store.lock("oauth-operation.lock", blocking=False):
            with self.store.lock():
                control = self.store.control()
                if attempt_id in control.get("cancelled_attempts", []):
                    raise OAuthError("oauth_cancelled")
                generation = secrets.token_hex(16)
                control.update(generation=generation, attempt_id=attempt_id)
                self.store.write("oauth-control.json", control)
            try:
                return self.wait_for_login(config, generation, attempt_id)
            finally:
                with self.store.lock():
                    control = self.store.control()
                    if control.get("attempt_id") == attempt_id:
                        control.pop("attempt_id", None)
                        self.store.write("oauth-control.json", control)

    def wait_for_login(self, config, generation, attempt_id):
        state = secrets.token_urlsafe(32)
        received = {}
        expected_host = "127.0.0.1:" + str(config["port"])
        monotonic = self.monotonic

        def check_login():
            if not self.active(generation, attempt_id):
                raise OAuthError("oauth_cancelled")
            if self.monotonic() >= deadline:
                raise OAuthError("oauth_timeout")
            if launcher is not True and launcher.poll() not in (None, 0):
                raise OAuthError("browser_open_failed")

        class Callback(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def handle(self):
                # BaseHTTPRequestHandler's buffered readline only enforces an
                # idle timeout. Read one complete header with an absolute bound
                # first, so continuously dripped bytes cannot hold the operation
                # lock. Poll login state independently of header completion.
                request_deadline = monotonic() + CALLBACK_REQUEST_TIMEOUT
                header = bytearray()
                while len(header) < CALLBACK_HEADER_LIMIT:
                    check_login()
                    remaining = min(request_deadline, deadline) - monotonic()
                    if remaining <= 0:
                        return
                    self.connection.settimeout(min(CALLBACK_POLL_INTERVAL, remaining))
                    try:
                        chunk = self.connection.recv(min(4096, CALLBACK_HEADER_LIMIT - len(header)))
                    except TimeoutError:
                        continue
                    if not chunk or monotonic() >= request_deadline:
                        return
                    header.extend(chunk)
                    if b"\r\n\r\n" in header or b"\n\n" in header:
                        check_login()
                        original_rfile = self.rfile
                        try:
                            self.rfile = io.BytesIO(header)
                            self.close_connection = True
                            self.handle_one_request()
                        finally:
                            self.rfile.close()
                            self.rfile = original_rfile
                        return

            def reply(self, status, text):
                body = text.encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("Referrer-Policy", "no-referrer")
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                parsed = urllib.parse.urlsplit(self.path)
                if (self.headers.get("Host") != expected_host or parsed.scheme or parsed.netloc
                        or parsed.path != "/callback" or parsed.fragment):
                    return self.reply(400, "Invalid callback.")
                params = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
                states = params.get("state", [])
                if len(states) != 1 or not secrets.compare_digest(states[0], state):
                    return self.reply(400, "Invalid OAuth state. Please use the original login page.")
                if received:
                    return self.reply(409, "This callback has already been received.")
                if params.get("error"):
                    received["error"] = "oauth_access_denied"
                elif len(params.get("code", [])) == 1 and params["code"][0]:
                    received["code"] = params["code"][0]
                else:
                    return self.reply(400, "Missing authorization code.")
                self.reply(200, "Authorization received. You may close this tab and return to Noctalia.")

        class Server(http.server.HTTPServer):
            # Reconnect after a failed/cancelled login without waiting for TCP
            # TIME_WAIT. This still refuses another active listening socket.
            allow_reuse_address = True

            def handle_error(self, _request, _client_address):
                pass  # Never print a callback URL or traceback containing a code.

        try:
            server = Server(("127.0.0.1", config["port"]), Callback)
        except OSError:
            raise OAuthError("callback_port_in_use") from None
        server.timeout = CALLBACK_POLL_INTERVAL
        deadline = monotonic() + self.login_timeout
        try:
            url = AUTHORIZE_URL + "?" + urllib.parse.urlencode({
                "client_id": config["client_id"], "response_type": "code",
                "redirect_uri": config["redirect_uri"], "state": state})
            launcher = self.browser(url)
            if not launcher:
                raise OAuthError("browser_open_failed")
            while not received:
                check_login()
                server.handle_request()
            check_login()
            if "error" in received:
                raise OAuthError(received["error"])
            response = self.transport("POST", TOKEN_URL, data={
                "grant_type": "authorization_code", "client_id": config["client_id"],
                "client_secret": config["client_secret"], "redirect_uri": config["redirect_uri"],
                "code": received["code"], "state": state})
            session = self.credential(response, config)
            if self.monotonic() >= deadline:
                raise OAuthError("oauth_timeout")
            session["login_attempt_id"] = attempt_id
            self.commit(session, generation, attempt_id)
            return {"ok": True, "authenticated": True, "user_id": session["user_id"],
                    "expires_at": session["expires_at"], "username": session["username"],
                    "nickname": session["nickname"]}
        finally:
            server.server_close()

    def refresh(self):
        config = read_client(self.client_file)
        with self.store.lock("oauth-operation.lock", blocking=False):
            with self.store.lock():
                session = self.store.read("oauth-session.json")
                control = self.store.control()
                generation = control["generation"]
                self.store.write("oauth-control.json", control)
            if not session:
                raise OAuthError("oauth_not_authenticated")
            if session.get("client_fingerprint") != config["fingerprint"]:
                raise OAuthError("oauth_client_changed")
            if session.get("relogin_required") or not session.get("refresh_token"):
                raise OAuthError("oauth_invalid_grant")
            # Reject damaged local identity before consuming its refresh token.
            self.identity(session.get("user_id"), session.get("username"), session.get("nickname"))
            try:
                response = self.transport("POST", TOKEN_URL, data={
                    "grant_type": "refresh_token", "client_id": config["client_id"],
                    "client_secret": config["client_secret"], "redirect_uri": config["redirect_uri"],
                    "refresh_token": session["refresh_token"]})
                renewed = self.credential(response, config, previous=session)
                self.commit(renewed, generation)
            except OAuthError as exc:
                if exc.code == "oauth_invalid_grant":
                    session["relogin_required"] = True
                    self.commit(session, generation)
                raise
            return {"ok": True, "authenticated": True, "user_id": renewed["user_id"],
                    "expires_at": renewed["expires_at"], "username": renewed["username"],
                    "nickname": renewed["nickname"]}

    def run(self, command, attempt_id=None):
        try:
            if command in ("login", "cancel"):
                return getattr(self, command)(attempt_id)
            return getattr(self, command)()
        except OAuthError as exc:
            return error(exc.code)
        except (OSError, ValueError, TypeError, KeyError, OverflowError):
            return error("oauth_storage_error")
        except Exception:
            # An integration/library failure must not emit an exception message
            # or traceback containing credentials, callback codes or API bodies.
            return error("oauth_internal_error")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("login", "refresh", "status", "logout", "cancel"))
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--client-file", required=True)
    parser.add_argument("--attempt-id")
    args = parser.parse_args(argv)
    try:
        if args.attempt_id and not ATTEMPT_PATTERN.fullmatch(args.attempt_id):
            raise OAuthError("oauth_invalid_attempt")
        result = Helper(args.data_dir, args.client_file).run(args.command, args.attempt_id)
    except (OSError, OAuthError) as exc:
        result = error(exc.code if isinstance(exc, OAuthError) else "oauth_storage_error")
    except Exception:
        result = error("oauth_internal_error")
    print(json.dumps(result, separators=(",", ":")), flush=True)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
