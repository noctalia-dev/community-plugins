"""Entry point: start asyncio loop, bootstrap service, expose HTTP control API.

The Luau [[service]] entry (service.luau) launches this module with
noctalia.runStream() and consumes the newline-JSON events we print to stdout.
Commands come back in over the loopback HTTP control port.

Port selection: RUH_VPN_CONTROL_PORT env var, else 11090.

Coexistence safety: if the control port is already bound, another backend is
already running (e.g. the user's active proxy). We emit a "port-in-use" error
and exit WITHOUT running the destructive shutdown path, so we never tear down a
proxy this instance does not own. The Luau service probes /healthz first and
only spawns us when no backend is present, so this is a belt-and-suspenders
guard.
"""

from __future__ import annotations

import asyncio
import os
import secrets
import signal
import sys
from pathlib import Path

from backend.http.control import DEFAULT_PORT, HOST, emit, serve
from backend.identity import PREFIX
from backend.paths import RUNTIME_DIR, ensure_private_dir, protect_file
from backend.service.vpn_service import VpnService

PIDFILE = RUNTIME_DIR / f"{PREFIX}-backend.pid"
TOKENFILE = RUNTIME_DIR / f"{PREFIX}-control.token"
DETACHED_LOG = RUNTIME_DIR / f"{PREFIX}-backend-detached.log"


class _StdoutGuard:
    """A stdout that outlives its reader.

    service.luau spawns us through noctalia.runStream(), so stdout is a pipe
    owned by that shell. When the shell exits we are meant to keep running (the
    next shell re-attaches over /healthz and the proxy survives), but the read
    end of the pipe closes with it, and from then on every write raises
    BrokenPipeError. Because _now_log() prints, that exception surfaced inside
    whichever RPC logged first: StartProxy died on its very first log line and
    the proxy silently never started. A vanished reader must not be fatal, so
    fall back to a file and carry on.
    """

    def __init__(self, stream: object, fallback: Path) -> None:
        self._stream = stream
        self._fallback = fallback
        self._demoted = False

    def _demote(self) -> None:
        # Close explicitly: the dead pipe still holds whatever we buffered, and
        # letting the finalizer discover that prints "Exception ignored".
        old, self._stream = self._stream, None
        if old is not None:
            try:
                old.close()
            except Exception:
                pass
        if self._demoted:
            return
        self._demoted = True
        try:
            self._stream = open(self._fallback, "a", buffering=1)
            protect_file(self._fallback)
        except OSError:
            self._stream = None

    def write(self, data: str) -> int:
        # At most two tries: pipe -> fallback file -> give up silently.
        for _ in range(2):
            stream = self._stream
            if stream is None:
                break
            try:
                written = stream.write(data)
                # Flush here, not in flush(): the stream is buffered, so a write
                # to a dead pipe succeeds and only the flush raises. By then the
                # line is stranded in a buffer we are about to drop. Flushing
                # while `data` is still in hand lets the retry re-send it.
                stream.flush()
                return written
            except (BrokenPipeError, OSError, ValueError):
                self._demote()
        return len(data)

    def flush(self) -> None:
        # write() already flushed; this only has to stay well-behaved.
        stream = self._stream
        if stream is None:
            return
        try:
            stream.flush()
        except (BrokenPipeError, OSError, ValueError):
            self._demote()

    def isatty(self) -> bool:
        return False


def _install_stdio_guards() -> None:
    sys.stdout = _StdoutGuard(sys.stdout, DETACHED_LOG)
    sys.stderr = _StdoutGuard(sys.stderr, DETACHED_LOG)


def _resolve_port() -> int:
    raw = os.environ.get("RUH_VPN_CONTROL_PORT", "")
    try:
        return int(raw) if raw else DEFAULT_PORT
    except ValueError:
        return DEFAULT_PORT


def _write_pidfile(port: int) -> None:
    try:
        PIDFILE.write_text(f"{os.getpid()} {port}\n")
        protect_file(PIDFILE)
    except Exception:
        pass


def _remove_pidfile() -> None:
    try:
        # Only remove if it still points at us
        content = PIDFILE.read_text().split()
        if content and content[0] == str(os.getpid()):
            PIDFILE.unlink()
    except Exception:
        pass


def _remove_tokenfile(token: str) -> None:
    try:
        # Only remove if it still holds our token
        if TOKENFILE.read_text().strip() == token:
            TOKENFILE.unlink()
    except Exception:
        pass


async def main() -> int:
    ensure_private_dir(RUNTIME_DIR)
    _install_stdio_guards()
    port = _resolve_port()

    svc = VpnService()
    await svc.bootstrap()

    # Per-launch RPC token. serve() writes it to TOKENFILE (0600) only after
    # the port is bound; the Luau service reads the file and sends it as
    # "Authorization: Bearer <token>" on every /rpc call.
    token = secrets.token_urlsafe(32)
    try:
        control = await serve(svc, port, token=token, token_file=TOKENFILE)
    except OSError as exc:
        # Port already in use: another backend owns the proxy. Do NOT shut down.
        emit({"event": "error", "data": {"message": f"control port {port} in use: {exc}"}})
        print(f"[error] control port {port} already in use; exiting without teardown", flush=True)
        return 3

    _write_pidfile(port)
    print(f"[info] Ruh VPN backend ready on http://{HOST}:{port} (pid {os.getpid()})", flush=True)

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()

    def _shutdown(*_: object) -> None:
        if not stop_event.is_set():
            print("[info] shutdown signal received", flush=True)
            stop_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, _shutdown)
        except NotImplementedError:
            pass

    await stop_event.wait()

    print("[info] shutting down VPN service", flush=True)
    try:
        await control.stop()
    except Exception as exc:
        print(f"[error] control stop error: {exc}", flush=True)
    try:
        await svc.shutdown()
    except Exception as exc:
        print(f"[error] shutdown error: {exc}", flush=True)
    _remove_pidfile()
    _remove_tokenfile(token)
    emit({"event": "exit", "data": {"code": 0}})
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        sys.exit(0)
