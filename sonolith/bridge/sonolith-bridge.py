#!/usr/bin/env python3
"""Bridge between the Noctalia Sonolith plugin and Sonolith's local API.

    sonolith-bridge.py daemon --data-dir DIR   long-running, started by the plugin service
    sonolith-bridge.py call METHOD [JSON]      one request through the running daemon

The daemon owns the only connection to Sonolith (JSON-RPC over a Unix socket) and writes one JSON object per line
to stdout: status changes, the session, Sonolith events 1:1, heartbeats and logs. `call` talks to the daemon over a
private control socket, so it never authenticates on its own, and prints one line: {"ok": true, "result": ...} or
{"ok": false, "error": {"name": ..., "reason": ..., ...}}.

Standard library only. The token lives in the Secret Service (secret-tool) or in a 0600 file in the data dir, and
is never printed.
"""

import json
import os
import socket
import sys

APP_ID = "com.github.opecko.sonolith-noctalia"
API_VERSION = "1.0"
MAX_MESSAGE = 1024 * 1024
CALL_TIMEOUT = 30
HEARTBEAT_S = 5

SCOPES = [
    ("player:read", True, "To show the current song in your bar"),
    ("player:control", False, "To play, pause, skip and seek from your bar"),
    ("queue:read", False, "To show what's up next"),
    ("queue:write", False, "To add, move and remove songs in your queue"),
    ("lyrics:read", False, "To show the current lyric line"),
    ("library:read", False, "To browse your library"),
    ("search", False, "To search YouTube Music"),
    ("library:write", False, "To like songs and save them to playlists"),
]
REASONS = {scope: reason for scope, _, reason in SCOPES}

# Topics we subscribe to, by the scope each one needs (None = no scope).
TOPICS = [
    ("player.state", "player:read"),
    ("player.track", "player:read"),
    ("player.position", "player:read"),
    ("player.volume", "player:read"),
    ("queue", "queue:read"),
    ("lyrics", "lyrics:read"),
    ("lyrics.line", "lyrics:read"),
    ("account", None),
]


def ctl_dir():
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg:
        return os.path.join(xdg, "sonolith-noctalia")
    return f"/tmp/sonolith-noctalia-{os.getuid()}"


def ctl_path():
    return os.path.join(ctl_dir(), "ctl.sock")


# ---------------------------------------------------------------- call mode


def call_main(method, raw_params):
    def fail(name, reason):
        print(json.dumps({"ok": False, "error": {"name": name, "reason": reason}}), flush=True)

    try:
        params = json.loads(raw_params) if raw_params else {}
    except ValueError as e:
        return fail("InvalidParams", str(e))
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(CALL_TIMEOUT + 5)
        s.connect(ctl_path())
    except OSError as e:
        return fail("BridgeDown", str(e))
    try:
        s.sendall(json.dumps({"method": method, "params": params}).encode() + b"\n")
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    except OSError as e:
        return fail("BridgeDown", str(e))
    finally:
        s.close()
    line = buf.decode("utf-8", "replace").strip()
    if not line:
        return fail("BridgeDown", "no answer")
    print(line, flush=True)


# ---------------------------------------------------------------- daemon


def daemon_main(data_dir):
    import asyncio
    import fcntl
    import random
    import shutil
    import signal
    import subprocess
    import time

    def now_ms():
        return int(time.time() * 1000)

    def emit(obj):
        try:
            sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, OSError):
            os._exit(0)  # the plugin went away

    def log(level, msg):
        emit({"t": "log", "level": level, "msg": msg})

    # -------------------------------------------------------- single instance

    def private_dir(path):
        os.makedirs(path, mode=0o700, exist_ok=True)
        st = os.lstat(path)
        if st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise SystemExit(f"{path} is not private to this user")

    def take_lock():
        """The newest daemon wins: a restarted plugin service must not end up with two bridges."""
        private_dir(ctl_dir())
        fd = os.open(os.path.join(ctl_dir(), "daemon.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            try:
                pid = int(os.pread(fd, 32, 0).decode().strip() or 0)
                with open(f"/proc/{pid}/cmdline", "rb") as f:
                    if b"sonolith-bridge" in f.read():
                        os.kill(pid, signal.SIGTERM)
            except (ValueError, OSError):
                pass
            for _ in range(30):
                time.sleep(0.1)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    continue
            else:
                fcntl.flock(fd, fcntl.LOCK_EX)
        os.ftruncate(fd, 0)
        os.pwrite(fd, str(os.getpid()).encode(), 0)
        return fd

    # -------------------------------------------------------- token storage

    class TokenStore:
        ATTRS = ["service", "sonolith-api", "app", APP_ID]

        def __init__(self, directory):
            self.file = os.path.join(directory, "token")
            self.tool = shutil.which("secret-tool")

        def _run(self, args, data=None):
            try:
                return subprocess.run([self.tool, *args], input=data, capture_output=True, text=True, timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                return None

        def load(self):
            if self.tool:
                r = self._run(["lookup", *self.ATTRS])
                if r and r.returncode == 0 and r.stdout.strip():
                    return r.stdout.strip()
            try:
                with open(self.file) as f:
                    return f.read().strip() or None
            except OSError:
                return None

        def save(self, token):
            if self.tool:
                r = self._run(["store", "--label=Sonolith token (Noctalia widget)", *self.ATTRS], token)
                if r and r.returncode == 0:
                    self._unlink()
                    return
                log("warn", "Secret Service unavailable; keeping the token in a user-only file")
            fd = os.open(self.file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(token)

        def delete(self):
            if self.tool:
                self._run(["clear", *self.ATTRS])
            self._unlink()

        def _unlink(self):
            try:
                os.unlink(self.file)
            except FileNotFoundError:
                pass

    # -------------------------------------------------------- Sonolith endpoint

    class NotAvailable(Exception):
        pass

    class RpcError(Exception):
        def __init__(self, error):
            self.code = error.get("code")
            self.data = error.get("data") or {}
            self.name = self.data.get("name") or error.get("message") or "Error"
            super().__init__(f"{self.name}: {self.data.get('reason') or error.get('message')}")

        def as_dict(self):
            d = dict(self.data)
            d.setdefault("name", self.name)
            d["code"] = self.code
            return d

    def sonolith_dir():
        xdg = os.environ.get("XDG_RUNTIME_DIR")
        if xdg:
            return os.path.join(xdg, "sonolith")
        d = f"/tmp/sonolith-{os.getuid()}"
        try:
            st = os.lstat(d)
        except FileNotFoundError:
            return d
        if st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise NotAvailable(f"{d} is not private to this user")
        return d

    def discovery():
        """(socket path, startedAt) or raises NotAvailable."""
        base = sonolith_dir()
        try:
            with open(os.path.join(base, "discovery.json")) as f:
                info = json.load(f)
            return info["path"], info.get("startedAt")
        except (OSError, KeyError, ValueError):
            path = os.path.join(base, "api.sock")
            if os.path.exists(path):
                return path, None
            raise NotAvailable("no endpoint")

    def endpoint_marker():
        try:
            return discovery()
        except NotAvailable:
            return None

    class Connection:
        def __init__(self, reader, writer):
            self.reader, self.writer = reader, writer
            self.next_id = 1
            self.pending = {}
            self.events = asyncio.Queue()
            self.closed = False
            self.task = asyncio.ensure_future(self._read())

        @classmethod
        async def open(cls):
            path, _ = discovery()
            try:
                return cls(*await asyncio.open_unix_connection(path, limit=2 * MAX_MESSAGE))
            except OSError as e:
                raise NotAvailable(str(e)) from e

        async def call(self, method, params=None, timeout=CALL_TIMEOUT):
            if self.closed:
                raise NotAvailable("connection closed")
            msg_id, self.next_id = self.next_id, self.next_id + 1
            msg = {"jsonrpc": "2.0", "id": msg_id, "method": method}
            if params:
                msg["params"] = params
            line = json.dumps(msg, separators=(",", ":")).encode() + b"\n"
            if len(line) > MAX_MESSAGE:
                raise RpcError({"code": -32600, "data": {"name": "InvalidRequest", "reason": "messageTooLarge"}})
            fut = asyncio.get_running_loop().create_future()
            self.pending[msg_id] = fut
            try:
                self.writer.write(line)
                await self.writer.drain()
                return await asyncio.wait_for(fut, timeout)
            except (ConnectionError, OSError) as e:
                raise NotAvailable(str(e)) from e
            except asyncio.TimeoutError:
                raise RpcError({"code": -32011, "data": {"name": "Timeout", "reason": "bridgeTimeout"}})
            finally:
                self.pending.pop(msg_id, None)

        async def _read(self):
            try:
                while True:
                    line = await self.reader.readline()
                    if not line:
                        break
                    if not line.strip():
                        continue
                    try:
                        msg = json.loads(line)
                    except ValueError:
                        continue
                    if "id" in msg and msg["id"] in self.pending:
                        fut = self.pending[msg["id"]]
                        if fut.done():
                            continue
                        if "error" in msg:
                            fut.set_exception(RpcError(msg["error"] or {}))
                        else:
                            fut.set_result(msg.get("result"))
                    elif "method" in msg:
                        await self.events.put(msg)
            except (ConnectionError, OSError, ValueError, asyncio.LimitOverrunError):
                pass
            finally:
                self.closed = True
                for fut in self.pending.values():
                    if not fut.done():
                        fut.set_exception(NotAvailable("connection closed"))
                await self.events.put(None)

        def close(self):
            if not self.closed:
                self.closed = True
                try:
                    self.writer.close()
                except Exception:
                    pass
            self.task.cancel()
            self.events.put_nowait(None)

    # -------------------------------------------------------- the app icon

    # 128x128 PNG of assets/icon.svg (rsvg-convert -w 128 -h 128), inlined so the bridge stays one file.
    ICON_PNG_BASE64 = (
        "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"
        "36z4/4J6EVSXiO1yAAAAAElFTkSuQmCC"
    )

    def registration():
        return {
            "appId": APP_ID,
            "name": "Sonolith Noctalia integration",
            "description": "Shows what's playing in your Noctalia bar and controls Sonolith.",
            "publisher": "opecko",
            "homepage": "https://github.com/opecko/sonolith-noctalia-integration",
            "icon": "data:image/png;base64," + ICON_PNG_BASE64,
            "scopes": [{"scope": s, "required": req, "reason": reason} for s, req, reason in SCOPES],
            "apiVersion": API_VERSION,
        }

    # -------------------------------------------------------- the bridge

    class Bridge:
        def __init__(self):
            self.store = TokenStore(data_dir)
            self.wake = asyncio.Event()
            self.status_key = None
            self.sticky = None  # (state, info) shown until the user acts
            self.session = None  # the authenticated Connection
            self.scopes = []
            self.reg_task = None
            self.reg_conn = None

        def set_status(self, state, **info):
            key = (state, json.dumps(info, sort_keys=True))
            if key == self.status_key:
                return
            self.status_key = key
            emit({"t": "status", "state": state, "info": info})

        def publish_idle(self):
            """No token: what the panel should offer."""
            if self.reg_task:
                return
            if self.sticky and self.sticky[0] in ("blocked", "denied", "expired"):
                self.set_status(self.sticky[0], **self.sticky[1])
            elif endpoint_marker() is None:
                self.set_status("unavailable")
            elif self.sticky:
                self.set_status(self.sticky[0], **self.sticky[1])
            else:
                self.set_status("unregistered")

        def poke(self):
            self.wake.set()

        async def wait(self, seconds=None):
            """Sleeps until poked, the endpoint appears or changes, or `seconds` pass."""
            marker = endpoint_marker()
            end = None if seconds is None else time.monotonic() + seconds
            while not self.wake.is_set():
                if end is not None and time.monotonic() >= end:
                    return
                if endpoint_marker() != marker:
                    return
                try:
                    await asyncio.wait_for(self.wake.wait(), 1)
                except asyncio.TimeoutError:
                    pass

        async def run(self):
            delay = 1.0
            while True:
                self.wake.clear()
                token = await asyncio.to_thread(self.store.load)
                if not token:
                    self.publish_idle()
                    await self.wait()
                    continue
                if self.reg_task:  # a token from an earlier approval while a new request waits
                    await self.wait()
                    continue
                try:
                    conn = await Connection.open()
                except NotAvailable:
                    self.set_status("unavailable")
                    await self.wait(delay * random.uniform(0.8, 1.2))
                    delay = min(delay * 2, 60)
                    continue
                try:
                    outcome = await self.run_session(conn, token)
                except NotAvailable:
                    outcome = "retry"
                except RpcError as e:
                    log("warn", f"session failed: {e}")
                    outcome = "retry"
                finally:
                    self.session = None
                    conn.close()
                if outcome == "ok":
                    delay = 1.0
                    outcome = "retry"
                if outcome == "stop":
                    await self.wait_for_user()
                elif outcome == "retry":
                    if not self.wake.is_set():
                        self.set_status("unavailable")
                    await self.wait(delay * random.uniform(0.8, 1.2))
                    delay = min(delay * 2, 60)

        async def wait_for_user(self):
            while not self.wake.is_set():
                await self.wake.wait()

        def lose_token(self, state, **info):
            self.store.delete()
            self.sticky = (state, info)
            self.set_status(state, **info)

        async def hello(self, conn, token):
            while True:
                try:
                    return await conn.call("session.hello", {"appId": APP_ID, "token": token, "apiVersion": API_VERSION})
                except RpcError as e:
                    if e.name in ("Unauthorized", "NotRegistered"):
                        self.lose_token("disconnected")
                        return "idle"
                    if e.name == "Blocked":
                        self.lose_token("blocked")
                        return "idle"
                    if e.name == "UnsupportedVersion":
                        self.set_status("error", message="unsupportedVersion", supported=e.data.get("supported"))
                        return "stop"
                    if e.name == "RateLimited":
                        await asyncio.sleep(max(e.data.get("retryAfterMs") or 1000, 100) / 1000)
                        continue
                    if e.name != "RegistrationPending":
                        raise
                    request_id = e.data.get("requestId")
                    self.set_status("pending", kind="identity", expiresAt=e.data.get("expiresAt"))
                    outcome = await self.wait_resolved(conn, request_id)
                    if outcome is None:
                        return "retry"
                    if outcome["status"] != "approved":
                        state = "denied" if outcome["status"] == "denied" else outcome["status"]
                        self.set_status(state, kind="identity", **self.retry_info(outcome))
                        return "stop"

        @staticmethod
        def retry_info(outcome):
            ms = outcome.get("retryAfterMs")
            return {"retryAfterMs": ms, "retryAt": now_ms() + ms} if ms else {}

        async def wait_resolved(self, conn, request_id):
            while True:
                msg = await conn.events.get()
                if msg is None:
                    return None
                if msg.get("method") == "registration.resolved" and msg["params"].get("requestId") == request_id:
                    return msg["params"]

        async def subscribe(self, conn):
            topics = [t for t, scope in TOPICS if scope is None or scope in self.scopes]
            if topics:
                await conn.call("events.subscribe", {"topics": topics, "positionHz": 1})

        async def run_session(self, conn, token):
            result = await self.hello(conn, token)
            if isinstance(result, str):
                return result
            self.sticky = None
            self.scopes = list(result.get("grantedScopes") or [])
            self.session = conn
            emit({
                "t": "hello",
                "grantedScopes": self.scopes,
                "signedIn": result.get("signedIn"),
                "appVersion": result.get("appVersion"),
                "apiVersion": result.get("apiVersion"),
            })
            self.set_status("connected")
            await self.subscribe(conn)
            while True:
                msg = await conn.events.get()
                if msg is None:
                    return "ok"
                method, params = msg.get("method"), msg.get("params") or {}
                if method == "session.revoked":
                    self.session = None
                    self.lose_token("disconnected", reason=params.get("reason"))
                    return "idle"
                if method == "session.scopesChanged":
                    self.scopes = list(params.get("grantedScopes") or [])
                    emit({"t": "scopes", "grantedScopes": self.scopes})
                    try:
                        await self.subscribe(conn)  # new topics only; removed scopes end their topics
                    except RpcError as e:
                        log("warn", f"resubscribe failed: {e}")
                    continue
                emit({"t": "event", "method": method, "params": params})

        # ---------------------------------------------------- control commands

        async def register(self):
            if self.session:
                return {"error": {"name": "AlreadyConnected", "reason": "alreadyConnected"}}
            if self.reg_task:
                return {"result": {"status": "pending"}}
            try:
                conn = await Connection.open()
            except NotAvailable as e:
                self.publish_idle()
                return {"error": {"name": "Unavailable", "reason": "sonolithNotRunning", "detail": str(e)}}
            try:
                res = await conn.call("app.register", registration())
            except (RpcError, NotAvailable) as e:
                conn.close()
                if isinstance(e, NotAvailable):
                    return {"error": {"name": "Unavailable", "reason": "sonolithNotRunning"}}
                if e.name == "Blocked":
                    self.sticky = ("blocked", {})
                elif e.name == "RegistrationDenied":
                    self.sticky = ("denied", self.retry_info(e.data))
                self.publish_idle()
                return {"error": e.as_dict()}
            self.sticky = None
            self.reg_conn = conn
            self.set_status("pending", kind="register", expiresAt=res.get("expiresAt"))
            self.reg_task = asyncio.ensure_future(self.await_registration(conn, res.get("requestId")))
            return {"result": {"status": "pending", "expiresAt": res.get("expiresAt")}}

        async def await_registration(self, conn, request_id):
            try:
                outcome = await self.wait_resolved(conn, request_id)
                if outcome is None:
                    log("warn", "the registration connection closed; the request was cancelled")
                elif outcome["status"] == "approved" and outcome.get("token"):
                    await asyncio.to_thread(self.store.save, outcome["token"])
                elif outcome["status"] in ("denied", "blocked", "expired"):
                    self.sticky = (outcome["status"], self.retry_info(outcome))
            finally:
                conn.close()
                self.reg_conn = None
                self.reg_task = None
                self.status_key = None
                self.poke()

        async def cancel_register(self):
            if self.reg_task:
                self.reg_task.cancel()
                if self.reg_conn:
                    self.reg_conn.close()
            self.sticky = None
            self.poke()
            return {"result": {}}

        async def disconnect(self):
            if self.reg_task:
                await self.cancel_register()
            conn = self.session
            try:
                if conn:
                    await conn.call("app.unregister", timeout=5)
                else:
                    token = await asyncio.to_thread(self.store.load)
                    if token and endpoint_marker():
                        tmp = await Connection.open()
                        try:
                            r = await tmp.call("session.hello", {"appId": APP_ID, "token": token, "apiVersion": API_VERSION}, timeout=5)
                            if r:
                                await tmp.call("app.unregister", timeout=5)
                        finally:
                            tmp.close()
            except (RpcError, NotAvailable) as e:
                log("info", f"unregister: {e}")  # the token goes anyway
            await asyncio.to_thread(self.store.delete)
            if conn:
                conn.close()
            self.session = None
            self.sticky = None
            self.status_key = None
            self.poke()
            return {"result": {}}

        async def request_scopes(self, params):
            if not self.session:
                return {"error": {"name": "NotConnected", "reason": "notConnected"}}
            wanted = [s for s in (params.get("scopes") or []) if s in REASONS and s not in self.scopes]
            if not wanted:
                return {"result": {"status": "granted", "grantedScopes": self.scopes}}
            scopes = [{"scope": s, "required": False, "reason": REASONS[s]} for s in wanted]
            try:
                return {"result": await self.session.call("app.requestScopes", {"scopes": scopes})}
            except RpcError as e:
                return {"error": e.as_dict()}

        async def forward(self, method, params):
            conn = self.session
            if not conn:
                return {"error": {"name": "NotConnected", "reason": "notConnected"}}
            try:
                return {"result": await conn.call(method, params or None)}
            except RpcError as e:
                return {"error": e.as_dict()}
            except NotAvailable:
                return {"error": {"name": "NotConnected", "reason": "connectionLost"}}

        async def handle(self, req):
            method = req.get("method")
            params = req.get("params")
            if not isinstance(params, dict):
                params = {}  # Luau encodes an empty table as []
            if method == "bridge.register":
                return await self.register()
            if method == "bridge.cancelRegister":
                return await self.cancel_register()
            if method == "bridge.disconnect":
                return await self.disconnect()
            if method == "bridge.requestScopes":
                return await self.request_scopes(params)
            if method == "bridge.retry":
                self.sticky = None if not self.session else self.sticky
                self.status_key = None
                self.poke()
                return {"result": {}}
            if not isinstance(method, str) or method.startswith("bridge.") or method in ("session.hello", "app.register", "app.unregister", "app.requestScopes"):
                return {"error": {"name": "MethodNotFound", "reason": "notAllowed"}}
            return await self.forward(method, params)

        async def serve_client(self, reader, writer):
            try:
                line = await asyncio.wait_for(reader.readline(), 5)
                req = json.loads(line)
                out = await self.handle(req if isinstance(req, dict) else {})
            except (ValueError, asyncio.TimeoutError, OSError) as e:
                out = {"error": {"name": "InvalidRequest", "reason": str(e)}}
            except Exception as e:  # never let one bad request take the daemon down
                out = {"error": {"name": "InternalError", "reason": repr(e)}}
            reply = {"ok": "error" not in out}
            reply.update(out)
            try:
                writer.write(json.dumps(reply, separators=(",", ":")).encode() + b"\n")
                await writer.drain()
            except OSError:
                pass
            finally:
                writer.close()

    async def heartbeat():
        parent = os.getppid()
        while True:
            emit({"t": "hb"})
            if os.getppid() != parent:
                os._exit(0)
            await asyncio.sleep(HEARTBEAT_S)

    async def main():
        bridge = Bridge()
        path = ctl_path()
        try:
            os.unlink(path)  # ours: we hold the lock
        except FileNotFoundError:
            pass
        server = await asyncio.start_unix_server(bridge.serve_client, path, limit=2 * MAX_MESSAGE)
        os.chmod(path, 0o600)
        loop = asyncio.get_running_loop()
        stop = asyncio.Event()
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            loop.add_signal_handler(sig, stop.set)
        tasks = [asyncio.ensure_future(bridge.run()), asyncio.ensure_future(heartbeat())]
        stopper = asyncio.ensure_future(stop.wait())
        done, _ = await asyncio.wait([*tasks, stopper], return_when=asyncio.FIRST_COMPLETED)
        for t in done:
            if t is not stopper and t.exception():
                log("error", f"bridge crashed: {t.exception()!r}")
        server.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass

    os.makedirs(data_dir, mode=0o700, exist_ok=True)
    take_lock()
    asyncio.run(main())


def main(argv):
    if len(argv) >= 2 and argv[1] == "call":
        if len(argv) < 3:
            sys.exit("usage: sonolith-bridge.py call METHOD [JSON]")
        call_main(argv[2], argv[3] if len(argv) > 3 else "")
    elif len(argv) >= 2 and argv[1] == "daemon":
        data_dir = argv[argv.index("--data-dir") + 1] if "--data-dir" in argv else os.path.expanduser("~/.local/state/sonolith-noctalia")
        daemon_main(data_dir)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
