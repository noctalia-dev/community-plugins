"""Binance helper for the Noctalia plugin. The only process that holds keys.

Run as `python3 -I binance_helper.py <subcommand> --data-dir <pluginDataDir>`.
Prints one small JSON object on stdout; larger results go to files in the data
directory. Secrets live in the Secret Service keyring and never reach argv,
stdout, logs or files.
"""

import argparse
import base64
import calendar
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal, InvalidOperation

API_HOST = "api.binance.com"
RECV_WINDOW = 5000
RESPONSE_CAP = 8 * 1024 * 1024
REQUEST_TIMEOUT_S = 10
LOCK_WAIT_S = 2.0
API_KEY_RE = re.compile(r"[A-Za-z0-9]{64}")
KEYRING_SERVICE = "noctalia-binance"
# How long an unlock prompt may block a keyring call. The service kills
# account subcommands after 60 s and data subcommands after 30 s, so each
# must give up first to report keyring_locked instead of a timeout.
KEYRING_TIMEOUT_S = 55
DATA_KEYRING_TIMEOUT_S = 20

# Permission gate: reading must be on, and every other enable*/permits* flag
# off. Flags Binance adds later fail closed until they are reviewed here.
READ_ONLY_FLAGS = {"enableReading", "enableFixReadOnly"}
# Flags every response has carried; one that goes missing fails too.
# enablePortfolioMarginTrading is newer and checked only when present.
REQUIRED_OFF_FLAGS = (
    "enableWithdrawals", "enableInternalTransfer", "enableSpotAndMarginTrading", "enableMargin",
    "enableFutures", "permitsUniversalTransfer", "enableVanillaOptions", "enableFixApiTrade",
)

# Files the helper writes; `disconnect` removes these, nothing else.
CACHE_FILES = (
    "account.json", "balances.json", "tokenized-assets.json", "stock-orders.json",
    "stock-orders.json.partial", "stocks.json", "ledger.json", "marks.json",
    "cursors.json", "flows.json", "flows-daily.json", "clock.json", "probe.json", "probe-redacted.json",
    "stock-quotes.json", "equity-symbols.json", "export.csv", "export-request.json",
    "trades.json", "crypto-costs.json",
)
RATELIMIT_FILES = ("ratelimit-public.json", "ratelimit-signed.json")
RATE_HEADERS = (
    "x-mbx-used-weight-1m",
    "x-sapi-used-ip-weight-1m",
    "x-sapi-used-uid-weight-1m",
)


class HelperError(Exception):
    def __init__(self, code, **detail):
        super().__init__(code)
        self.code = code
        self.detail = detail

    def payload(self):
        return {"error": self.code, **self.detail}


def scrub(text):
    """Drop query strings and signatures; urllib errors embed the full URL."""
    text = re.sub(r"\?[^\s'\"<>]*", "?<redacted>", str(text))
    return re.sub(r"signature=[^&\s'\"]*", "signature=<redacted>", text)


def now_ms():
    return int(time.time() * 1000)


# ── Files ───────────────────────────────────────────────────────────────────


def prepare_data_dir(path):
    if not os.path.isabs(path):
        raise HelperError("invalid_data_dir", detail="must be an absolute path")
    os.makedirs(path, mode=0o700, exist_ok=True)
    if os.path.islink(path) or not os.path.isdir(path):
        raise HelperError("invalid_data_dir", detail="not a directory")
    # Covers files Luau wrote with the default umask too.
    os.chmod(path, 0o700)
    return path


def write_json_atomic(path, data):
    """Temp file + rename: readers see the old or new file, never half of one,
    and rename replaces a symlink at `path` instead of following it."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=1, sort_keys=True)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def read_json(path):
    with open(path) as f:
        return json.load(f)


class DataLock:
    """Non-blocking flock with a short retry, so a held lock never eats the
    caller's subprocess timeout."""

    def __init__(self, data_dir, exclusive, name="helper.lock"):
        self.path = os.path.join(data_dir, name)
        self.mode = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH

    def __enter__(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        deadline = time.monotonic() + LOCK_WAIT_S
        while True:
            try:
                fcntl.flock(self.fd, self.mode | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    os.close(self.fd)
                    raise HelperError("busy") from None
                time.sleep(0.1)

    def __exit__(self, *exc):
        os.close(self.fd)


# ── Keyring ─────────────────────────────────────────────────────────────────
#
# Items: key=private slot=pending, key=api slot=pending (built in two steps by
# keygen and store-api-key), and key=pair slot=active holding both as one JSON
# secret, so promotion replaces the active pair in a single store. Every call
# passes all three attributes because `secret-tool lookup` returns the first
# unlocked match.


def keyring_error(stderr):
    text = stderr.strip()
    lower = text.lower()
    if any(s in lower for s in ("org.freedesktop.secrets", "d-bus", "dbus", "autolaunch")):
        return HelperError("no_secret_service")
    if any(s in lower for s in ("locked", "cancel", "dismiss", "prompt")):
        return HelperError("keyring_locked")
    return HelperError("keyring_error", detail=scrub(text.splitlines()[0] if text else ""))


def secret_tool(args, secret=None, timeout=KEYRING_TIMEOUT_S):
    try:
        return subprocess.run(
            ["secret-tool", *args],
            input=secret if secret is not None else "",
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        raise HelperError("missing_dependency", command="secret-tool") from None
    except subprocess.TimeoutExpired:
        raise HelperError("keyring_locked") from None


def attributes(key, slot):
    return ["service", KEYRING_SERVICE, "key", key, "slot", slot]


def keyring_lookup(key, slot, timeout=KEYRING_TIMEOUT_S):
    result = secret_tool(["lookup", *attributes(key, slot)], timeout=timeout)
    if result.returncode == 0 and result.stdout:
        return result.stdout.rstrip("\n")
    if result.stderr.strip():
        raise keyring_error(result.stderr)
    # A dismissed unlock prompt also ends in a silent exit 1. `search`
    # without --unlock lists locked items too, so it tells the two apart.
    # Item details may go to stdout or stderr, so both are read.
    found = secret_tool(["search", *attributes(key, slot)], timeout=timeout)
    listed = re.compile(rf"^(\[/org/freedesktop/secrets/|attribute\.slot = {re.escape(slot)}$)", re.M)
    if listed.search(found.stdout) or listed.search(found.stderr):
        raise HelperError("keyring_locked")
    raise HelperError("item_missing", key=key, slot=slot)


def keyring_find(key, slot):
    try:
        return keyring_lookup(key, slot)
    except HelperError as error:
        if error.code == "item_missing":
            return None
        raise


def keyring_store(key, slot, secret):
    label = f"Noctalia Binance ({key}, {slot})"
    result = secret_tool(["store", f"--label={label}", *attributes(key, slot)], secret)
    if result.returncode != 0:
        raise keyring_error(result.stderr or "store failed")
    if keyring_find(key, slot) != secret.rstrip("\n"):
        raise HelperError("keyring_readback_failed", key=key, slot=slot)


def keyring_clear(key, slot):
    result = secret_tool(["clear", *attributes(key, slot)])
    # clear exits non-zero with no message when nothing matched.
    if result.returncode != 0 and result.stderr.strip():
        raise keyring_error(result.stderr)


def load_active_pair(timeout=KEYRING_TIMEOUT_S):
    raw = keyring_lookup("pair", "active", timeout)
    try:
        pair = json.loads(raw)
        return pair["api_key"], pair["private_key_pem"]
    except (ValueError, KeyError, TypeError):
        raise HelperError("keyring_corrupt", key="pair", slot="active") from None


# ── Signing ─────────────────────────────────────────────────────────────────


def crypto():
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ed25519
    except ImportError:
        raise HelperError("missing_dependency", package="python-cryptography") from None
    return serialization, ed25519


def generate_keypair():
    serialization, ed25519 = crypto()
    key = ed25519.Ed25519PrivateKey.generate()
    private_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    return private_pem, public_pem(key)


def public_pem(private_key):
    serialization, _ = crypto()
    return private_key.public_key().public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode()


def sign(private_key_pem, payload):
    serialization, ed25519 = crypto()
    key = serialization.load_pem_private_key(private_key_pem.encode(), password=None)
    if not isinstance(key, ed25519.Ed25519PrivateKey):
        raise HelperError("keyring_corrupt", detail="stored key is not Ed25519")
    return base64.b64encode(key.sign(payload.encode("ascii"))).decode()


def build_payload(params):
    """`parameter=value` pairs, percent-encoded as UTF-8: the exact string signed."""
    return urllib.parse.urlencode(params, encoding="utf-8")


def signed_query(params, private_key_pem):
    payload = build_payload(params)
    signature = urllib.parse.quote(sign(private_key_pem, payload), safe="")
    return f"{payload}&signature={signature}"


# ── Network ─────────────────────────────────────────────────────────────────


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise HelperError("network_error", detail=f"unexpected redirect ({code})")


OPENER = urllib.request.build_opener(NoRedirect())


def http_get(url, headers):
    """One GET to the allowlisted host. Returns (status, headers, body)."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or parts.hostname != API_HOST:
        raise HelperError("host_not_allowed")
    request = urllib.request.Request(url, headers=headers, method="GET")
    try:
        response = OPENER.open(request, timeout=REQUEST_TIMEOUT_S)
    except urllib.error.HTTPError as error:
        response = error
    except (urllib.error.URLError, OSError) as error:
        raise HelperError("network_error", detail=scrub(error)) from None
    with response:
        body = response.read(RESPONSE_CAP + 1)
        if len(body) > RESPONSE_CAP:
            raise HelperError("response_too_large")
        return response.status, {k.lower(): v for k, v in response.headers.items()}, body


class Binance:
    """Signed client: clock offset, -1021 retry, rate-limit pause files."""

    def __init__(self, data_dir, api_key=None, private_key_pem=None):
        self.data_dir = data_dir
        self.api_key = api_key
        self.private_key_pem = private_key_pem
        self.offset_ms = None
        self.weights = {}

    def paused_until(self):
        until = 0
        for name in RATELIMIT_FILES:
            path = os.path.join(self.data_dir, name)
            if not os.path.exists(path):
                continue
            try:
                until = max(until, int(read_json(path)["until_ms"]))
            except (OSError, ValueError, KeyError, TypeError):
                until = max(until, now_ms() + 60_000)
        return until

    def pause(self, status, retry_after):
        seconds = 600 if status == 418 else 60
        try:
            seconds = max(seconds, int(retry_after))
        except (TypeError, ValueError):
            pass
        until = now_ms() + seconds * 1000
        write_json_atomic(
            os.path.join(self.data_dir, "ratelimit-signed.json"),
            {"until_ms": until, "status": status},
        )
        return until

    def raw(self, path, query, with_key):
        until = self.paused_until()
        if until > now_ms():
            raise HelperError("rate_limited", until_ms=until)
        headers = {"X-MBX-APIKEY": self.api_key} if with_key and self.api_key else {}
        url = f"https://{API_HOST}{path}" + (f"?{query}" if query else "")
        status, response_headers, body = http_get(url, headers)
        for name in RATE_HEADERS:
            if name in response_headers:
                self.weights[name] = response_headers[name]
        if status in (418, 429):
            until = self.pause(status, response_headers.get("retry-after"))
            raise HelperError("rate_limited", status=status, until_ms=until)
        if status == 200 and not body.strip():
            return None  # /equity/market/quote: no quote for this ticker
        try:
            data = json.loads(body)
        except ValueError:
            raise HelperError("bad_response", status=status) from None
        if status != 200:
            code = data.get("code") if isinstance(data, dict) else None
            msg = data.get("msg", "") if isinstance(data, dict) else ""
            raise api_error(status, code, scrub(msg))
        return data

    def sync_clock(self):
        clock_path = os.path.join(self.data_dir, "clock.json")
        started = now_ms()
        try:
            server = self.raw("/api/v3/time", "", with_key=False)["serverTime"]
            self.offset_ms = int(server) - (started + now_ms()) // 2
            write_json_atomic(clock_path, {"offset_ms": self.offset_ms, "at_ms": now_ms()})
        except HelperError as error:
            if error.code == "rate_limited":
                raise
            try:
                self.offset_ms = int(read_json(clock_path)["offset_ms"])
            except (OSError, ValueError, KeyError, TypeError):
                raise error from None

    def get(self, path, params=None, signed=True):
        params = dict(params or {})
        if not signed:
            return self.raw(path, build_payload(params), with_key=True)
        for attempt in range(2):
            if self.offset_ms is None or attempt:
                self.sync_clock()
            query = signed_query(
                {**params, "recvWindow": RECV_WINDOW, "timestamp": now_ms() + self.offset_ms},
                self.private_key_pem,
            )
            try:
                return self.raw(path, query, with_key=True)
            except HelperError as error:
                if error.detail.get("binance_code") != -1021 or attempt:
                    raise
        raise AssertionError("unreachable")


def api_error(status, code, msg):
    if code == -1021:
        name = "clock_skew"
    elif code in (-2014, -2015, -1022):
        name = "auth_rejected"
    else:
        name = "api_error"
    return HelperError(name, status=status, binance_code=code, msg=msg)


# ── Permission gate ─────────────────────────────────────────────────────────


def permission_problems(restrictions):
    """Names of permissions that make the key more than read-only."""
    if not isinstance(restrictions, dict):
        return ["<unexpected response>"]
    problems = []
    if restrictions.get("enableReading") is not True:
        problems.append("enableReading=false")
    for name, value in sorted(restrictions.items()):
        if not name.startswith(("enable", "permits")) or name in READ_ONLY_FLAGS:
            continue
        if value is not False:
            problems.append(name)
    problems += [f"{name} missing" for name in REQUIRED_OFF_FLAGS if name not in restrictions]
    return problems


def check_permissions(client):
    restrictions = client.get("/sapi/v1/account/apiRestrictions")
    problems = permission_problems(restrictions)
    if problems:
        raise HelperError("permissions_too_broad", flags=problems)
    return restrictions


# ── Clipboard ───────────────────────────────────────────────────────────────


def wl_paste(primary=False):
    argv = ["wl-paste", "--no-newline"] + (["--primary"] if primary else [])
    try:
        result = subprocess.run(argv, capture_output=True, timeout=5)
    except FileNotFoundError:
        raise HelperError("missing_dependency", command="wl-paste") from None
    except subprocess.TimeoutExpired:
        return None
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8", "replace")


def clear_selection_if(expected, primary=False):
    """Clear a selection only if it still holds `expected`; returns whether it did.
    Output goes to /dev/null: wl-copy may fork and keep a pipe open."""
    if wl_paste(primary) != expected:
        return False
    argv = ["wl-copy"] + (["--primary"] if primary else []) + ["--clear"]
    try:
        result = subprocess.run(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


# ── Subcommands ─────────────────────────────────────────────────────────────


def cmd_keygen(args):
    private_pem, public_pem = generate_keypair()
    # A pending API key from an abandoned attempt belongs to another key pair.
    keyring_clear("api", "pending")
    keyring_store("private", "pending", private_pem)
    return {"ok": True, "public_key_pem": public_pem}


def cmd_store_api_key(args):
    if keyring_find("private", "pending") is None:
        raise HelperError("no_pending_key")
    raw = wl_paste()
    if raw is None:
        raise HelperError("clipboard_empty")
    api_key = raw.strip()
    if not API_KEY_RE.fullmatch(api_key):
        raise HelperError("invalid_key_format")
    keyring_store("api", "pending", api_key)
    return {
        "ok": True,
        "cleared": {
            "clipboard": clear_selection_if(raw),
            "primary": clear_selection_if(raw, primary=True),
        },
    }


def cmd_verify(args):
    """Verify the pending pair and promote it, or re-verify the active pair.
    Run only from the wizard: it is how a pending pair gets promoted."""
    pending_private = keyring_find("private", "pending")
    pending_api = keyring_find("api", "pending")
    if pending_private or pending_api:
        if not (pending_private and pending_api):
            raise HelperError("pending_incomplete", has_private=bool(pending_private))
        slot, api_key, private_pem = "pending", pending_api, pending_private
    else:
        slot = "active"
        api_key, private_pem = load_active_pair()

    client = Binance(args.data_dir, api_key, private_pem)
    try:
        check_permissions(client)
    except HelperError as error:
        error.detail["slot"] = slot
        raise

    if slot == "pending":
        # One store replaces the active pair; if it fails the old pair stays.
        keyring_store(
            "pair", "active", json.dumps({"api_key": api_key, "private_key_pem": private_pem})
        )
        keyring_clear("private", "pending")
        keyring_clear("api", "pending")
    return {"ok": True, "slot": slot, "promoted": slot == "pending", "verified_at": now_ms()}


def cmd_recheck(args):
    """Re-verify the active pair (the scheduled gate check). Never looks at
    or promotes a pending pair, so an abandoned rotation can't skip it."""
    api_key, private_pem = load_active_pair()
    try:
        check_permissions(Binance(args.data_dir, api_key, private_pem))
    except HelperError as error:
        error.detail["slot"] = "active"
        raise
    return {"ok": True, "slot": "active", "promoted": False, "verified_at": now_ms()}


def cmd_disconnect(args):
    for key, slot in (("private", "pending"), ("api", "pending"), ("pair", "active")):
        keyring_clear(key, slot)
        # A locked collection can make clear a silent no-op.
        if keyring_find(key, slot) is not None:
            raise HelperError("keyring_locked")
    removed = []
    # .tmp-* files are left by helpers killed mid-write and hold the same data.
    names = [*CACHE_FILES, *(n for n in os.listdir(args.data_dir) if n.startswith(".tmp-"))]
    for name in names:
        path = os.path.join(args.data_dir, name)
        if os.path.lexists(path):
            os.unlink(path)
            removed.append(name)
    return {"ok": True, "removed": removed}


# ── Account file ────────────────────────────────────────────────────────────
#
# account.json tells the service the connection stage without spawning the
# helper: keyless mode never runs Python. Rewritten after every keyring
# subcommand; `disconnect` deletes it.

ACCOUNT_COMMANDS = {"keygen", "store-api-key", "verify", "recheck"}
# Subcommands that read account data with the active key; refused while the
# active key fails the read-only gate (account.json "gate_failed").
DATA_COMMANDS = {"balances", "stocks-sync", "flows-sync", "deposits-recent", "stock-quotes", "trades-sync"}
# Error detail worth showing in the wizard; nothing else is copied.
ACCOUNT_ERROR_KEYS = ("flags", "slot", "status", "binance_code", "msg", "until_ms", "has_private", "package", "detail")


def account_from_keyring():
    private = keyring_find("private", "pending")
    api = keyring_find("api", "pending")
    account = {
        "active": keyring_find("pair", "active") is not None,
        "pending": "both" if private and api else "private" if private else "none",
    }
    if private:
        serialization, _ = crypto()
        try:
            key = serialization.load_pem_private_key(private.encode(), password=None)
            account["public_key_pem"] = public_pem(key)
        except ValueError:
            pass  # unreadable pending key: the wizard offers keygen again
    return account


def record_account(data_dir, error=None, verified_at=None, keep_pending_error=False):
    path = os.path.join(data_dir, "account.json")
    account = read_object(path) or {"active": False, "pending": "none"}
    if error is None:
        try:
            observed = account_from_keyring()
        except HelperError:
            observed = {}  # the subcommand succeeded; keep what was known
        # Only a passing verify lifts a failed gate; other steps keep it.
        kept = ("verified_at_ms",) if verified_at is not None else ("verified_at_ms", "gate_failed")
        # A passing re-check of the active key says nothing about the pending
        # one, so the wizard keeps showing why the new key failed.
        last_error = account.get("last_error")
        if keep_pending_error and isinstance(last_error, dict) and last_error.get("slot") == "pending":
            kept += ("last_error",)
        account = {k: v for k, v in account.items() if k in kept} | observed
        if verified_at is not None:
            account["verified_at_ms"] = verified_at
    else:
        if error.code == "item_missing" and error.detail.get("key") == "pair":
            account["active"] = False
        if error.code == "permissions_too_broad" and error.detail.get("slot") == "active":
            account["gate_failed"] = {"flags": error.detail.get("flags") or [], "at_ms": now_ms()}
        account["last_error"] = {
            "code": error.code,
            "at_ms": now_ms(),
            **{k: v for k, v in error.detail.items() if k in ACCOUNT_ERROR_KEYS},
        }
    write_json_atomic(path, {**account, "v": 1})


def check_gate(data_dir):
    """Refuses account data while the active key's last verify failed the
    read-only gate, so a key granted more permissions stops being used."""
    gate = (read_object(os.path.join(data_dir, "account.json")) or {}).get("gate_failed")
    if isinstance(gate, dict):
        raise HelperError("permissions_too_broad", flags=gate.get("flags") or [], slot="active")


# ── Data ────────────────────────────────────────────────────────────────────

BALANCE_PARTS = ("free", "locked", "freeze", "withdrawing")
TOKENIZED_ASSETS_TTL_MS = 24 * 3_600_000
EQUITY_PREFIX = "EQ_"  # wallet code of untokenized Binance Stocks shares
ORDER_WINDOW_MS = 87_600 * 3_600_000 - 60_000  # widest window probe found
PAGE_SIZE = 100
STOCK_MAX_CALLS = 8  # UID-weighted history calls per invocation
# No new request after this; each may take 10 s more, under the 30 s kill.
STOCK_DEADLINE_S = 15
DUST = Decimal("1e-9")


def read_object(path):
    try:
        data = read_json(path)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def num(value, places=10):
    """Decimal -> plain decimal string, rounded, no exponent."""
    text = format(value.quantize(Decimal(1).scaleb(-places)).normalize(), "f")
    return "0" if text in ("-0", "") else text


def utc_day(ms):
    return time.strftime("%Y-%m-%d", time.gmtime(ms / 1000))


def update_ledger(data_dir, day, part, quantities, marks=None):
    """Sets one half (`crypto` or `stocks`) of a day's quantities; a new day
    starts as a copy of the latest earlier day so rows are always complete."""
    with DataLock(data_dir, exclusive=True, name="ledger.lock"):
        path = os.path.join(data_dir, "ledger.json")
        ledger = read_object(path) or {}
        days = ledger.get("days") if isinstance(ledger.get("days"), dict) else {}
        if day not in days:
            earlier = [d for d in days if d < day]
            days[day] = dict(days[max(earlier)]) if earlier else {}
        days[day][part] = quantities
        write_json_atomic(path, {"v": 1, "first_day": min(days), "days": days})
        if marks:
            marks_path = os.path.join(data_dir, "marks.json")
            stored = (read_object(marks_path) or {}).get("marks") or {}
            for symbol, mark in marks.items():
                stored.setdefault(symbol, {})[day] = mark
            write_json_atomic(marks_path, {"v": 1, "marks": stored})


def tokenized_assets(client, data_dir):
    """Tokenized stock codes (NVDAB -> NVDA), refreshed at most daily."""
    path = os.path.join(data_dir, "tokenized-assets.json")
    cached = read_object(path)
    if cached and now_ms() - int(cached.get("at_ms") or 0) < TOKENIZED_ASSETS_TTL_MS:
        return cached.get("assets") or []
    try:
        rows = client.get("/sapi/v1/equity/market/tokenized-assets", signed=False)
    except HelperError as error:
        if cached is None or error.code == "rate_limited":
            raise
        return cached.get("assets") or []
    assets = [
        {
            "asset": r["assetCode"],
            "symbol": r["underlyingEquitySymbol"],
            "name": r.get("assetName") or "",
            "multiplier": r.get("multiplier") or "1",
        }
        for r in (rows if isinstance(rows, list) else [])
        if isinstance(r, dict) and r.get("assetCode") and r.get("underlyingEquitySymbol")
    ]
    write_json_atomic(path, {"v": 1, "at_ms": now_ms(), "assets": assets})
    return assets


def cmd_balances(args):
    client = Binance(args.data_dir, *load_active_pair(DATA_KEYRING_TIMEOUT_S))
    raw = client.get("/sapi/v1/asset/wallet/balance", {"needBalanceDetail": "true"})
    tokens = {a["asset"]: a for a in tokenized_assets(client, args.data_dir)}
    wallets, tokenized, equities, totals = [], [], [], {}
    for wallet in raw if isinstance(raw, list) else []:
        if not isinstance(wallet, dict):
            continue
        assets = []
        for row in wallet.get("assetBalances") or []:
            asset = row.get("asset")
            total = sum(dec(row.get(k, 0)) for k in BALANCE_PARTS)
            if not asset or total == 0:
                continue
            if asset in tokens:
                token = tokens[asset]
                tokenized.append({
                    "asset": asset, "symbol": token["symbol"], "multiplier": token["multiplier"],
                    "wallet": wallet.get("walletName"), "qty": num(total),
                    "shares": num(total * dec(token["multiplier"])),
                })
                continue
            if asset.startswith(EQUITY_PREFIX):
                # Untokenized Binance Stocks shares (EQ_NVDA), held in Funding.
                # stocks-sync values them from the order replay, so they are
                # never crypto.
                equities.append({
                    "asset": asset, "symbol": asset[len(EQUITY_PREFIX):],
                    "wallet": wallet.get("walletName"), "qty": num(total),
                })
                continue
            assets.append({
                "asset": asset, "name": row.get("assetName") or asset,
                **{k: row.get(k) or "0" for k in BALANCE_PARTS},
                "total": num(total), "btc_value": row.get("btcValuation") or "0",
            })
            totals[asset] = totals.get(asset, Decimal(0)) + total
        wallets.append({
            "name": wallet.get("walletName"), "active": bool(wallet.get("activate")),
            "btc_value": wallet.get("balance") or "0", "assets": assets,
        })
    at = now_ms()
    write_json_atomic(
        os.path.join(args.data_dir, "balances.json"),
        {"v": 1, "at_ms": at, "wallets": wallets, "tokenized": tokenized, "equities": equities},
    )
    update_ledger(args.data_dir, utc_day(at), "crypto", {a: num(q) for a, q in sorted(totals.items())})
    return {"ok": True, "at_ms": at, "wallets": len(wallets), "assets": len(totals),
            "tokenized_held": len(tokenized)}


ORDER_FIELDS = ("orderId", "symbol", "side", "orderType", "status", "filledQty", "filledTotal",
                "fee", "avgFilledPrice", "createdAt", "updatedAt")


def replay_stocks(orders, conversions, token_shares, equity_shares=None):
    """Average-cost replay per symbol. BUY adds filledTotal + fee to the cost,
    which reproduces the Binance app's average cost (avgFilledPrice is absent
    on limit orders and not needed). SELL removes cost at the running average
    and realizes the difference. Successful MINTs move shares out of the
    untokenized count and REDEEMs move them back; tokenized shares come from
    the wallet (`token_shares`), so a token is never counted twice.

    `equity_shares` (symbol -> wallet EQ_ quantity, None when unknown) makes
    the wallet authoritative for untokenized shares too: the replay then only
    gives the average cost, and a symbol whose replayed count differs from
    the wallet is flagged `cost_approx`."""
    events = [(int(o.get("createdAt") or 0), 0, o) for o in orders if dec(o.get("filledQty")) > 0]
    events += [(int(c.get("updatedAt") or c.get("createdAt") or 0), 1, c)
               for c in conversions if c.get("status") == "S"]
    events.sort(key=lambda e: (e[0], e[1]))
    book = {}

    def position(symbol):
        return book.setdefault(symbol, {
            "qty": Decimal(0), "cost": Decimal(0), "realized": Decimal(0), "fees": Decimal(0),
            "tokenized": Decimal(0), "orders": 0, "unknown": False,
        })

    for _, kind, row in events:
        if kind == 0:
            p = position(row.get("symbol"))
            qty, fee = dec(row.get("filledQty")), dec(row.get("fee"))
            # filledTotal is documented for market buys only; fall back to
            # quantity x average price, else the cost basis is unknown.
            if row.get("filledTotal") not in (None, ""):
                total = dec(row.get("filledTotal"))
            elif row.get("avgFilledPrice") not in (None, ""):
                total = qty * dec(row.get("avgFilledPrice"))
            else:
                total, p["unknown"] = Decimal(0), True
            p["orders"] += 1
            p["fees"] += fee
            if row.get("side") == "BUY":
                p["qty"] += qty
                p["cost"] += total + fee
            elif row.get("side") == "SELL":
                average = p["cost"] / p["qty"] if p["qty"] > 0 else Decimal(0)
                p["realized"] += total - fee - average * qty
                p["cost"] -= average * qty
                p["qty"] -= qty
        else:
            p = position(row.get("underlyingAsset"))
            shares = dec(row.get("underlyingAssetAmount"))
            p["tokenized"] += shares if row.get("convertType") == "MINT" else -shares

    for symbol in [*token_shares, *(equity_shares or {})]:
        position(symbol)
    positions, closed = [], []
    for symbol, p in sorted(book.items()):
        if not symbol:
            continue
        held = token_shares.get(symbol, Decimal(0))
        replayed = p["qty"] - p["tokenized"] + held
        qty, approx = replayed, False
        if equity_shares is not None:
            qty = equity_shares.get(symbol, Decimal(0)) + held
            approx = abs(qty - replayed) > DUST
        # Tokens beyond the net mints were bought outside the Stocks app, at
        # a cost the order history doesn't have.
        approx = approx or held > p["tokenized"] + DUST
        common = {"fees": num(p["fees"], 8), "orders": p["orders"]}
        if not p["unknown"]:  # an order without a total makes realized meaningless
            common["realized_pnl"] = num(p["realized"], 8)
        if qty > DUST:
            # The average comes from the orders alone: shares that left or
            # entered as tokens don't change what the bought ones cost.
            based = p["orders"] > 0 and p["qty"] > DUST and not p["unknown"]
            average = max(p["cost"], Decimal(0)) / p["qty"] if based else Decimal(0)
            positions.append({
                "symbol": symbol, "qty": num(qty), "avg_cost": num(average, 8),
                "cost": num(average * qty, 8), "cost_known": based, "cost_approx": approx,
                "tokenized_shares": num(held), **common,
            })
        elif p["orders"]:
            closed.append({"symbol": symbol, **common})
    return positions, closed


def fetch_quote(client, symbol, previous):
    try:
        data = client.get("/sapi/v1/equity/market/quote", {"symbol": symbol}, signed=False)
    except HelperError as error:
        if error.code == "rate_limited":
            raise
        data = None
    data = data if isinstance(data, dict) else {}
    bid, ask = dec(data.get("bidPrice")), dec(data.get("askPrice"))
    sides = [p for p in (bid, ask) if p > 0]
    if sides:
        return {"bid": num(bid, 8), "ask": num(ask, 8), "mid": num(sum(sides) / len(sides), 8),
                "at_ms": now_ms(), "stale": False}
    if previous:
        return {**previous, "stale": True}
    return None


def fetch_history_pages(client, cursor, partial, deadline):
    """Advances the order-history then tokenized-history paging by at most
    STOCK_MAX_CALLS requests, none started after `deadline` (monotonic).
    Returns True when both are complete."""
    for _ in range(STOCK_MAX_CALLS):
        if time.monotonic() > deadline:
            return False
        if not cursor["orders_done"]:
            data = client.get("/sapi/v1/equity/order/history", {
                "startTime": cursor["end_ms"] - ORDER_WINDOW_MS, "endTime": cursor["end_ms"],
                "orderStatus": EQUITY_STATUSES, "current": cursor["next_page"], "size": PAGE_SIZE,
            })
            rows = (data or {}).get("rows") or []
            partial["orders"].extend({k: r.get(k) for k in ORDER_FIELDS if k in r} for r in rows)
            total = int((data or {}).get("total") or 0)
            cursor["orders_done"] = len(rows) < PAGE_SIZE or cursor["next_page"] * PAGE_SIZE >= total
            cursor["next_page"] += 1
        else:
            params = {"size": PAGE_SIZE}
            if cursor.get("tokenized_last_id") is not None:
                params["lastId"] = cursor["tokenized_last_id"]
            data = client.get("/sapi/v1/equity/tokenized/history", params) or {}
            partial["tokenized"].extend(data.get("rows") or [])
            if not data.get("hasMore") or data.get("nextLastId") is None:
                return True
            cursor["tokenized_last_id"] = data["nextLastId"]
    return False


def cmd_stocks_sync(args):
    data_dir = args.data_dir
    client = Binance(data_dir, *load_active_pair(DATA_KEYRING_TIMEOUT_S))
    cursors_path = os.path.join(data_dir, "cursors.json")
    partial_path = os.path.join(data_dir, "stock-orders.json.partial")
    cursors = read_object(cursors_path) or {}
    cursor = cursors.get("stocks")
    partial = read_object(partial_path) if cursor else None
    if not isinstance(cursor, dict) or partial is None:
        started = now_ms()
        cursor = {"run_started_ms": started, "end_ms": started, "next_page": 1, "orders_done": False}
        partial = {"orders": [], "tokenized": []}

    calls_before = cursor["next_page"]
    deadline = args.started + STOCK_DEADLINE_S
    try:
        done = fetch_history_pages(client, cursor, partial, deadline)
    except Exception:
        # Keep the pages already fetched; the next run resumes from here.
        write_json_atomic(partial_path, partial)
        write_json_atomic(cursors_path, cursors | {"stocks": cursor})
        raise
    if not done:
        write_json_atomic(partial_path, partial)
        write_json_atomic(cursors_path, cursors | {"stocks": cursor})
        return {"ok": True, "done": False, "pages": cursor["next_page"] - calls_before}

    orders = list({str(o.get("orderId")): o for o in partial["orders"]}.values())
    at = now_ms()
    write_json_atomic(os.path.join(data_dir, "stock-orders.json"),
                      {"v": 1, "at_ms": at, "orders": orders, "tokenized": partial["tokenized"]})

    balances = read_object(os.path.join(data_dir, "balances.json")) or {}
    token_shares, equity_shares = {}, None
    for token in balances.get("tokenized") or []:
        symbol = token.get("symbol")
        token_shares[symbol] = token_shares.get(symbol, Decimal(0)) + dec(token.get("shares"))
    if isinstance(balances.get("equities"), list):
        # Wallet EQ_ rows are the share count; before the first balances run
        # (or with a pre-v1.2 file) the replay stands in.
        equity_shares = {}
        for row in balances["equities"]:
            symbol = row.get("symbol")
            equity_shares[symbol] = equity_shares.get(symbol, Decimal(0)) + dec(row.get("qty"))
    positions, closed = replay_stocks(orders, partial["tokenized"], token_shares, equity_shares)

    previous = {p["symbol"]: p.get("quote") for p in
                (read_object(os.path.join(data_dir, "stocks.json")) or {}).get("positions") or []}
    marks, stale = {}, 0
    for position in positions:
        last = previous.get(position["symbol"])
        if time.monotonic() > deadline:
            # Out of time: keep the last quote so the sync still completes.
            quote = {**last, "stale": True} if last else None
        else:
            quote = fetch_quote(client, position["symbol"], last)
        if quote is None:
            stale += 1
            continue
        position["quote"] = quote
        if quote["stale"]:
            stale += 1
        else:
            marks[position["symbol"]] = {"mid": quote["mid"], "at_ms": quote["at_ms"]}

    filled = [o for o in orders if dec(o.get("filledQty")) > 0]
    times = [int(o.get("createdAt") or 0) for o in filled]
    write_json_atomic(os.path.join(data_dir, "stocks.json"), {
        "v": 1, "at_ms": at, "quote_currency": "USD", "positions": positions, "closed": closed,
        "orders": {"rows": len(orders), "filled": len(filled),
                   **({"first_ms": min(times), "last_ms": max(times)} if times else {})},
    })
    update_ledger(data_dir, utc_day(at), "stocks",
                  {p["symbol"]: p["qty"] for p in positions}, marks)
    if positions and time.monotonic() <= deadline:
        # Held stocks need the listing's session flags even when none is
        # watched (stock-quotes then never runs). Cached daily; optional.
        try:
            equity_symbols(client, data_dir)
        except HelperError:
            pass
    cursors.pop("stocks", None)
    write_json_atomic(cursors_path, cursors)
    if os.path.exists(partial_path):
        os.unlink(partial_path)
    return {"ok": True, "done": True, "at_ms": at, "positions": len(positions),
            "quotes_ok": len(positions) - stale, "quotes_stale": stale,
            "cost_approx": sum(1 for p in positions if p["cost_approx"])}


# ── Watched stocks ──────────────────────────────────────────────────────────
#
# Stock tickers in the watchlist (and stock alerts) are stored by the service
# in prefs.json as EQ_<TICKER>, the wallet's own code for Binance Stocks
# shares. Their quotes need the API key (/equity/market/quote refuses keyless
# calls with -2014), so they come from here, not from the service.

EQUITY_SYMBOLS_TTL_MS = 24 * 3_600_000
STOCK_WATCH_MAX = 30
TICKER_RE = re.compile(r"[A-Z0-9]{1,16}")


def equity_symbols(client, data_dir):
    """Tickers Binance Stocks lists (exchangeInfo, weight 1), refreshed at most
    daily into equity-symbols.json: ticker -> {"overnight": bool,
    "extended": bool}. `extended` is false only when Binance says the
    symbol has no pre- and post-market session."""
    path = os.path.join(data_dir, "equity-symbols.json")
    cached = read_object(path)
    if cached and now_ms() - int(cached.get("at_ms") or 0) < EQUITY_SYMBOLS_TTL_MS:
        return cached.get("symbols") or {}
    try:
        data = client.get("/sapi/v1/equity/market/exchangeInfo", signed=False)
    except HelperError as error:
        if cached is None or error.code == "rate_limited":
            raise
        return cached.get("symbols") or {}
    symbols = {
        row["symbol"]: {"overnight": row.get("overnightSupported") is True,
                        "extended": row.get("extendedSession") is not False}
        for row in ((data or {}).get("symbols") or [])
        if isinstance(row, dict) and isinstance(row.get("symbol"), str) and TICKER_RE.fullmatch(row["symbol"])
    }
    write_json_atomic(path, {"v": 1, "at_ms": now_ms(), "symbols": symbols})
    return symbols


def watched_stocks(data_dir):
    """Tickers the service's prefs.json watches or alerts on, in list order."""
    prefs = read_object(os.path.join(data_dir, "prefs.json")) or {}
    alerts = [a.get("symbol") for a in prefs.get("alerts") or []
              if isinstance(a, dict) and a.get("enabled") is not False]
    out = []
    for symbol in [*(prefs.get("watchlist") or []), *alerts]:
        if not isinstance(symbol, str) or not symbol.startswith(EQUITY_PREFIX):
            continue
        ticker = symbol[len(EQUITY_PREFIX):]
        if TICKER_RE.fullmatch(ticker) and ticker not in out:
            out.append(ticker)
    return out[:STOCK_WATCH_MAX]


def cmd_stock_quotes(args):
    data_dir = args.data_dir
    client = Binance(data_dir, *load_active_pair(DATA_KEYRING_TIMEOUT_S))
    deadline = args.started + STOCK_DEADLINE_S
    listed = equity_symbols(client, data_dir)
    path = os.path.join(data_dir, "stock-quotes.json")
    previous = (read_object(path) or {}).get("quotes") or {}
    quotes, unknown, stale = {}, [], 0
    for ticker in watched_stocks(data_dir):
        if ticker not in listed:
            unknown.append(ticker)
            continue
        last = previous.get(ticker) if isinstance(previous.get(ticker), dict) else None
        if time.monotonic() > deadline:
            quote = {**last, "stale": True} if last else None
        else:
            quote = fetch_quote(client, ticker, last)
        if quote is None:
            stale += 1
            continue
        if quote["stale"]:
            stale += 1
        else:
            # The day change is against the last quote of an earlier UTC day,
            # the same base Holdings uses for stocks (marks.json).
            day = utc_day(quote["at_ms"])
            if last and last.get("day") == day:
                quote |= {k: last[k] for k in ("prev_mid", "prev_day") if k in last}
            elif last and last.get("mid") and last.get("day"):
                quote |= {"prev_mid": last["mid"], "prev_day": last["day"]}
            quote["day"] = day
        quotes[ticker] = quote
    at = now_ms()
    write_json_atomic(path, {"v": 1, "at_ms": at, "quotes": quotes, "unknown": unknown})
    return {"ok": True, "done": True, "at_ms": at, "quotes": len(quotes) - stale, "stale": stale,
            "unknown": len(unknown)}


# ── Flows ───────────────────────────────────────────────────────────────────
#
# Deposits and withdrawals of every kind, for the return on net deposits.
# Each source is scanned in time windows: backwards from the first run down
# to its floor (Binance's opening, or the source's lookback limit), then
# forwards from where it stopped on later runs, re-reading the last week so
# that pending rows that completed since are picked up. One invocation does
# a bounded chunk; cursors.json["flows"] holds where each source stands.

DAY_MS = 86_400_000
HOUR_MS = 3_600_000
FLOWS_FLOOR_MS = 1_498_867_200_000  # 2017-07-01 UTC, before Binance opened
FLOW_OVERLAP_MS = 7 * DAY_MS
FLOW_FRESH_MS = 10 * 60_000  # a forward scan newer than this needs no repeat
FLOW_MAX_UID_CALLS = 8  # UID-weighted calls per invocation
FLOW_MAX_CALLS = 24  # all history calls per invocation
FLOW_MAX_KLINES = 40  # 1h kline lookups per invocation (weight 2 each)
FLOW_DEADLINE_S = 9  # no new request after this; each may take 10 s more
# Binance allows 180 000 UID weight a minute per endpoint; stay under it
# across invocations (the per-minute use is kept in cursors.json).
UID_MINUTE_BUDGET = 150_000
UID_HEADER = "x-sapi-used-uid-weight-1m"
UID_HEADER_CAP = 170_000
WITHDRAW_TIME_FORMAT = "%Y-%m-%d %H:%M:%S"  # UTC
STABLE_USD = {"USDT", "USD"}

# source -> how to read it. `window_days` is the widest window tried; a
# window the endpoint rejects is halved down to `min_days`. `lookback_days`
# is how far back the endpoint serves data at all. `paging`: "offset" (list
# responses), "page" (wrapped responses with `total`) or None (Pay: a full
# page halves the window instead).
FLOW_SOURCES = {
    "deposit": {"path": "/sapi/v1/capital/deposit/hisrec", "uid": 0, "window_days": 89,
                "paging": "offset", "rows": 1000},
    "withdraw": {"path": "/sapi/v1/capital/withdraw/history", "uid": 18_000, "window_days": 89,
                 "paging": "offset", "rows": 1000},
    "fiat_deposit": {"path": "/sapi/v1/fiat/orders", "uid": 45_000, "window_days": 365, "min_days": 89,
                     "paging": "page", "rows": 500, "params": {"transactionType": "0"},
                     "time_keys": ("beginTime", "endTime")},
    "fiat_withdraw": {"path": "/sapi/v1/fiat/orders", "uid": 45_000, "window_days": 365, "min_days": 89,
                      "paging": "page", "rows": 500, "params": {"transactionType": "1"},
                      "time_keys": ("beginTime", "endTime")},
    "card_buy": {"path": "/sapi/v1/fiat/payments", "uid": 0, "window_days": 365, "min_days": 89,
                 "paging": "page", "rows": 500, "params": {"transactionType": "0"},
                 "time_keys": ("beginTime", "endTime")},
    "p2p": {"path": "/sapi/v1/c2c/orderMatch/listUserOrderHistory", "uid": 0, "window_days": 29,
            "paging": "page", "rows": 100, "lookback_days": 180,
            "time_keys": ("startTimestamp", "endTimestamp")},
    "pay": {"path": "/sapi/v1/pay/transactions", "uid": 3_000, "window_days": 89,
            "paging": None, "rows": 100, "lookback_days": 540, "limit_key": "limit"},
}
# Shown as "not counted" when the account is older than the lookback.
LOOKBACK_GAPS = {"p2p": "p2p_older_than_6_months", "pay": "pay_older_than_18_months"}


def withdraw_time(row):
    for key in ("completeTime", "applyTime"):
        try:
            return calendar.timegm(time.strptime(row.get(key) or "", WITHDRAW_TIME_FORMAT)) * 1000
        except ValueError:
            continue
    return 0


def flow_from_row(source, row):
    """One history row -> a completed flow, or None. Amounts are what crossed
    the account boundary: the gross amount paid in, the net amount received
    out, so fees count against the return."""
    if not isinstance(row, dict):
        return None
    if source == "deposit":
        # 1 = success, 6 = credited but not yet withdrawable.
        if row.get("status") not in (1, 6):
            return None
        return ("in", row.get("coin"), row.get("amount"), row.get("insertTime"), row.get("id") or row.get("txId"))
    if source == "withdraw":
        if row.get("status") != 6:  # completed
            return None
        return ("out", row.get("coin"), row.get("amount"), withdraw_time(row), row.get("id"))
    if source in ("fiat_deposit", "fiat_withdraw"):
        if row.get("status") not in ("Successful", "Finished"):
            return None
        if source == "fiat_deposit":
            return ("in", row.get("fiatCurrency"), row.get("indicatedAmount"), row.get("createTime"), row.get("orderNo"))
        return ("out", row.get("fiatCurrency"), row.get("amount"), row.get("createTime"), row.get("orderNo"))
    if source == "card_buy":
        # Paid with the fiat balance: that money was counted when deposited.
        if row.get("status") not in ("Completed", "Successful", "Finished") or row.get("paymentMethod") == "Cash Balance":
            return None
        return ("in", row.get("fiatCurrency"), row.get("sourceAmount"), row.get("createTime"), row.get("orderNo"))
    if source == "p2p":
        if row.get("orderStatus") != "COMPLETED" or row.get("tradeType") not in ("BUY", "SELL"):
            return None
        direction = "in" if row["tradeType"] == "BUY" else "out"
        # Paid in euros: the euro amount is exact; anything else is valued
        # as the crypto that moved.
        if row.get("fiat") == "EUR":
            return (direction, "EUR", row.get("totalPrice"), row.get("createTime"), row.get("orderNumber"))
        return (direction, row.get("asset"), row.get("amount"), row.get("createTime"), row.get("orderNumber"))
    if source == "pay":
        amount = dec(row.get("amount"))
        if amount == 0:
            return None
        return ("in" if amount > 0 else "out", row.get("currency"), num(abs(amount)),
                row.get("transactionTime"), row.get("transactionId"))
    return None


def flow_record(source, row):
    parsed = flow_from_row(source, row)
    if parsed is None:
        return None
    direction, asset, amount, at, row_id = parsed
    try:
        at = int(at or 0)
    except (TypeError, ValueError):
        at = 0
    if not asset or dec(amount) <= 0 or at <= 0 or row_id in (None, ""):
        return None
    return {"id": f"{source}:{row_id}", "source": source, "dir": direction, "asset": asset,
            "amount": num(dec(amount)), "at_ms": at}


class FlowBudget:
    """Per-invocation limits plus the per-minute UID weight per endpoint,
    carried over between invocations in the cursor file."""

    def __init__(self, client, minute, started):
        self.client = client
        self.minute = minute  # path -> [window start ms, weight used]
        self.started = started
        self.calls = self.uid_calls = self.klines = 0

    def out_of_time(self):
        return time.monotonic() - self.started > FLOW_DEADLINE_S

    def uid_free_at(self, path, cost):
        """None if a call of `cost` fits now, else when it will."""
        if not cost:
            return None
        start, used = self.minute.get(path) or (0, 0)
        if now_ms() - start >= 60_000:
            start, used = now_ms(), 0
            self.minute[path] = [start, used]
        header = int(self.client.weights.get(UID_HEADER) or 0)
        if used + cost <= UID_MINUTE_BUDGET and header + cost <= UID_HEADER_CAP:
            return None
        return start + 60_000

    def can_call(self, source):
        spec = FLOW_SOURCES[source]
        if self.out_of_time() or self.calls >= FLOW_MAX_CALLS:
            return False
        return not spec["uid"] or self.uid_calls < FLOW_MAX_UID_CALLS

    def spend(self, path, cost):
        self.calls += 1
        if cost:
            self.uid_calls += 1
            self.minute.setdefault(path, [now_ms(), 0])[1] += cost


def flow_floor(source, at):
    lookback = FLOW_SOURCES[source].get("lookback_days")
    return max(FLOWS_FLOOR_MS, at - lookback * DAY_MS) if lookback else FLOWS_FLOOR_MS


def next_flow_window(cursor, source, at):
    """The window to read next, or None when the source is up to date (or
    failed during this run)."""
    if "error" in cursor:
        return None
    if cursor.get("scan"):
        return cursor["scan"]
    window = cursor["window_ms"]
    floor = flow_floor(source, at)
    if cursor["from_ms"] > floor:
        return {"dir": "back", "start": max(floor, cursor["from_ms"] - window), "end": cursor["from_ms"], "page": 1}
    if "fwd_from" in cursor or cursor["to_ms"] < at - FLOW_FRESH_MS:
        # Catching up starts a week back: rows pending then may be done now.
        start = cursor.get("fwd_from", max(floor, cursor["to_ms"] - FLOW_OVERLAP_MS))
        return {"dir": "fwd", "start": start, "end": min(at, start + window), "page": 1}
    return None


def fetch_flow_page(client, source, scan):
    spec = FLOW_SOURCES[source]
    start_key, end_key = spec.get("time_keys", ("startTime", "endTime"))
    params = {**spec.get("params", {}), start_key: scan["start"], end_key: scan["end"]}
    if spec["paging"] == "offset":
        params.update(offset=(scan["page"] - 1) * spec["rows"], limit=spec["rows"])
    elif spec["paging"] == "page":
        params.update(page=scan["page"], rows=spec["rows"])
    else:
        params[spec["limit_key"]] = spec["rows"]
    data = client.get(spec["path"], params)
    if isinstance(data, list):
        return data, None
    if not isinstance(data, dict):
        raise HelperError("bad_response")
    if data.get("success") is False or data.get("code") not in (None, "000000"):
        raise HelperError("api_error", status=200, binance_code=data.get("code"), msg=scrub(data.get("message") or ""))
    rows = data.get("data") or []
    return rows, data.get("total")


def step_flow_source(budget, cursors, source, flows, at):
    """Reads one page of one source. Returns True if it made a request, the
    time a UID-limited source may continue, or None when it has nothing to
    do (or no budget) in this invocation."""
    spec = FLOW_SOURCES[source]
    cursor = cursors[source]
    if not budget.can_call(source):
        return None
    scan = next_flow_window(cursor, source, at)
    if scan is None:
        return None
    wait = budget.uid_free_at(spec["path"], spec["uid"])
    if wait is not None:
        return wait
    cursor["scan"] = scan
    budget.spend(spec["path"], spec["uid"])
    try:
        rows, total = fetch_flow_page(budget.client, source, scan)
    except HelperError as error:
        if error.code != "api_error":
            raise
        cursor.pop("scan", None)
        min_ms = spec.get("min_days", spec["window_days"]) * DAY_MS
        if cursor["window_ms"] > min_ms:
            # The widest window this endpoint takes, remembered.
            cursor["window_ms"] = cursor["max_window_ms"] = max(min_ms, cursor["window_ms"] // 2)
        else:
            cursor["error"] = {k: v for k, v in error.payload().items() if k in ("error", "binance_code", "msg")}
        return True
    for row in rows:
        flow = flow_record(source, row)
        if flow is not None:
            old = flows.get(flow["id"])
            if old and old["amount"] == flow["amount"] and old["asset"] == flow["asset"]:
                flow = old  # keeps its valuation
            flows[flow["id"]] = flow
    full = len(rows) >= spec["rows"]
    if spec["paging"] == "page" and total is not None:
        full = scan["page"] * spec["rows"] < int(total or 0)
    if full and spec["paging"]:
        scan["page"] += 1
        return True
    cursor.pop("scan", None)
    if full and scan["end"] - scan["start"] > HOUR_MS:
        # Pay has no paging: narrow the window until a page holds it.
        cursor["window_ms"] = max(HOUR_MS, (scan["end"] - scan["start"]) // 2)
        return True
    if scan["dir"] == "fwd":
        cursor["fwd_from"] = scan["end"]
        if scan["end"] >= at:
            cursor["to_ms"] = cursor.pop("fwd_from")
    else:
        cursor["from_ms"] = scan["start"]
    cursor["window_ms"] = min(cursor.get("max_window_ms", spec["window_days"] * DAY_MS), cursor["window_ms"] * 2)
    return True


def advance_flows(budget, cursors, flows, at, sources):
    """One page per source in turn, so no source starves the others.
    Returns the times at which UID-limited sources may continue."""
    waits = {}
    progress = True
    while progress:
        progress = False
        for source in sources:
            result = step_flow_source(budget, cursors, source, flows, at)
            if result is True:
                progress = True
                waits.pop(source, None)
            elif result is not None:
                waits[source] = result
    return waits


def kline_close(client, symbol, at):
    """USDT close of the 1h candle holding `at`, or None if the pair had no
    candle near then. Raises when Binance rejects the request."""
    hour = at - at % HOUR_MS
    rows = client.raw("/api/v3/klines", build_payload(
        {"symbol": symbol, "interval": "1h", "startTime": hour, "limit": 1}), with_key=False)
    if not isinstance(rows, list) or not rows or not isinstance(rows[0], list) or len(rows[0]) < 5:
        return None
    if int(rows[0][0]) - hour > 7 * DAY_MS:  # the pair opened long after the flow
        return None
    close = dec(rows[0][4])
    return close if close > 0 else None


class OutOfLookups(Exception):
    pass


class FlowPricer:
    """Flow-time USD prices from public 1h klines, memoized per hour."""

    def __init__(self, budget):
        self.budget = budget
        self.memo = {}

    def close(self, symbol, at):
        key = (symbol, at - at % HOUR_MS)
        if key not in self.memo:
            if self.budget.klines >= FLOW_MAX_KLINES or self.budget.out_of_time():
                raise OutOfLookups
            self.budget.klines += 1
            try:
                self.memo[key] = kline_close(self.budget.client, symbol, at)
            except HelperError as error:
                # A 400 (unknown symbol, delisted pair, bad parameter) would
                # fail the same way on every retry; other statuses may pass later.
                if error.code != "api_error" or error.detail.get("status") != 400:
                    raise
                self.memo[key] = "invalid"
        return self.memo[key]

    def usd_price(self, asset, at):
        """USD per unit, or None if it cannot be priced. Raises OutOfLookups
        when this invocation's lookups are used up."""
        if asset in STABLE_USD:
            return Decimal(1)
        if asset == "EUR":
            price = self.close("EURUSDT", at)
            return price if price != "invalid" else None
        direct = self.close(f"{asset}USDT", at)
        if direct not in (None, "invalid"):
            return direct
        inverse = self.close(f"USDT{asset}", at)  # fiat such as BRL or TRY
        if inverse not in (None, "invalid"):
            return 1 / inverse
        return None


def value_flows(budget, flows):
    """Adds `usd` and `eurusd` at flow time. Returns False if lookups ran out
    first. A flow that cannot be priced is marked so and never retried."""
    pricer = FlowPricer(budget)
    try:
        for flow in sorted(flows.values(), key=lambda f: f["at_ms"]):
            if "usd" not in flow and not flow.get("unpriced"):
                price = pricer.usd_price(flow["asset"], flow["at_ms"])
                if price is None:
                    flow["unpriced"] = True
                else:
                    flow["usd"] = num(dec(flow["amount"]) * price, 8)
            if "eurusd" not in flow and not flow.get("no_eurusd"):
                rate = pricer.close("EURUSDT", flow["at_ms"])
                if rate in (None, "invalid"):
                    flow["no_eurusd"] = True  # before EURUSDT listed (2020)
                else:
                    flow["eurusd"] = num(rate, 8)
    except OutOfLookups:
        return False
    return True


def daily_flows(flows):
    """Per-day sums of `flows` (sorted by time), so the service never reads
    or sorts every flow: amounts in and out in USD and in EUR at flow-time
    rates, what can never be valued in each, and how many flows are still
    waiting for a price lookup (`awaiting`, cleared by a later chunk)."""
    out = {}
    for flow in flows:
        day = out.setdefault(utc_day(flow["at_ms"]), {
            "in_usd": Decimal(0), "out_usd": Decimal(0), "in_eur": Decimal(0), "out_eur": Decimal(0),
            "valued": 0, "no_usd": 0, "no_eur": 0, "no_eur_usd": Decimal(0), "awaiting": 0})
        side = "in" if flow["dir"] == "in" else "out"
        if "usd" not in flow:
            if flow.get("unpriced"):
                day["no_usd"] += 1
                day["no_eur"] += 1
            else:
                day["awaiting"] += 1
            continue
        usd = dec(flow["usd"])
        day["valued"] += 1
        day[f"{side}_usd"] += usd
        rate = dec(flow.get("eurusd"))
        if rate > 0:
            day[f"{side}_eur"] += usd / rate
        elif flow.get("no_eurusd"):
            day["no_eur"] += 1
            day["no_eur_usd"] += usd
        else:
            day["awaiting"] += 1
    return [{"day": d, **{k: num(v, 8) if isinstance(v, Decimal) else v for k, v in sums.items()}}
            for d, sums in out.items()]


def flow_coverage(cursors, at):
    coverage = {}
    for source in FLOW_SOURCES:
        cursor = cursors[source]
        entry = {
            "from_day": utc_day(cursor["from_ms"]), "from_ms": cursor["from_ms"], "to_ms": cursor["to_ms"],
            "complete": cursor["from_ms"] <= flow_floor(source, at) and "error" not in cursor,
        }
        if "error" in cursor:
            entry["error"] = cursor["error"].get("error", "api_error")
        coverage[source] = entry
    return coverage


def cmd_flows_sync(args, sources_to_read=tuple(FLOW_SOURCES)):
    data_dir = args.data_dir
    client = Binance(data_dir, *load_active_pair(DATA_KEYRING_TIMEOUT_S))
    cursors_path = os.path.join(data_dir, "cursors.json")
    flows_path = os.path.join(data_dir, "flows.json")
    cursors = read_object(cursors_path) or {}
    state = cursors.get("flows") if isinstance(cursors.get("flows"), dict) else {}
    at = now_ms()
    sources = state.get("sources") if isinstance(state.get("sources"), dict) else {}
    new_run = state.get("done", True)
    recent = sources_to_read != tuple(FLOW_SOURCES)
    if recent and not new_run:
        return {"ok": True, "done": True, "skipped": True}  # a full sync is under way
    for source, spec in FLOW_SOURCES.items():
        cursor = sources.get(source)
        if not isinstance(cursor, dict) or not {"from_ms", "to_ms", "window_ms"} <= cursor.keys():
            sources[source] = {"from_ms": at, "to_ms": at, "window_ms": spec["window_days"] * DAY_MS}
        elif new_run and not recent:
            cursor.pop("error", None)  # a failed source is retried once per run
    if recent and any(sources[s]["from_ms"] > flow_floor(s, at) for s in sources_to_read):
        return {"ok": True, "done": True, "skipped": True}  # not backfilled yet
    stored = read_object(flows_path) or {}
    flows = {f["id"]: f for f in stored.get("flows") or [] if isinstance(f, dict) and f.get("id")}
    budget = FlowBudget(client, state.get("uid_minute") or {}, args.started)

    def save(done):
        coverage = flow_coverage(sources, at)
        ordered = sorted(flows.values(), key=lambda f: (f["at_ms"], f["id"]))
        complete = all(c["complete"] for c in coverage.values())
        since = ordered[0]["at_ms"] if ordered else None
        uncovered = [gap for source, gap in LOOKBACK_GAPS.items()
                     if since is None or since < coverage[source]["from_ms"]]
        uncovered += [f"{s}_unavailable" for s, c in coverage.items() if "error" in c]
        uncovered.append("gifts_and_rewards")
        summary = {
            # at_ms: the last full sync, which the service schedules from.
            "v": 1, "at_ms": stored.get("at_ms", at) if recent else at, "coverage": coverage, "uncovered": uncovered,
            "complete": complete, **({"since_day": utc_day(since)} if since else {}),
        }
        write_json_atomic(flows_path, {**summary, "flows": ordered})
        # What the service reads: the same summary with per-day sums.
        write_json_atomic(os.path.join(data_dir, "flows-daily.json"),
                          {**summary, "count": len(ordered), "days": daily_flows(ordered)})
        write_json_atomic(cursors_path, cursors | {"flows": {
            "done": done, "sources": sources, "uid_minute": budget.minute}})

    try:
        waits = advance_flows(budget, sources, flows, at, sources_to_read)
        valued = value_flows(budget, flows)
    except HelperError:
        save(False)  # keep what this chunk read; the next run resumes here
        raise
    pending = [s for s in sources_to_read if next_flow_window(sources[s], s, at)]
    save(recent or (not pending and valued))
    if pending or not valued:
        # Only UID-limited work left: say when it can continue.
        wait_ms = 0
        if valued and set(pending) <= set(waits):
            wait_ms = max(0, min(waits.values()) - now_ms())
        return {"ok": True, "done": False, "sources_pending": pending, "wait_ms": wait_ms}
    return {"ok": True, "done": True, "at_ms": at, "flows": len(flows),
            "unpriced": sum(1 for f in flows.values() if f.get("unpriced"))}


def cmd_deposits_recent(args):
    """Crypto deposits since the last scan (IP weight 1), run with balances
    so that a fresh deposit isn't read as profit until the next full sync.
    Skipped until the full sync has read deposits back to their floor."""
    return cmd_flows_sync(args, ("deposit",))


# ── Crypto cost basis ──────────────────────────────────────────────────────

# Spot pairs are read for each held coin against these quotes. Binance keeps
# no per-coin purchase price, so the cost comes from replaying these fills
# together with deposits and withdrawals valued at flow time (flows.json).
TRADE_QUOTES = ("USDT", "USDC", "FDUSD", "BTC", "ETH", "BNB", "EUR")
# Cash, with no basis to track: the stablecoins and fiat of lib/allocation.luau.
NO_COST_ASSETS = {
    "USDT", "USDC", "FDUSD", "TUSD", "USDP", "DAI", "PYUSD", "USDE", "USD1", "RLUSD", "BFUSD", "BUSD",
    "EURI", "AEUR", "EURC",
    "USD", "EUR", "GBP", "TRY", "BRL", "ARS", "MXN", "PLN", "RON", "CZK", "UAH", "ZAR", "JPY", "AUD",
    "COP", "KZT", "NGN", "IDR", "CHF", "SEK", "NOK",
}
TRADE_PAGE = 1000
TRADE_MAX_CALLS = 30  # myTrades calls per invocation, weight 20 each
TRADE_INVALID_TTL_MS = 30 * DAY_MS  # how long a pair that doesn't exist stays skipped
TRADE_REFRESH_MS = 50 * 60_000  # a pair read this recently is up to date
TRADE_IP_WEIGHT_CAP = 4000  # of Binance's 6000 per minute per IP: stop the chunk above it
COST_MISMATCH = Decimal("0.01")  # replay vs wallet share above which the basis is approximate


def trade_fill(row):
    if not isinstance(row, dict) or row.get("id") is None or dec(row.get("qty")) <= 0:
        return None
    return {"id": int(row["id"]), "at_ms": int(row.get("time") or 0), "qty": num(dec(row.get("qty"))),
            "quote_qty": num(dec(row.get("quoteQty"))), "buyer": bool(row.get("isBuyer")),
            "fee": num(dec(row.get("commission"))), "fee_asset": row.get("commissionAsset") or ""}


def held_coins(balances):
    coins = set()
    for wallet in (balances or {}).get("wallets") or []:
        for a in wallet.get("assets") or []:
            if dec(a.get("total")) > 0 and a.get("asset") and a["asset"] not in NO_COST_ASSETS:
                coins.add(a["asset"])
    return coins


def wallet_quantities(balances):
    qty = {}
    for wallet in (balances or {}).get("wallets") or []:
        for a in wallet.get("assets") or []:
            if a.get("asset"):
                qty[a["asset"]] = qty.get(a["asset"], Decimal(0)) + dec(a.get("total"))
    return qty


def price_fills(pricer, pairs):
    """Adds `px` (USD per quote unit) and, for a fee paid in a third asset,
    `fee_usd`, at trade time. Raises OutOfLookups when lookups run out."""
    for pair in pairs.values():
        for fill in pair["fills"]:
            if "px" not in fill and not fill.get("unpriced"):
                price = pricer.usd_price(pair["quote"], fill["at_ms"])
                if price is None:
                    fill["unpriced"] = True
                else:
                    fill["px"] = num(price, 8)
            fee_asset = fill["fee_asset"]
            if (dec(fill["fee"]) > 0 and fee_asset not in (pair["base"], pair["quote"])
                    and "fee_usd" not in fill and not fill.get("fee_unpriced")):
                price = pricer.usd_price(fee_asset, fill["at_ms"])
                if price is None:
                    fill["fee_unpriced"] = True
                else:
                    fill["fee_usd"] = num(dec(fill["fee"]) * price, 8)


def replay_crypto(pairs, flows, wallet, coins):
    """Average cost per coin in USD. A buy adds what was paid (fees
    included); a sell or a trade paying with the coin removes cost at the
    running average and realizes the difference; a deposit adds its value at
    flow time and a withdrawal removes cost without a result. The wallet is
    authoritative for the quantity: a coin whose replayed quantity differs
    from it by more than 1% (Earn rewards, Convert, airdrops) is flagged
    `cost_approx`, and a coin with no replayed quantity has no basis."""
    events = []  # (at, order, coin, qty, usd or None, realizes)

    def add(at, coin, qty, usd, realizes=True):
        if coin in coins and qty != 0:
            events.append((at, 0 if qty > 0 else 1, coin, qty, usd, realizes))

    for pair in pairs.values():
        base, quote = pair["base"], pair["quote"]
        for f in pair["fills"]:
            qty, quote_qty, fee = dec(f["qty"]), dec(f["quote_qty"]), dec(f["fee"])
            px = dec(f["px"]) if "px" in f else None
            value = quote_qty * px if px is not None else None
            fee_value = dec(f["fee_usd"]) if "fee_usd" in f else Decimal(0)
            if f["fee_asset"] == quote and px is not None:
                fee_value = fee * px
            base_fee = fee if f["fee_asset"] == base else Decimal(0)
            quote_fee = fee if f["fee_asset"] == quote else Decimal(0)
            quote_fee_value = fee_value if quote_fee else Decimal(0)
            if f["buyer"]:
                add(f["at_ms"], base, qty - base_fee, None if value is None else value + fee_value)
                add(f["at_ms"], quote, -(quote_qty + quote_fee), None if value is None else value + quote_fee_value)
            else:
                add(f["at_ms"], base, -(qty + base_fee), None if value is None else value - fee_value)
                add(f["at_ms"], quote, quote_qty - quote_fee, None if value is None else value - quote_fee_value)
            if fee > 0 and f["fee_asset"] not in (base, quote):
                # A fee paid in a third coin (BNB) leaves that coin's book too.
                add(f["at_ms"], f["fee_asset"], -fee, dec(f["fee_usd"]) if "fee_usd" in f else None)
    for flow in flows:
        if flow.get("asset") in coins:
            amount = dec(flow.get("amount"))
            usd = dec(flow["usd"]) if "usd" in flow else None
            add(int(flow.get("at_ms") or 0), flow["asset"], amount if flow.get("dir") == "in" else -amount,
                usd, realizes=False)
    events.sort(key=lambda e: (e[0], e[1]))

    book = {c: {"qty": Decimal(0), "cost": Decimal(0), "realized": Decimal(0), "approx": False} for c in coins}
    for _, _, coin, qty, usd, realizes in events:
        p = book[coin]
        if qty > 0:
            if usd is None:
                p["approx"] = True  # held, at a cost nobody recorded
                continue
            p["qty"] += qty
            p["cost"] += usd
            continue
        out = -qty
        take = min(out, p["qty"])
        if take < out - DUST:
            p["approx"] = True  # more left than the history brought in
        if take <= 0:
            continue
        average = p["cost"] / p["qty"]
        if realizes and usd is not None:
            p["realized"] += usd * take / out - average * take
        p["cost"] -= average * take
        p["qty"] -= take

    costs = {}
    for coin, p in sorted(book.items()):
        held = wallet.get(coin, Decimal(0))
        if p["qty"] <= DUST or held <= DUST:
            continue
        average = max(p["cost"], Decimal(0)) / p["qty"]
        approx = p["approx"] or abs(held - p["qty"]) > held * COST_MISMATCH
        costs[coin] = {"avg_cost": num(average, 8), "cost": num(average * held, 8),
                       "realized_pnl": num(p["realized"], 8), "cost_approx": approx}
    return costs


def cmd_trades_sync(args):
    """Reads new spot fills for each held coin's pairs, a chunk at a time
    (done: false asks for the next), then writes crypto-costs.json."""
    data_dir = args.data_dir
    client = Binance(data_dir, *load_active_pair(DATA_KEYRING_TIMEOUT_S))
    balances = read_object(os.path.join(data_dir, "balances.json"))
    flows_file = read_object(os.path.join(data_dir, "flows.json")) or {}
    path = os.path.join(data_dir, "trades.json")
    stored = read_object(path) or {}
    pairs = stored.get("pairs") if isinstance(stored.get("pairs"), dict) else {}
    invalid = stored.get("invalid") if isinstance(stored.get("invalid"), dict) else {}
    at = now_ms()
    coins = held_coins(balances)
    budget = FlowBudget(client, {}, args.started)
    calls = 0

    def save():
        write_json_atomic(path, {"v": 1, "pairs": pairs, "invalid": invalid})

    # Each held coin against every quote, plus pairs with fills whose base is
    # gone: spending BTC on a coin since sold still moved BTC.
    symbols = {coin + quote: (coin, quote) for coin in coins for quote in TRADE_QUOTES if coin != quote}
    for symbol, pair in pairs.items():
        if pair.get("fills"):
            symbols.setdefault(symbol, (pair["base"], pair["quote"]))
    pending, wait_ms = False, 0
    try:
        for symbol, (coin, quote) in sorted(symbols.items()):
            if at - int(invalid.get(symbol) or 0) < TRADE_INVALID_TTL_MS:
                continue
            pair = pairs.setdefault(symbol, {"base": coin, "quote": quote, "next_id": 0, "fills": []})
            while at - int(pair.get("read_at") or 0) >= TRADE_REFRESH_MS:
                if int(client.weights.get("x-mbx-used-weight-1m") or 0) > TRADE_IP_WEIGHT_CAP:
                    pending, wait_ms = True, 60_000 - now_ms() % 60_000
                    break
                if calls >= TRADE_MAX_CALLS or budget.out_of_time():
                    pending = True
                    break
                calls += 1
                try:
                    rows = client.get("/api/v3/myTrades",
                                      {"symbol": symbol, "fromId": pair["next_id"], "limit": TRADE_PAGE})
                except HelperError as error:
                    if error.detail.get("binance_code") != -1121:  # invalid symbol
                        raise
                    invalid[symbol] = at
                    if not pair["fills"]:
                        pairs.pop(symbol)  # a delisted pair keeps the fills it had
                    break
                fills = [f for f in map(trade_fill, rows if isinstance(rows, list) else []) if f]
                pair["fills"].extend(fills)
                if fills:
                    pair["next_id"] = max(f["id"] for f in fills) + 1
                if len(rows or []) < TRADE_PAGE:
                    pair["read_at"] = at
            if pending:
                break
        priced = True
        try:
            price_fills(FlowPricer(budget), pairs)
        except OutOfLookups:
            priced = False
    finally:
        save()
    if pending or not priced:
        return {"ok": True, "done": False, "wait_ms": wait_ms}
    costs = replay_crypto(pairs, flows_file.get("flows") or [], wallet_quantities(balances), coins)
    # Synced once every source is read back to its floor; one Binance refuses
    # (not offered in the region) won't ever be, so it doesn't count.
    coverage = flows_file.get("coverage") or {}
    synced = bool(flows_file.get("complete")) or (bool(coverage) and all(
        c.get("complete") or "error" in c for c in coverage.values()))
    if not synced:
        for cost in costs.values():
            cost["cost_approx"] = True  # deposits or withdrawals may be missing
    write_json_atomic(os.path.join(data_dir, "crypto-costs.json"), {
        "v": 1, "at_ms": at, "flows_complete": bool(flows_file.get("complete")), "assets": costs})
    return {"ok": True, "done": True, "at_ms": at, "assets": len(costs),
            "fills": sum(len(p["fills"]) for p in pairs.values())}


# ── Probe ───────────────────────────────────────────────────────────────────

EQUITY_STATUSES = "FILLED,PARTIALLY_FILLED,CANCELED,EXPIRED"
WINDOW_CANDIDATES_DAYS = (365, 180, 90, 30, 7)
# String fields whose values are enums, safe to keep in the redacted shapes.
ENUM_FIELDS = {
    "walletName", "status", "side", "orderType", "convertType", "session", "quote",
}


def probe_call(client, record, name, path, params=None, signed=True):
    try:
        data = client.get(path, params, signed)
        record[name] = {"ok": True, "data": data}
        return data
    except HelperError as error:
        if error.code == "rate_limited":
            raise
        record[name] = {"ok": False, **error.payload()}
        return None


def probe_order_window(client, record):
    """Find the widest order/history window. Binance names the limit in the
    -1127 message ("More than %s hours"); fall back to a short descending list.
    Each window is one minute under its nominal hours."""
    end = now_ms()
    result = {"max_window_hours": None, "tried_hours": []}
    hours = 3650 * 24
    while hours:
        result["tried_hours"].append(hours)
        name = f"equity_order_history_{hours}h"
        params = {
            "startTime": end - hours * 3_600_000 + 60_000,
            "endTime": end,
            "orderStatus": EQUITY_STATUSES,
            "current": 1,
            "size": 100,
        }
        if probe_call(client, record, name, "/sapi/v1/equity/order/history", params) is not None:
            result["max_window_hours"] = hours
            return result
        error = record[name]
        if error.get("binance_code") != -1127:
            result["error"] = {k: error.get(k) for k in ("error", "binance_code", "msg")}
            return result
        match = re.search(r"more than (\d+) hours", error.get("msg") or "", re.I)
        stated = int(match.group(1)) if match else 0
        if 0 < stated < hours and "stated_hours" not in result:
            result["stated_hours"] = hours = stated
        else:
            hours = next((d * 24 for d in WINDOW_CANDIDATES_DAYS if d * 24 < hours), 0)
    return result


def probe_tokenized_history(client, record, pages=10):
    rows, last_id = [], None
    for page in range(pages):
        params = {"size": 100} | ({"lastId": last_id} if last_id is not None else {})
        data = probe_call(client, record, f"tokenized_history_p{page}", "/sapi/v1/equity/tokenized/history", params)
        if not isinstance(data, dict):
            return rows, False
        rows.extend(data.get("rows") or [])
        if not data.get("hasMore"):
            return rows, True
        last_id = data.get("nextLastId")
    return rows, False


def dec(value):
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return Decimal(0)


def token_balance_check(wallets, token_codes, convert_rows):
    """Per token code: does the wallet hold more than successful net mints?"""
    held = {}
    for wallet in wallets if isinstance(wallets, list) else []:
        for row in wallet.get("assetBalances") or []:
            asset = row.get("asset")
            if asset in token_codes:
                total = sum(dec(row.get(k, 0)) for k in ("free", "locked", "freeze", "withdrawing"))
                held[asset] = held.get(asset, Decimal(0)) + total
    minted = {}
    for row in convert_rows:
        if row.get("status") != "S":
            continue
        sign = {"MINT": 1, "REDEEM": -1}.get(row.get("convertType"), 0)
        asset = row.get("tokenizedAsset")
        minted[asset] = minted.get(asset, Decimal(0)) + sign * dec(row.get("tokenizedAssetAmount"))
    return {
        asset: {"exceeds_net_mints": qty > minted.get(asset, Decimal(0))}
        for asset, qty in held.items()
    }


def shape(value):
    """Keys, types, counts and enum values only: safe to share."""
    if isinstance(value, dict):
        return {k: enum_or_shape(k, v) for k, v in sorted(value.items())}
    if isinstance(value, list):
        out = {"type": "list", "count": len(value)}
        if value:
            out["item"] = merge_shapes([shape(v) for v in value])
        return out
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "float"
    if value is None:
        return "null"
    if isinstance(value, str):
        return "decimal-str" if re.fullmatch(r"-?\d+(\.\d+)?", value) else "str"
    return type(value).__name__


def enum_or_shape(key, value):
    if key in ENUM_FIELDS and isinstance(value, str):
        return {"enum": [value]}
    return shape(value)


def merge_shapes(shapes):
    merged = shapes[0]
    for other in shapes[1:]:
        merged = merge_two(merged, other)
    return merged


def shape_kind(s):
    if isinstance(s, str):
        return s
    if set(s) == {"enum"}:
        return "enum"
    if s.get("type") == "list" and "count" in s:
        return "list"
    return "object"


def union_members(s):
    """Flatten nullable/one_of into plain member shapes ("null" included)."""
    if isinstance(s, dict) and set(s) == {"nullable"}:
        return union_members(s["nullable"]) + ["null"]
    if isinstance(s, dict) and set(s) == {"one_of"}:
        return [m for member in s["one_of"] for m in union_members(member)]
    return [s]


def merge_two(a, b):
    """Merge two shapes structurally. A union keeps at most one member per
    kind (each primitive, enum, list, object), so the size is bounded by the
    schema, never by the row count."""
    if a == b:
        return a
    by_kind = {}
    for member in union_members(a) + union_members(b):
        kind = shape_kind(member)
        by_kind[kind] = merge_same_kind(by_kind[kind], member) if kind in by_kind else member
    nullable = by_kind.pop("null", None) is not None
    members = sorted(by_kind.values(), key=lambda m: json.dumps(m, sort_keys=True))
    if not members:
        return "null"
    merged = members[0] if len(members) == 1 else {"one_of": members}
    return {"nullable": merged} if nullable else merged


def merge_same_kind(a, b):
    if a == b or isinstance(a, str):
        return a
    if "enum" in a:
        return {"enum": sorted(set(a["enum"]) | set(b["enum"]))}
    if a.get("type") == "list" and "count" in a:
        out = {"type": "list", "count": a["count"] + b["count"]}
        items = [s["item"] for s in (a, b) if "item" in s]
        if items:
            out["item"] = merge_shapes(items)
        return out
    out = {}
    for key in sorted(set(a) | set(b)):
        fields = [s[key] for s in (a, b) if key in s]
        optional = len(fields) < 2 or any(is_optional(f) for f in fields)
        merged = merge_shapes([f["optional"] if is_optional(f) else f for f in fields])
        out[key] = {"optional": merged} if optional else merged
    return out


def is_optional(s):
    return isinstance(s, dict) and set(s) == {"optional"}


def redact_record(record):
    out = {}
    for name, entry in record.items():
        if entry.get("ok"):
            out[name] = {"ok": True, "shape": shape(entry["data"])}
        else:
            out[name] = {k: entry.get(k) for k in ("ok", "error", "status", "binance_code", "msg")}
    return out


def write_redacted(path, summary, record):
    write_json_atomic(path, {"summary": summary, "responses": redact_record(record)})


def cmd_redact(args):
    """Rebuild probe-redacted.json from an existing probe.json, offline."""
    full_path = os.path.join(args.data_dir, "probe.json")
    redacted_path = os.path.join(args.data_dir, "probe-redacted.json")
    try:
        probe = read_json(full_path)
        summary, record = probe["summary"], probe["responses"]
    except FileNotFoundError:
        raise HelperError("no_probe") from None
    except (OSError, ValueError, KeyError, TypeError):
        raise HelperError("bad_probe") from None
    write_redacted(redacted_path, summary, record)
    return {"ok": True, "redacted": redacted_path, "bytes": os.path.getsize(redacted_path)}


def cmd_probe(args):
    api_key, private_pem = load_active_pair()
    client = Binance(args.data_dir, api_key, private_pem)
    record = {}

    restrictions = check_permissions(client)
    record["api_restrictions"] = {"ok": True, "data": restrictions}
    wallets = probe_call(
        client, record, "wallet_balance", "/sapi/v1/asset/wallet/balance",
        {"needBalanceDetail": "true"},
    )
    assets = probe_call(
        client, record, "tokenized_assets", "/sapi/v1/equity/market/tokenized-assets",
        signed=False,
    )
    window = probe_order_window(client, record)
    convert_rows, convert_complete = probe_tokenized_history(client, record)

    token_codes = {a.get("assetCode") for a in assets or [] if isinstance(a, dict)}
    tokens = token_balance_check(wallets, token_codes, convert_rows)
    equity_calls = [v for k, v in record.items() if k.startswith(("equity_", "tokenized_history"))]
    equity_codes = {v.get("binance_code") for v in equity_calls if not v["ok"]} - {-1127}
    summary = {
        "wallet_names": sorted(
            w.get("walletName") for w in wallets or [] if isinstance(w, dict) and w.get("walletName")
        ),
        "wallets_with_detail": sum(
            1 for w in wallets or [] if isinstance(w, dict) and "assetBalances" in w
        ),
        "token_codes_known": len(token_codes - {None}),
        "token_wallet_counts": {
            w.get("walletName"): sum(1 for r in w.get("assetBalances") or [] if r.get("asset") in token_codes)
            for w in wallets or [] if isinstance(w, dict)
        },
        "tokens_held": len(tokens),
        "tokens_exceeding_net_mints": sum(1 for t in tokens.values() if t["exceeds_net_mints"]),
        "tokenized_history_complete": convert_complete,
        # None: no equity call succeeded, see equity_error_codes.
        "enable_reading_covers_equity": any(v["ok"] for v in equity_calls) or None,
        "equity_error_codes": sorted(c for c in equity_codes if c is not None),
        "order_history_window": window,
        "restriction_fields": sorted(restrictions),
        "used_weights": client.weights,
    }

    full_path = os.path.join(args.data_dir, "probe.json")
    redacted_path = os.path.join(args.data_dir, "probe-redacted.json")
    write_json_atomic(
        full_path, {"at_ms": now_ms(), "summary": summary, "tokens": tokens, "responses": record}
    )
    write_redacted(redacted_path, summary, record)
    return {
        "ok": True,
        "probe": full_path,
        "redacted": redacted_path,
        "enable_reading_covers_equity": summary["enable_reading_covers_equity"],
        "max_window_hours": window["max_window_hours"],
    }


# ── CSV export ──────────────────────────────────────────────────────────────
#
# The service builds the CSV (it holds every figure in the display currency)
# and stages it in the data dir with export-request.json. Noctalia's
# writeFile follows symlinks and creates files with the umask, so the copy
# into the downloads folder is made here: always a new 0600 file, never
# through an existing name or a dangling link.

EXPORT_REQUEST = "export-request.json"
EXPORT_STAGED = "export.csv"
EXPORT_DAY_RE = re.compile(r"\d{4}-\d{2}-\d{2}")
EXPORT_MAX_BYTES = 16 * 1024 * 1024


def export_names(day):
    yield f"binance-portfolio-{day}.csv"
    for n in range(2, 1000):
        yield f"binance-portfolio-{day}-{n}.csv"


def cmd_export_csv(args):
    data_dir = args.data_dir
    request_path = os.path.join(data_dir, EXPORT_REQUEST)
    request = read_object(request_path) or {}
    staged = os.path.join(data_dir, EXPORT_STAGED)
    try:
        dest, day = request.get("dir"), request.get("day")
        if not isinstance(dest, str) or not os.path.isabs(dest) or "\0" in dest:
            raise HelperError("write_failed", detail="the destination must be an absolute path")
        if not isinstance(day, str) or not EXPORT_DAY_RE.fullmatch(day):
            raise HelperError("write_failed", detail="bad day")
        fd = os.open(staged, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        with os.fdopen(fd, "rb") as f:
            content = f.read(EXPORT_MAX_BYTES + 1)
        if len(content) > EXPORT_MAX_BYTES:
            raise HelperError("write_failed", detail="the staged file is too large")
        os.makedirs(dest, exist_ok=True)
        for name in export_names(day):
            path = os.path.join(dest, name)
            try:
                # O_EXCL also refuses a dangling symlink at `path`.
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            except FileExistsError:
                continue
            try:
                with os.fdopen(fd, "wb") as f:
                    f.write(content)
            except OSError:
                os.unlink(path)
                raise
            return {"ok": True, "path": path, "name": name}
        raise HelperError("write_failed", detail="no free file name")
    except OSError as error:
        raise HelperError("write_failed", detail=f"{type(error).__name__}: {error.strerror}") from None
    finally:
        for path in (staged, request_path):
            if os.path.lexists(path):
                os.unlink(path)


# ── Entry ───────────────────────────────────────────────────────────────────

# name -> (handler, exclusive lock)
COMMANDS = {
    "keygen": (cmd_keygen, True),
    "store-api-key": (cmd_store_api_key, True),
    "verify": (cmd_verify, True),
    "recheck": (cmd_recheck, True),
    "disconnect": (cmd_disconnect, True),
    "balances": (cmd_balances, False),
    "stocks-sync": (cmd_stocks_sync, False),
    "flows-sync": (cmd_flows_sync, False),
    "deposits-recent": (cmd_deposits_recent, False),
    "stock-quotes": (cmd_stock_quotes, False),
    "trades-sync": (cmd_trades_sync, False),
    "export-csv": (cmd_export_csv, False),
    "probe": (cmd_probe, False),
    "redact": (cmd_redact, False),
}


def run(argv):
    # Time limits count from here, so a keyring unlock prompt eats into them
    # and the run still ends before the service's 30 s kill.
    started = time.monotonic()
    parser = argparse.ArgumentParser(prog="binance_helper.py")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in COMMANDS:
        sub.add_parser(name).add_argument("--data-dir", required=True)
    args = parser.parse_args(argv)
    args.started = started
    handler, exclusive = COMMANDS[args.command]
    try:
        prepare_data_dir(args.data_dir)
        with DataLock(args.data_dir, exclusive):
            if args.command in DATA_COMMANDS:
                check_gate(args.data_dir)
            if args.command not in ACCOUNT_COMMANDS:
                return handler(args)
            try:
                result = handler(args)
            except HelperError as error:
                record_account(args.data_dir, error=error)
                raise
            record_account(args.data_dir, verified_at=result.get("verified_at"),
                           keep_pending_error=args.command == "recheck")
            return result
    except HelperError as error:
        return error.payload()


def main():
    try:
        result = run(sys.argv[1:])
    except Exception as error:  # last resort: never a traceback with a URL in it
        result = {"error": "internal", "detail": scrub(f"{type(error).__name__}: {error}")}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
