#!/usr/bin/env python3
"""Minimal LocalSend v2 daemon (stdlib only) with a local JSON control API.

Speaks the LocalSend protocol (https://github.com/localsend/protocol) on the LAN
and exposes a small loopback-only HTTP API that the Noctalia plugin drives:

  GET  /state                      peers, sessions, own identity
  POST /send    {fingerprint, paths[]?, text?}   (paths may include folders)
  POST /accept  {session}
  POST /reject  {session}
  POST /cancel  {session}
  POST /rescan
  POST /quit

Every control request must carry the header `X-LocalSend-Token` with the secret the
daemon writes (mode 0600, inside its 0700 data directory) to `control.token` at start,
so only the owning user can drive it, and the `Host` header must be the loopback
address, which also defeats DNS rebinding.
"""
import argparse
import getpass
import hashlib
import http.client
import io
import json
import mimetypes
import os
import re
import secrets
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MCAST_ADDR = "224.0.0.167"
PEER_TTL = 75
ANNOUNCE_EVERY = 20
PROMPT_TIMEOUT = 60
STALL_TIMEOUT = 120
CHUNK = 256 * 1024
MAX_TEXT = 1024 * 1024
MAX_FILES = 5000

lock = threading.RLock()
cfg = None
me = {}
peers = {}      # fingerprint -> peer dict
sessions = {}   # id -> session dict
stop_event = threading.Event()
ctl_token = ""   # secret for the control API, see main()


def log(*a):
    print(*a, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- identity

def ensure_cert(data_dir):
    cert = os.path.join(data_dir, "cert.pem")
    key = os.path.join(data_dir, "key.pem")
    if not (os.path.exists(cert) and os.path.exists(key)):
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", key, "-out", cert, "-days", "3650",
             "-subj", "/CN=LocalSend User"],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.chmod(key, 0o600)
    with open(cert) as f:
        der = ssl.PEM_cert_to_DER_cert(f.read())
    return cert, key, hashlib.sha256(der).hexdigest()


def self_info(with_port=True):
    d = {
        "alias": me["alias"], "version": "2.0", "deviceModel": "Linux",
        "deviceType": "desktop", "fingerprint": me["fingerprint"],
        "download": False,
    }
    if with_port:
        d["port"] = cfg.port
        d["protocol"] = "https"
    return d


def local_ips():
    ips = []
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr", "show"], capture_output=True,
                             text=True, timeout=3).stdout
        for m in re.finditer(r"inet (\d+\.\d+\.\d+\.\d+)", out):
            if not m.group(1).startswith("127."):
                ips.append(m.group(1))
    except Exception:
        pass
    return ips


# ---------------------------------------------------------------- peers

def add_peer(info, ip):
    fp = info.get("fingerprint")
    if not fp or fp == me["fingerprint"]:
        return None
    with lock:
        peers[fp] = {
            "fingerprint": fp,
            "alias": str(info.get("alias") or "Unknown")[:64],
            "deviceType": info.get("deviceType") or "desktop",
            "deviceModel": info.get("deviceModel"),
            "ip": ip,
            "port": int(info.get("port") or 53317),
            "protocol": info.get("protocol") or "https",
            "lastSeen": time.time(),
        }
    return fp


def unverified_ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    # Recent LocalSend versions require the sender to present a client certificate.
    ctx.load_cert_chain(me["cert"], me["key"])
    return ctx


def conn_to(peer, timeout=10):
    if peer["protocol"] == "https":
        return http.client.HTTPSConnection(peer["ip"], peer["port"], timeout=timeout,
                                           context=unverified_ctx())
    return http.client.HTTPConnection(peer["ip"], peer["port"], timeout=timeout)


def register_with(ip, port, protocol):
    """Reply to a multicast announcement with our info (two-way discovery)."""
    peer = {"ip": ip, "port": port, "protocol": protocol}
    try:
        c = conn_to(peer, 4)
        c.request("POST", "/api/localsend/v2/register", json.dumps(self_info()),
                  {"Content-Type": "application/json"})
        r = c.getresponse()
        body = r.read()
        if r.status == 200:
            add_peer(json.loads(body) | {"port": port, "protocol": protocol}, ip)
        c.close()
        return True
    except Exception:
        return False


def mcast_sender(ip=None):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    if ip:
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(ip))
    return s


def announce(announce_flag=True):
    msg = json.dumps(self_info() | {"announce": announce_flag}).encode()
    targets = local_ips() or [None]
    for ip in targets:
        try:
            s = mcast_sender(ip)
            s.sendto(msg, (MCAST_ADDR, cfg.port))
            s.close()
        except OSError:
            pass


def udp_listener():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except OSError:
        pass
    s.bind(("", cfg.port))
    for ip in (local_ips() or ["0.0.0.0"]):
        try:
            s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                         struct.pack("4s4s", socket.inet_aton(MCAST_ADDR), socket.inet_aton(ip)))
        except OSError:
            pass
    s.settimeout(1)
    while not stop_event.is_set():
        try:
            data, (ip, _) = s.recvfrom(65535)
            info = json.loads(data)
        except (socket.timeout, ValueError):
            continue
        except OSError:
            break
        fp = add_peer(info, ip)
        if fp and info.get("announce"):
            threading.Thread(target=register_with,
                             args=(ip, int(info.get("port") or 53317),
                                   info.get("protocol") or "https"), daemon=True).start()


def maintenance():
    last = 0
    while not stop_event.wait(2):
        now = time.time()
        if now - last >= ANNOUNCE_EVERY:
            announce()
            last = now
        with lock:
            for s in sessions.values():  # a sender that went quiet must not block the receiver forever
                if s["direction"] == "in" and s["status"] == "receiving" and now - s["updated"] > STALL_TIMEOUT:
                    s.update(status="failed", error="timed out", updated=now)
            for fp in [f for f, p in peers.items() if now - p["lastSeen"] > PEER_TTL]:
                del peers[fp]
            for sid in [s for s, v in sessions.items()
                        if v["status"] in ("done", "rejected", "failed", "cancelled")
                        and now - v["updated"] > 300]:
                del sessions[sid]


# ---------------------------------------------------------------- sessions

def new_session(direction, alias, files):
    sid = uuid.uuid4().hex
    s = {
        "id": sid, "direction": direction, "peer": alias, "status": "pending",
        "files": files, "total": sum(f["size"] for f in files), "done": 0,
        "error": None, "updated": time.time(), "event": threading.Event(),
        "accepted": None, "tokens": {}, "cancel": False,
    }
    with lock:
        sessions[sid] = s
    return s


def touch(s, **kw):
    with lock:
        s.update(kw)
        s["updated"] = time.time()


def public_session(s):
    return {k: s[k] for k in ("id", "direction", "peer", "status", "total", "done", "error")} | {
        "text": s.get("text"),
        "files": [{"name": f["name"], "size": f["size"]} for f in s["files"]]}


def busy_incoming():
    with lock:
        return any(s["direction"] == "in" and s["status"] in ("pending", "receiving")
                   for s in sessions.values())


def safe_relpath(name):
    """Sanitise a sender-supplied file name, keeping sub-folders but never escaping them."""
    parts = [p.strip().lstrip(".")[:200] for p in str(name).replace("\\", "/").split("/")
             if p.strip() not in ("", ".", "..")]
    return "/".join(p for p in parts if p) or "file"


def unique_path(directory, name):
    path = os.path.join(directory, name)
    stem, ext = os.path.splitext(name)
    n = 1
    while os.path.lexists(path):  # lexists: a dangling symlink also counts as taken
        path = os.path.join(directory, f"{stem} ({n}){ext}")
        n += 1
    return path


def publish(tmp, dest):
    """Move tmp to dest without ever replacing an existing file (or following a symlink)."""
    directory, name = os.path.split(dest)
    while True:
        try:
            os.link(tmp, dest)  # fails with FileExistsError instead of overwriting
        except FileExistsError:
            dest = unique_path(directory, name)
            continue
        except OSError:
            # Filesystem without hard links: fall back to a check-then-rename.
            if os.path.lexists(dest):
                dest = unique_path(directory, name)
                continue
            os.rename(tmp, dest)
            return dest
        os.remove(tmp)
        return dest


# ---------------------------------------------------------------- receiving (HTTPS server)

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "localsendd"

    def log_message(self, *a):
        pass

    def reply(self, code, obj=None):
        body = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(code)
        if obj is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 8 * 1024 * 1024:
            raise ValueError("too large")
        return json.loads(self.rfile.read(n) or b"{}")

    def query(self):
        from urllib.parse import urlparse, parse_qs
        u = urlparse(self.path)
        return u.path, {k: v[0] for k, v in parse_qs(u.query).items()}

    def do_GET(self):
        path, _ = self.query()
        if path == "/api/localsend/v2/info":
            return self.reply(200, self_info(False))
        self.reply(404)

    def do_POST(self):
        path, q = self.query()
        try:
            if path == "/api/localsend/v2/register":
                info = self.read_json()
                add_peer(info | {"port": info.get("port", 53317)}, self.client_address[0])
                return self.reply(200, self_info(False))
            if path == "/api/localsend/v2/prepare-upload":
                return self.prepare_upload(q)
            if path == "/api/localsend/v2/upload":
                return self.upload(q)
            if path == "/api/localsend/v2/cancel":
                s = sessions.get(q.get("sessionId", ""))
                if s and s["direction"] == "in":
                    touch(s, status="cancelled", cancel=True)
                return self.reply(200)
        except (ValueError, KeyError, TypeError):
            return self.reply(400, {"message": "Invalid body"})
        except Exception as e:
            log("handler error:", e)
            return self.reply(500, {"message": "Unknown error"})
        self.reply(404)

    def prepare_upload(self, q):
        body = self.read_json()
        info, files_in = body["info"], body["files"]
        if not files_in:
            return self.reply(400, {"message": "Invalid body"})
        if cfg.pin and not secrets.compare_digest(q.get("pin", ""), cfg.pin):
            return self.reply(401, {"message": "PIN required / Invalid PIN"})
        if busy_incoming():
            return self.reply(409, {"message": "Blocked by another session"})
        files = []
        for fid, f in files_in.items():
            item = {"id": str(fid), "name": safe_relpath(f["fileName"]), "size": int(f["size"]),
                    "type": f.get("fileType"), "sha256": f.get("sha256")}
            preview = f.get("preview")
            if isinstance(preview, str) and (item["type"] or "").startswith("text/plain") \
                    and item["size"] <= MAX_TEXT:
                item["text"] = preview  # a text message: kept in memory, not written to disk
            files.append(item)
        s = new_session("in", str(info.get("alias") or "Unknown")[:64], files)
        s["remote_ip"] = self.client_address[0]
        if cfg.auto_accept:
            s["accepted"] = True
        else:
            s["event"].wait(PROMPT_TIMEOUT)
        if s["accepted"] is not True:
            touch(s, status="rejected" if s["accepted"] is False else "failed",
                  error=None if s["accepted"] is False else "timed out")
            return self.reply(403, {"message": "Rejected"})
        texts = [f["text"] for f in files if "text" in f]
        for f in files:
            if "text" in f:
                f["saved"] = True
        tokens = {f["id"]: secrets.token_urlsafe(16) for f in files if "text" not in f}
        touch(s, status="receiving" if tokens else "done", tokens=tokens,
              text="\n".join(texts) if texts else None)
        if not tokens:
            return self.reply(204)  # nothing to upload (text only)
        self.reply(200, {"sessionId": s["id"], "files": tokens})

    def body_chunks(self):
        """Yield the request body, whether Content-Length or chunked encoded."""
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline().strip():  # trailers
                        pass
                    return
                left = size
                while left:
                    chunk = self.rfile.read(min(CHUNK, left))
                    if not chunk:
                        raise RuntimeError("connection lost")
                    left -= len(chunk)
                    yield chunk
                self.rfile.readline()  # CRLF after each chunk
        else:
            left = int(self.headers.get("Content-Length") or 0)
            while left:
                chunk = self.rfile.read(min(CHUNK, left))
                if not chunk:
                    raise RuntimeError("connection lost")
                left -= len(chunk)
                yield chunk

    def upload(self, q):
        s = sessions.get(q.get("sessionId", ""))
        fid, token = q.get("fileId"), q.get("token")
        if not s or s["direction"] != "in" or s["status"] != "receiving" \
                or s["tokens"].get(fid) != token or self.client_address[0] != s.get("remote_ip"):
            return self.reply(403, {"message": "Invalid token or IP address"})
        f = next(x for x in s["files"] if x["id"] == fid)
        os.makedirs(cfg.save_dir, exist_ok=True)
        dest = os.path.realpath(unique_path(cfg.save_dir, f["name"]))
        if not dest.startswith(os.path.realpath(cfg.save_dir) + os.sep):
            return self.reply(403, {"message": "Invalid file name"})
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        # A fresh, randomly named temp file that must not exist and is never a symlink:
        # nothing already on disk can be truncated or redirected.
        tmp = os.path.join(os.path.dirname(dest), f".{uuid.uuid4().hex}.part")
        h = hashlib.sha256()
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666)
            with os.fdopen(fd, "wb") as out:
                for chunk in self.body_chunks():
                    if s["cancel"]:
                        raise RuntimeError("cancelled")
                    out.write(chunk)
                    h.update(chunk)
                    with lock:
                        s["done"] += len(chunk)
                        s["updated"] = time.time()
        except Exception as e:
            try:
                os.remove(tmp)
            except OSError:
                pass
            if s["status"] != "cancelled":
                touch(s, status="failed", error=str(e))
            self.close_connection = True
            return
        if f.get("sha256") and f["sha256"].lower() != h.hexdigest():
            os.remove(tmp)
            touch(s, status="failed", error="checksum mismatch")
            return self.reply(422, {"message": "Checksum mismatch"})
        try:
            dest = publish(tmp, dest)
        except OSError as e:
            touch(s, status="failed", error=str(e))
            return self.reply(500, {"message": "Could not save file"})
        with lock:
            f["saved"] = True
            if all(x.get("saved") for x in s["files"]):
                s["status"] = "done"
            s["updated"] = time.time()
        self.reply(200)


# ---------------------------------------------------------------- sending

def collect_items(paths, text=None):
    """Expand files, folders and an optional text message into sendable items."""
    items = []
    for p in paths:
        if os.path.isdir(p):
            base = os.path.dirname(os.path.abspath(p))
            for root, _, names in os.walk(p):
                for n in sorted(names):
                    full = os.path.join(root, n)
                    if os.path.isfile(full):
                        items.append({"path": full, "name": os.path.relpath(full, base)})
        elif os.path.isfile(p):
            items.append({"path": p, "name": os.path.basename(p)})
        if len(items) > MAX_FILES:
            raise ValueError("too many files")
    if text:
        data = text.encode()[:MAX_TEXT]
        items.append({"data": data, "name": f"{uuid.uuid4().hex[:8]}.txt", "text": data.decode(errors="ignore")})
    return items


def do_send(peer, items, s):
    files, by_id = {}, {}
    for it in items:
        fid = uuid.uuid4().hex
        by_id[fid] = it
        size = len(it["data"]) if "data" in it else os.path.getsize(it["path"])
        files[fid] = {"id": fid, "fileName": it["name"].replace(os.sep, "/"), "size": size,
                      "fileType": "text/plain" if "data" in it
                      else mimetypes.guess_type(it["name"])[0] or "application/octet-stream"}
        if "data" in it:
            files[fid]["preview"] = it["text"]
    try:
        c = conn_to(peer, 15)
        c.request("POST", "/api/localsend/v2/prepare-upload",
                  json.dumps({"info": self_info(), "files": files}),
                  {"Content-Type": "application/json"})
        c.sock.settimeout(PROMPT_TIMEOUT + 15)  # receiver may be deciding
        r = c.getresponse()
        data = r.read()
        c.close()
        if r.status == 204:
            return touch(s, status="done")
        if r.status != 200:
            msg = {403: "rejected", 409: "receiver busy", 401: "PIN required"}.get(
                r.status, f"HTTP {r.status}")
            return touch(s, status="rejected" if r.status == 403 else "failed", error=msg)
        resp = json.loads(data)
        touch(s, status="sending")
        for fid, token in resp["files"].items():
            it = by_id[fid]
            size = files[fid]["size"]
            from urllib.parse import urlencode
            qs = urlencode({"sessionId": resp["sessionId"], "fileId": fid, "token": token})
            c = conn_to(peer, 30)
            c.putrequest("POST", "/api/localsend/v2/upload?" + qs)
            c.putheader("Content-Type", files[fid]["fileType"])
            c.putheader("Content-Length", str(size))
            c.endheaders()
            with (io.BytesIO(it["data"]) if "data" in it else open(it["path"], "rb")) as f:
                while True:
                    if s["cancel"]:
                        c.close()
                        try:
                            cc = conn_to(peer, 5)
                            cc.request("POST", "/api/localsend/v2/cancel?sessionId=" + resp["sessionId"])
                            cc.getresponse().read()
                        except Exception:
                            pass
                        return touch(s, status="cancelled")
                    chunk = f.read(CHUNK)
                    if not chunk:
                        break
                    c.send(chunk)
                    with lock:
                        s["done"] += len(chunk)
                        s["updated"] = time.time()
            r = c.getresponse()
            r.read()
            c.close()
            if r.status != 200:
                return touch(s, status="failed", error=f"upload failed (HTTP {r.status})")
        touch(s, status="done")
    except Exception as e:
        touch(s, status="failed", error=str(e) or e.__class__.__name__)


# ---------------------------------------------------------------- control API (loopback)

class Control(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def reply(self, code, obj=None):
        body = json.dumps(obj if obj is not None else {}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def guard(self):
        host = (self.headers.get("Host") or "").split(":")[0]
        supplied = self.headers.get("X-LocalSend-Token") or ""
        if host not in ("127.0.0.1", "localhost") or \
                not secrets.compare_digest(supplied.encode(), ctl_token.encode()):
            self.reply(403, {"error": "forbidden"})
            return False
        return True

    def do_GET(self):
        if not self.guard():
            return
        if self.path != "/state":
            return self.reply(404)
        with lock:
            self.reply(200, {
                "self": {"alias": me["alias"], "fingerprint": me["fingerprint"],
                         "port": cfg.port, "saveDir": cfg.save_dir,
                         "autoAccept": cfg.auto_accept, "pin": bool(cfg.pin)},
                "peers": sorted(({k: p[k] for k in ("fingerprint", "alias", "deviceType", "ip")}
                                 for p in peers.values()), key=lambda p: p["alias"].lower()),
                "sessions": sorted((public_session(s) for s in sessions.values()),
                                   key=lambda s: sessions[s["id"]]["updated"], reverse=True),
            })

    def do_POST(self):
        if not self.guard():
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            if self.path == "/send":
                with lock:
                    peer = dict(peers[body["fingerprint"]])
                items = collect_items(body.get("paths") or [], body.get("text"))
                if not items:
                    return self.reply(400, {"error": "nothing to send"})
                files = [{"name": it["name"], "size": len(it["data"]) if "data" in it
                          else os.path.getsize(it["path"])} for it in items]
                s = new_session("out", peer["alias"], files)
                touch(s, status="waiting")
                threading.Thread(target=do_send, args=(peer, items, s), daemon=True).start()
                return self.reply(200, {"session": s["id"]})
            if self.path in ("/accept", "/reject"):
                s = sessions[body["session"]]
                s["accepted"] = self.path == "/accept"
                s["event"].set()
                return self.reply(200)
            if self.path == "/cancel":
                s = sessions[body["session"]]
                touch(s, cancel=True)
                if s["status"] == "pending":
                    s["accepted"] = False
                    s["event"].set()
                return self.reply(200)
            if self.path == "/rescan":
                threading.Thread(target=announce, daemon=True).start()
                return self.reply(200)
            if self.path == "/quit":
                self.reply(200)
                stop_event.set()
                return
        except KeyError:
            return self.reply(404, {"error": "not found"})
        except (ValueError, TypeError):
            return self.reply(400, {"error": "bad request"})
        self.reply(404)


# ---------------------------------------------------------------- main

def main():
    global cfg, me, ctl_token
    ap = argparse.ArgumentParser()
    xdg = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    ap.add_argument("--data-dir", default=os.path.join(xdg, "localsendd"))
    ap.add_argument("--save-dir", default=os.path.expanduser("~/Downloads/LocalSend"))
    host = socket.gethostname()
    ap.add_argument("--alias", default=getpass.getuser() if host == "localhost" else host)
    ap.add_argument("--pin-file", default="",
                    help="file holding the PIN senders must provide; read once, then deleted")
    ap.add_argument("--port", type=int, default=53317)
    ap.add_argument("--control-port", type=int, default=53318)
    ap.add_argument("--auto-accept", action="store_true")
    cfg = ap.parse_args()
    cfg.save_dir = os.path.expanduser(cfg.save_dir)
    cfg.pin = ""
    os.makedirs(cfg.data_dir, mode=0o700, exist_ok=True)
    os.chmod(cfg.data_dir, 0o700)
    if cfg.pin_file:
        try:
            with open(cfg.pin_file) as f:
                cfg.pin = f.read().strip()
            os.remove(cfg.pin_file)  # keep the PIN out of argv and off disk
        except OSError:
            pass
    old_umask = os.umask(0o077)  # key and token are never group/world readable, even briefly
    cert, key, fp = ensure_cert(cfg.data_dir)
    os.umask(old_umask)
    me = {"alias": cfg.alias, "fingerprint": fp, "cert": cert, "key": key}

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    server = ThreadingHTTPServer(("", cfg.port), Handler)
    server.daemon_threads = True
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    control = ThreadingHTTPServer(("127.0.0.1", cfg.control_port), Control)
    control.daemon_threads = True

    # Only now, with both ports bound, publish the token: an instance that failed to start
    # (port already taken by a live daemon) must not overwrite the live daemon's token.
    os.umask(0o077)
    ctl_token = secrets.token_urlsafe(32)
    fd = os.open(os.path.join(cfg.data_dir, "control.token"),
                 os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(ctl_token)
    os.umask(old_umask)

    for fn in (server.serve_forever, control.serve_forever, udp_listener, maintenance):
        threading.Thread(target=fn, daemon=True).start()
    log(f"localsendd: {me['alias']} fp={fp[:12]} https:{cfg.port} control:{cfg.control_port}")
    announce()
    stop_event.wait()
    server.shutdown()
    control.shutdown()


if __name__ == "__main__":
    main()
