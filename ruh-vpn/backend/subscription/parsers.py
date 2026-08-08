"""Parse share links (vless / vmess / ss / socks5 / sn) into server dicts.

The output dict shape matches `backend.models.server.parse_server` so it can be
fed straight into VpnService.add_server.
"""

from __future__ import annotations

import base64
import binascii
import json
import re
import struct
import urllib.parse as urlparse
import uuid
import zlib


def _b64_decode_padded(data: str) -> bytes:
    data = data.strip().replace("\n", "").replace("\r", "")
    pad = "=" * (-len(data) % 4)
    try:
        return base64.urlsafe_b64decode(data + pad)
    except (binascii.Error, ValueError):
        try:
            return base64.b64decode(data + pad)
        except (binascii.Error, ValueError):
            return b""


def parse_subscription_body(body: str) -> list[str]:
    """Return a list of share-link strings from a raw subscription body.

    Body may be:
      - Base64 of newline-separated share links (most common).
      - Plain text with newline-separated share links.
    """
    body = body.strip()
    if not body:
        return []
    if "://" not in body:
        decoded = _b64_decode_padded(body)
        try:
            body = decoded.decode("utf-8", errors="replace")
        except UnicodeDecodeError:
            return []
    out: list[str] = []
    for line in body.splitlines():
        line = line.strip()
        if "://" in line:
            out.append(line)
    return out


def parse_share_link(link: str) -> dict | None:
    link = link.strip()
    if link.startswith("vless://"):
        return _parse_vless(link)
    if link.startswith("vmess://"):
        return _parse_vmess(link)
    if link.startswith("ss://"):
        return _parse_ss(link)
    if link.startswith("socks5://") or link.startswith("socks://"):
        return _parse_socks5(link)
    if link.startswith("sn://"):
        return _parse_sn(link)
    return None


# ---------------------------------------------------------------- sn:// links
#
# sn://<type>?<urlsafe-base64 of zlib(payload)>. The payload is a binary record,
# not JSON: strings are stored raw with the high bit set on their LAST byte
# (so "192.0.2." + 0xb1 reads as "192.0.2.1"), and numbers are 32-bit LE.
#
# This layout was derived by inspection of a working ssh link — no public spec
# was found for it, and it is NOT nekoray's (its repositories contain no "sn://"
# and it has no ssh profile type). The reading was confirmed field by field
# against a real link: port came out as exactly 22 and the user as "root", and
# the owner verified the decoded password character for character.
#
# Because the format is inferred rather than specified, everything here is
# strict: only the "ssh" type is accepted, every field must survive validation,
# and anything unexpected returns None so the caller reports an unsupported link
# instead of silently creating a wrong server. Two trailing fields (an int and
# what looks like a UTF-8 remark) do not fit the scheme and are ignored — the
# name is taken from the host instead.


def _sn_read_string(buf: bytes, i: int) -> tuple[str, int] | None:
    """Read one high-bit-terminated string starting at `i`."""
    out = bytearray()
    while i < len(buf):
        c = buf[i]
        i += 1
        if c & 0x80:
            out.append(c & 0x7F)
            try:
                return out.decode("utf-8"), i
            except UnicodeDecodeError:
                return None
        out.append(c)
    return None  # ran off the end without a terminator


def _sn_read_u32(buf: bytes, i: int) -> tuple[int, int] | None:
    if i + 4 > len(buf):
        return None
    return struct.unpack_from("<I", buf, i)[0], i + 4


_SN_PRINTABLE = re.compile(r"^[\x20-\x7e]+$")


def _parse_sn(link: str) -> dict | None:
    try:
        kind, payload = link[len("sn://"):].split("?", 1)
    except ValueError:
        return None
    if kind != "ssh":
        return None  # only type verified against a real link

    raw = _b64_decode_padded(payload)
    if not raw:
        return None
    try:
        buf = zlib.decompress(raw)
    except zlib.error:
        return None

    i = 4  # leading u32, always 0 in the sample; purpose unknown
    host_r = _sn_read_string(buf, i)
    if not host_r:
        return None
    host, i = host_r
    port_r = _sn_read_u32(buf, i)
    if not port_r:
        return None
    port, i = port_r
    user_r = _sn_read_string(buf, i)
    if not user_r:
        return None
    user, i = user_r
    # Unknown u32 between user and password (1 in the sample; possibly an auth
    # mode). Not trusted for anything.
    skip = _sn_read_u32(buf, i)
    if not skip:
        return None
    i = skip[1]
    pw_r = _sn_read_string(buf, i)
    if not pw_r:
        return None
    password, _ = pw_r

    if not (0 < port < 65536):
        return None
    for value in (host, user, password):
        if not value or not _SN_PRINTABLE.match(value):
            return None

    return {
        "protocol": "ssh",
        "name": host,
        "host": host,
        "port": port,
        "user": user,
        "password": password,
    }


def _decode_name(fragment: str) -> str:
    return urlparse.unquote(fragment or "").strip() or "imported"


def _parse_vless(link: str) -> dict | None:
    parsed = urlparse.urlparse(link)
    if not parsed.username or not parsed.hostname or not parsed.port:
        return None
    q = urlparse.parse_qs(parsed.query)

    def _q(k: str, default: str = "") -> str:
        return (q.get(k, [default]) or [default])[0]

    out: dict = {
        "name": _decode_name(parsed.fragment),
        "protocol": "vless",
        "address": parsed.hostname,
        "port": int(parsed.port),
        "uuid": parsed.username,
        "transport": _q("type", "tcp") or "tcp",
    }
    sec = _q("security", "")
    out["security"] = sec if sec in ("tls", "reality", "none") else None
    out["tls"] = bool(sec in ("tls", "reality"))
    sni = _q("sni") or _q("host")
    if sni:
        out["sni"] = sni
    for src, dst in [
        ("flow", "flow"),
        ("fp", "fp"),
        ("pbk", "pbk"),
        ("sid", "sid"),
        ("path", "path"),
        ("serviceName", "serviceName"),
    ]:
        v = _q(src)
        if v:
            out[dst] = v
    out["id"] = _gen_id("vless", out["address"], out["port"], out["uuid"])
    return {k: v for k, v in out.items() if v is not None}


def _parse_vmess(link: str) -> dict | None:
    payload = link[len("vmess://"):]
    decoded = _b64_decode_padded(payload)
    if not decoded:
        return None
    try:
        obj = json.loads(decoded.decode("utf-8", errors="replace"))
    except (json.JSONDecodeError, ValueError):
        return None
    addr = obj.get("add")
    port = obj.get("port")
    uuid_ = obj.get("id")
    if not addr or not port or not uuid_:
        return None
    out = {
        "name": obj.get("ps") or "imported",
        "protocol": "vmess",
        "address": addr,
        "port": int(port),
        "uuid": uuid_,
        "alterId": int(obj.get("aid") or 0),
        "security": obj.get("scy") or "auto",
        "transport": obj.get("net") or "tcp",
        "tls": (obj.get("tls") == "tls"),
    }
    if obj.get("sni") or obj.get("host"):
        out["sni"] = obj.get("sni") or obj.get("host")
    if obj.get("path"):
        out["path"] = obj["path"]
    if obj.get("host"):
        out["host"] = obj["host"]
    out["id"] = _gen_id("vmess", out["address"], out["port"], out["uuid"])
    return out


def _parse_ss(link: str) -> dict | None:
    # Two common forms:
    #   ss://base64(method:password)@host:port#name
    #   ss://base64(method:password@host:port)#name
    rest = link[len("ss://"):]
    frag = ""
    if "#" in rest:
        rest, frag = rest.split("#", 1)
    name = _decode_name(frag)

    method: str | None = None
    password: str | None = None
    host: str | None = None
    port: int | None = None

    if "@" in rest:
        creds_b64, host_part = rest.rsplit("@", 1)
        creds = _b64_decode_padded(creds_b64).decode("utf-8", errors="replace")
        if ":" in creds:
            method, password = creds.split(":", 1)
        if ":" in host_part:
            h, p = host_part.rsplit(":", 1)
            host = h
            try:
                port = int(p)
            except ValueError:
                pass
    else:
        whole = _b64_decode_padded(rest).decode("utf-8", errors="replace")
        m = re.match(r"^([^:]+):([^@]+)@([^:]+):(\d+)$", whole)
        if m:
            method, password, host, port = m.group(1), m.group(2), m.group(3), int(m.group(4))

    if not method or not password or not host or not port:
        return None
    return {
        "id": _gen_id("ss", host, port, password),
        "name": name,
        "protocol": "shadowsocks",
        "address": host,
        "port": port,
        "method": method,
        "password": password,
    }


def _parse_socks5(link: str) -> dict | None:
    parsed = urlparse.urlparse(link)
    if not parsed.hostname or not parsed.port:
        return None
    return {
        "id": _gen_id("socks5", parsed.hostname, parsed.port, parsed.username or ""),
        "name": _decode_name(parsed.fragment),
        "protocol": "socks5",
        "host": parsed.hostname,
        "port": int(parsed.port),
        "username": parsed.username,
        "password": parsed.password,
    }


def _gen_id(proto: str, host: str, port: int, secret: str) -> str:
    h = f"{proto}|{host}|{port}|{secret}".encode("utf-8")
    return uuid.uuid5(uuid.NAMESPACE_URL, h.decode("utf-8")).hex[:12]
