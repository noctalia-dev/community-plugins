#!/usr/bin/env python3
"""Temporary localhost OAuth callback server for AniList login."""

from __future__ import annotations

import base64
import json
import socket
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = "127.0.0.1"
PORT = 7823
REDIRECT_URI = f"http://{HOST}:{PORT}/callback"
AUTH_URL = "https://anilist.co/api/v2/oauth/authorize"
TOKEN_URL = "https://anilist.co/api/v2/oauth/token"
TIMEOUT_SECONDS = 180


def emit(payload: dict, result_path: str | None = None) -> None:
    encoded = json.dumps(payload)
    print(encoded, flush=True)
    if result_path:
        with open(result_path, "w", encoding="utf-8") as handle:
            handle.write(encoded)


def load_credentials(path: str) -> tuple[str, str]:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    client_id = str(data.get("client_id", "")).strip()
    client_secret = str(data.get("client_secret", "")).strip()
    if not client_id or not client_secret:
        raise ValueError("missing client_id or client_secret")
    return client_id, client_secret


def exchange_code(client_id: str, client_secret: str, code: str) -> str:
    body = urllib.parse.urlencode(
        {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": REDIRECT_URI,
        }
    ).encode("utf-8")
    credentials = base64.b64encode(f"{client_id}:{client_secret}".encode("utf-8")).decode("ascii")
    request = urllib.request.Request(
        TOKEN_URL,
        data=body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "Authorization": f"Basic {credentials}",
            "User-Agent": "noctalia-anilist-plugin",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
    token = payload.get("access_token")
    if not token:
        message = payload.get("error_description") or payload.get("message") or payload.get("error")
        raise RuntimeError(message or "token response missing access_token")
    return str(token)


def format_http_error(exc: urllib.error.HTTPError) -> str:
    try:
        detail = json.loads(exc.read().decode("utf-8"))
        message = detail.get("error_description") or detail.get("message") or detail.get("error")
        if message:
            return str(message)
    except Exception:  # noqa: BLE001
        pass
    return exc.reason or "token exchange failed"


def port_available(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind((HOST, port))
        except OSError:
            return False
    return True


def main() -> int:
    if len(sys.argv) not in (2, 3):
        emit({"ok": False, "error": "usage: oauth_login.py <credentials.json> [result.json]"}, None)
        return 1

    result_path = sys.argv[2] if len(sys.argv) == 3 else None

    if not port_available(PORT):
        emit(
            {
                "ok": False,
                "error": f"port {PORT} is already in use; close the other login attempt first",
            },
            result_path,
        )
        return 1

    try:
        client_id, client_secret = load_credentials(sys.argv[1])
    except Exception as exc:  # noqa: BLE001
        emit({"ok": False, "error": str(exc)}, result_path)
        return 1

    result: dict[str, str] = {"status": "pending"}
    done = threading.Event()

    class CallbackHandler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            if done.is_set():
                self.send_error(404)
                return

            parsed = urllib.parse.urlparse(self.path)
            if parsed.path != "/callback":
                self.send_error(404)
                return

            params = urllib.parse.parse_qs(parsed.query)
            error = params.get("error", [None])[0]
            if error:
                result["status"] = "error"
                result["error"] = str(error)
                self._success_page("Login failed", "Return to Noctalia and try again.")
                done.set()
                return

            code = params.get("code", [None])[0]
            if not code:
                result["status"] = "error"
                result["error"] = "missing authorization code"
                self._success_page("Login failed", "No authorization code was received.")
                done.set()
                return

            try:
                token = exchange_code(client_id, client_secret, code)
            except urllib.error.HTTPError as exc:
                result["status"] = "error"
                result["error"] = format_http_error(exc)
                self._success_page("Login failed", "Could not finish login. Return to Noctalia and try again.")
                done.set()
                return
            except Exception as exc:  # noqa: BLE001
                result["status"] = "error"
                result["error"] = str(exc)
                self._success_page("Login failed", "Could not finish login. Return to Noctalia and try again.")
                done.set()
                return

            result["status"] = "ok"
            result["access_token"] = token
            self._success_page(
                "Connected to AniList",
                "You can close this tab and return to Noctalia.",
            )
            done.set()

        def log_message(self, format: str, *args) -> None:  # noqa: A003
            return

        def _success_page(self, title: str, message: str) -> None:
            html = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>{title}</title>
  <style>
    body {{
      font-family: system-ui, sans-serif;
      background: #0f172a;
      color: #e2e8f0;
      display: grid;
      place-items: center;
      min-height: 100vh;
      margin: 0;
    }}
    .card {{
      background: #1e293b;
      border-radius: 12px;
      padding: 32px;
      max-width: 420px;
      text-align: center;
      box-shadow: 0 10px 30px rgba(0,0,0,.35);
    }}
    h1 {{ margin-top: 0; color: #38bdf8; }}
  </style>
</head>
<body>
  <div class="card">
    <h1>{title}</h1>
    <p>{message}</p>
  </div>
</body>
</html>"""
            encoded = html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    server = HTTPServer((HOST, PORT), CallbackHandler)
    server.timeout = 1

    authorize = (
        f"{AUTH_URL}?client_id={urllib.parse.quote(client_id)}"
        f"&redirect_uri={urllib.parse.quote(REDIRECT_URI)}"
        "&response_type=code"
    )
    webbrowser.open(authorize)

    def serve_until_done() -> None:
        while not done.is_set():
            server.handle_request()

    worker = threading.Thread(target=serve_until_done, daemon=True)
    worker.start()
    if not done.wait(TIMEOUT_SECONDS):
        result["status"] = "error"
        result["error"] = "login timed out"

    server.server_close()

    if result.get("status") == "ok" and result.get("access_token"):
        emit({"ok": True, "access_token": result["access_token"]}, result_path)
        return 0

    emit({"ok": False, "error": result.get("error") or "login cancelled"}, result_path)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
