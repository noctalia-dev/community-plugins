"""Tests for the Binance helper. No network, no real keyring or clipboard:
`secret-tool`, `wl-paste` and `wl-copy` are fakes on a temporary PATH, HOME
is a temporary directory, and HTTP is replaced at `http_get`."""

import base64
import fcntl
import json
import os
import stat
import sys
import tempfile
import textwrap
import unittest
import urllib.error
import urllib.parse
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

import binance_helper as helper

API_KEY = "4yNzx3yWC5bS6YTwEkSRaC0nRmSQIIStAUOh1b6kqaBrTLIhjCpI5lJH8q8R8WNO"
READ_ONLY = {
    "ipRestrict": False,
    "createTime": 1700000000000,
    "enableReading": True,
    "enableWithdrawals": False,
    "enableInternalTransfer": False,
    "enableMargin": False,
    "enableFutures": False,
    "permitsUniversalTransfer": False,
    "enableVanillaOptions": False,
    "enableFixApiTrade": False,
    "enableFixReadOnly": True,
    "enableSpotAndMarginTrading": False,
}

FAKE_SECRET_TOOL = """
import json, os, sys
path = os.environ["FAKE_KEYRING"]
mode = os.environ.get("FAKE_KEYRING_MODE", "")
items = json.load(open(path)) if os.path.exists(path) else []
op, args = sys.argv[1], [a for a in sys.argv[2:] if not a.startswith("--")]
attrs = dict(zip(args[::2], args[1::2]))
if mode == "noservice":
    sys.exit("secret-tool: The name org.freedesktop.secrets was not provided by any .service files")
locked = "secret-tool: Cannot create an item in a locked collection"
if mode == "locked":
    sys.exit(locked)
matches = [i for i in items if attrs.items() <= i["attrs"].items()]
if op == "lookup":
    # dismissed: the user closed the unlock prompt; libsecret exits 1, silent.
    if not matches or mode == "dismissed":
        sys.exit(1)
    sys.stdout.write(matches[0]["secret"])
elif op == "search":
    # Lists locked items too (no --unlock), without their secrets; some
    # libsecret builds print the details on stderr.
    out = sys.stderr if os.environ.get("FAKE_KEYRING_SEARCH_STDERR") else sys.stdout
    for i in matches:
        print("[/org/freedesktop/secrets/collection/login/1]", file=out)
        print("\\n".join(f"attribute.{k} = {v}" for k, v in i["attrs"].items()), file=out)
elif op == "store":
    if os.environ.get("FAKE_KEYRING_FAIL_STORE") == attrs["key"] + ":" + attrs["slot"]:
        sys.exit(locked)
    items = [i for i in items if i["attrs"] != attrs] + [{"attrs": attrs, "secret": sys.stdin.read()}]
elif op == "clear" and mode != "clear_noop":  # clear_noop: a locked collection
    items = [i for i in items if i not in matches]
json.dump(items, open(path, "w"))
"""

FAKE_WL_PASTE = """
import json, os, sys
path = os.environ["FAKE_CLIP"]
state = json.load(open(path))
which = "primary" if "--primary" in sys.argv else "clipboard"
value = state.get(which)
if value is None:
    sys.exit("Nothing is copied")
sys.stdout.write(value)
if which + "_next" in state:
    state[which] = state.pop(which + "_next")
    json.dump(state, open(path, "w"))
"""

FAKE_WL_COPY = """
import json, os, sys
path = os.environ["FAKE_CLIP"]
state = json.load(open(path))
assert "--clear" in sys.argv
state["primary" if "--primary" in sys.argv else "clipboard"] = None
json.dump(state, open(path, "w"))
"""


def pem_from_seed(seed_hex):
    serialization, ed25519 = helper.crypto()
    key = ed25519.Ed25519PrivateKey.from_private_bytes(bytes.fromhex(seed_hex))
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()


class FakeBinance:
    """Routes `http_get` by path. Handlers return (status, body[, headers])."""

    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def __call__(self, url, headers):
        parts = urllib.parse.urlsplit(url)
        query = dict(urllib.parse.parse_qsl(parts.query))
        self.calls.append((parts.path, query, headers))
        if parts.path == "/api/v3/time" and parts.path not in self.routes:
            return 200, {}, json.dumps({"serverTime": helper.now_ms()}).encode()
        result = self.routes[parts.path](query)
        status, body, response_headers = (*result, {})[:3]
        return status, response_headers, body if isinstance(body, bytes) else json.dumps(body).encode()

    def count(self, path):
        return sum(1 for p, _, _ in self.calls if p == path)


class HelperTestCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, source in (
            ("secret-tool", FAKE_SECRET_TOOL),
            ("wl-paste", FAKE_WL_PASTE),
            ("wl-copy", FAKE_WL_COPY),
        ):
            path = self.bin / name
            path.write_text(f"#!{sys.executable} -I\n" + textwrap.dedent(source))
            path.chmod(0o755)
        self.keyring = self.root / "keyring.json"
        self.clip = self.root / "clip.json"
        self.data_dir = self.root / "home" / "data"
        env = {
            "PATH": str(self.bin),
            "HOME": str(self.root / "home"),
            "FAKE_KEYRING": str(self.keyring),
            "FAKE_CLIP": str(self.clip),
        }
        env_patch = patch.dict(os.environ, env, clear=True)
        env_patch.start()
        self.addCleanup(env_patch.stop)

    def run_helper(self, command, http=None):
        def no_network(url, headers):
            raise AssertionError(f"unexpected network call: {url}")

        with patch.object(helper, "http_get", http or no_network):
            return helper.run([command, "--data-dir", str(self.data_dir)])

    def items(self):
        if not self.keyring.exists():
            return {}
        return {
            (i["attrs"]["key"], i["attrs"]["slot"]): i["secret"]
            for i in json.loads(self.keyring.read_text())
        }

    def seed_keyring(self, entries):
        self.keyring.write_text(json.dumps([
            {"attrs": {"service": "noctalia-binance", "key": k, "slot": s}, "secret": v}
            for (k, s), v in entries.items()
        ]))

    def set_clipboard(self, **state):
        self.clip.write_text(json.dumps(state))

    def clipboard(self):
        return json.loads(self.clip.read_text())


class SigningTests(unittest.TestCase):
    def test_payload_matches_documented_examples(self):
        common = [
            ("side", "SELL"), ("type", "LIMIT"), ("timeInForce", "GTC"),
            ("quantity", "1"), ("price", "0.2"),
            ("timestamp", 1668481559918), ("recvWindow", 5000),
        ]
        tail = "&side=SELL&type=LIMIT&timeInForce=GTC&quantity=1&price=0.2&timestamp=1668481559918&recvWindow=5000"
        self.assertEqual(
            helper.build_payload([("symbol", "BTCUSDT"), *common]), "symbol=BTCUSDT" + tail
        )
        self.assertEqual(
            helper.build_payload([("symbol", "１２３４５６"), *common]),
            "symbol=%EF%BC%91%EF%BC%92%EF%BC%93%EF%BC%94%EF%BC%95%EF%BC%96" + tail,
        )

    def test_signature_is_percent_encoded_in_query(self):
        # From the docs; an unencoded "+" would reach Binance as a space (-1022).
        signature = "HaZnek7KOGa/k5+f6Q1nw8lzMUpo36mRVvvLHCMUCXxlmdQQ=="
        with patch.object(helper, "sign", return_value=signature):
            query = helper.signed_query({"timestamp": 1}, "pem")
        self.assertEqual(
            query, "timestamp=1&signature=HaZnek7KOGa%2Fk5%2Bf6Q1nw8lzMUpo36mRVvvLHCMUCXxlmdQQ%3D%3D"
        )

    def test_rfc8032_vectors(self):
        vectors = [  # RFC 8032 §7.1 TEST 1 and TEST 2 (message 0x72 = "r")
            ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "",
             "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
            ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "r",
             "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
        ]
        for seed, message, expected in vectors:
            with self.subTest(message=message):
                signature = helper.sign(pem_from_seed(seed), message)
                self.assertEqual(base64.b64decode(signature).hex(), expected)

    def test_generated_public_key_verifies_signatures(self):
        serialization, _ = helper.crypto()
        private_pem, public_pem = helper.generate_keypair()
        payload = "recvWindow=5000&timestamp=1"
        public = serialization.load_pem_public_key(public_pem.encode())
        public.verify(base64.b64decode(helper.sign(private_pem, payload)), payload.encode())

    def test_missing_cryptography_is_reported(self):
        hidden = dict.fromkeys(
            ("cryptography", "cryptography.hazmat.primitives",
             "cryptography.hazmat.primitives.asymmetric"))
        with patch.dict(sys.modules, hidden):
            with self.assertRaises(helper.HelperError) as caught:
                helper.generate_keypair()
        self.assertEqual(
            caught.exception.payload(),
            {"error": "missing_dependency", "package": "python-cryptography"},
        )


class PermissionGateTests(unittest.TestCase):
    def test_read_only_key_passes(self):
        self.assertEqual(helper.permission_problems(READ_ONLY), [])

    def test_anything_beyond_reading_fails_closed(self):
        cases = {
            "known trading flag": ({"enableSpotAndMarginTrading": True}, ["enableSpotAndMarginTrading"]),
            "future enable flag": ({"enableStocksTrading": True}, ["enableStocksTrading"]),
            "future permits flag": ({"permitsGiftCards": True}, ["permitsGiftCards"]),
            "non-boolean flag": ({"enableWithdrawals": "true"}, ["enableWithdrawals"]),
            "reading off": ({"enableReading": False}, ["enableReading=false"]),
        }
        for label, (change, problems) in cases.items():
            with self.subTest(label):
                self.assertEqual(helper.permission_problems({**READ_ONLY, **change}), problems)
        without = {k: v for k, v in READ_ONLY.items() if k != "enableSpotAndMarginTrading"}
        self.assertEqual(helper.permission_problems(without), ["enableSpotAndMarginTrading missing"])


class KeyringTests(HelperTestCase):
    def test_keygen_stores_pending_key_and_drops_stale_api_key(self):
        self.seed_keyring({("api", "pending"): "stale", ("pair", "active"): "old-pair"})
        result = self.run_helper("keygen")
        self.assertTrue(result["ok"])
        items = self.items()
        self.assertNotIn(("api", "pending"), items)
        self.assertEqual(items[("pair", "active")], "old-pair")
        # The stored private key matches the public key the user uploads.
        serialization, _ = helper.crypto()
        public = serialization.load_pem_public_key(result["public_key_pem"].encode())
        payload = "timestamp=1"
        public.verify(
            base64.b64decode(helper.sign(items[("private", "pending")], payload)), payload.encode()
        )
        self.assertNotIn("PRIVATE", json.dumps(result))

    def test_keyring_failures_are_mapped(self):
        for mode, code in (("noservice", "no_secret_service"), ("locked", "keyring_locked")):
            with self.subTest(mode), patch.dict(os.environ, {"FAKE_KEYRING_MODE": mode}):
                self.assertEqual(self.run_helper("keygen")["error"], code)

    def test_a_dismissed_unlock_prompt_is_a_locked_keyring_not_a_missing_key(self):
        self.seed_keyring({("pair", "active"): json.dumps({"api_key": API_KEY, "private_key_pem": "pem"})})
        self.data_dir.mkdir(parents=True)
        (self.data_dir / "account.json").write_text(json.dumps({"v": 1, "active": True, "pending": "none"}))
        pair = self.keyring.read_text()
        for stream in ("stdout", "stderr"):
            env = {"FAKE_KEYRING_MODE": "dismissed", "FAKE_KEYRING_SEARCH_STDERR": "1" if stream == "stderr" else ""}
            with self.subTest(stream), patch.dict(os.environ, env):
                self.keyring.write_text(pair)
                self.assertEqual(self.run_helper("balances"), {"error": "keyring_locked"})
                self.assertEqual(self.run_helper("recheck"), {"error": "keyring_locked"})
                self.assertEqual(self.run_helper("verify"), {"error": "keyring_locked"})
                # The daily re-check must not flip the account to keyless.
                self.assertTrue(json.loads((self.data_dir / "account.json").read_text())["active"])
                self.seed_keyring({})
                self.assertEqual(self.run_helper("balances")["error"], "item_missing")

    def test_missing_secret_tool_is_reported(self):
        (self.bin / "secret-tool").unlink()
        self.assertEqual(
            self.run_helper("keygen"), {"error": "missing_dependency", "command": "secret-tool"}
        )

    def test_busy_when_another_helper_holds_the_lock(self):
        self.data_dir.mkdir(parents=True)
        with open(self.data_dir / "helper.lock", "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            with patch.object(helper, "LOCK_WAIT_S", 0.2):
                self.assertEqual(self.run_helper("keygen"), {"error": "busy"})
                self.assertEqual(self.run_helper("probe"), {"error": "busy"})
        self.assertEqual(self.items(), {})


class StoreApiKeyTests(HelperTestCase):
    def setUp(self):
        super().setUp()
        self.seed_keyring({("private", "pending"): "pem"})

    def test_saves_key_and_clears_selections_holding_it(self):
        self.set_clipboard(clipboard=API_KEY + "\n", primary=API_KEY + "\n")
        result = self.run_helper("store-api-key")
        self.assertEqual(result, {"ok": True, "cleared": {"clipboard": True, "primary": True}})
        self.assertEqual(self.items()[("api", "pending")], API_KEY)
        self.assertEqual(self.clipboard(), {"clipboard": None, "primary": None})
        self.assertNotIn(API_KEY, json.dumps(result))

    def test_leaves_selections_the_user_changed(self):
        self.set_clipboard(clipboard=API_KEY, clipboard_next="new copy", primary="other text")
        result = self.run_helper("store-api-key")
        self.assertEqual(result["cleared"], {"clipboard": False, "primary": False})
        self.assertEqual(self.clipboard(), {"clipboard": "new copy", "primary": "other text"})

    def test_rejects_malformed_key_without_storing_or_clearing(self):
        for content in (API_KEY[:-1], API_KEY + "x", "my password " + API_KEY, API_KEY[:-1] + "é"):
            with self.subTest(content=content[:8]):
                self.set_clipboard(clipboard=content, primary=None)
                self.assertEqual(self.run_helper("store-api-key"), {"error": "invalid_key_format"})
                self.assertNotIn(("api", "pending"), self.items())
                self.assertEqual(self.clipboard()["clipboard"], content)

    def test_requires_a_generated_key_first(self):
        self.seed_keyring({})
        self.set_clipboard(clipboard=API_KEY)
        self.assertEqual(self.run_helper("store-api-key"), {"error": "no_pending_key"})
        self.assertEqual(self.items(), {})


class VerifyTests(HelperTestCase):
    def setUp(self):
        super().setUp()
        self.new_pem = pem_from_seed("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
        self.old_pair = json.dumps({"api_key": "A" * 64, "private_key_pem": "old"})
        self.seed_keyring({
            ("private", "pending"): self.new_pem,
            ("api", "pending"): API_KEY,
            ("pair", "active"): self.old_pair,
        })

    def restrictions(self, body, status=200):
        return FakeBinance({"/sapi/v1/account/apiRestrictions": lambda q: (status, body)})

    def test_read_only_pending_pair_replaces_active(self):
        fake = self.restrictions(READ_ONLY)
        result = self.run_helper("verify", fake)
        self.assertEqual(result["slot"], "pending")
        self.assertTrue(result["promoted"])
        items = self.items()
        self.assertEqual(list(items), [("pair", "active")])
        active = json.loads(items[("pair", "active")])
        self.assertEqual(active["api_key"], API_KEY)
        self.assertEqual(active["private_key_pem"].strip(), self.new_pem.strip())
        path, query, headers = fake.calls[-1]
        self.assertEqual(headers, {"X-MBX-APIKEY": API_KEY})
        self.assertEqual(query["recvWindow"], "5000")

    def test_broad_key_is_refused_and_active_pair_kept(self):
        result = self.run_helper("verify", self.restrictions({**READ_ONLY, "enableWithdrawals": True}))
        self.assertEqual(result, {
            "error": "permissions_too_broad", "flags": ["enableWithdrawals"], "slot": "pending",
        })
        self.assertEqual(self.items()[("pair", "active")], self.old_pair)
        self.assertEqual(self.items()[("api", "pending")], API_KEY)

    def test_failed_promotion_keeps_old_active_pair_and_pending_keys(self):
        with patch.dict(os.environ, {"FAKE_KEYRING_FAIL_STORE": "pair:active"}):
            result = self.run_helper("verify", self.restrictions(READ_ONLY))
        self.assertEqual(result["error"], "keyring_locked")
        items = self.items()
        self.assertEqual(items[("pair", "active")], self.old_pair)
        self.assertEqual(items[("private", "pending")], self.new_pem)
        self.assertEqual(items[("api", "pending")], API_KEY)

    def test_rejected_key_reports_auth(self):
        result = self.run_helper("verify", self.restrictions(
            {"code": -2015, "msg": "Invalid API-key, IP, or permissions for action."}, status=401,
        ))
        self.assertEqual((result["error"], result["binance_code"]), ("auth_rejected", -2015))
        self.assertEqual(self.items()[("pair", "active")], self.old_pair)

    def test_without_pending_pair_the_active_pair_is_rechecked(self):
        self.seed_keyring({("pair", "active"): json.dumps(
            {"api_key": API_KEY, "private_key_pem": self.new_pem})})
        result = self.run_helper("verify", self.restrictions(READ_ONLY))
        self.assertEqual((result["slot"], result["promoted"]), ("active", False))

    def test_recheck_tests_the_active_pair_and_leaves_pending_alone(self):
        active = json.dumps({"api_key": "A" * 64, "private_key_pem": self.new_pem})
        self.seed_keyring({
            ("private", "pending"): self.new_pem,
            ("api", "pending"): API_KEY,
            ("pair", "active"): active,
        })
        fake = self.restrictions({**READ_ONLY, "enableSpotAndMarginTrading": True})
        result = self.run_helper("recheck", fake)
        self.assertEqual(result, {
            "error": "permissions_too_broad", "flags": ["enableSpotAndMarginTrading"], "slot": "active",
        })
        self.assertEqual(fake.calls[-1][2], {"X-MBX-APIKEY": "A" * 64})
        items = self.items()
        self.assertEqual(items[("pair", "active")], active)
        self.assertEqual(items[("api", "pending")], API_KEY)

    def test_recheck_ignores_an_abandoned_rotation(self):
        self.seed_keyring({
            ("private", "pending"): self.new_pem,
            ("pair", "active"): json.dumps({"api_key": API_KEY, "private_key_pem": self.new_pem}),
        })
        result = self.run_helper("recheck", self.restrictions(READ_ONLY))
        self.assertEqual((result["slot"], result["promoted"]), ("active", False))

    def test_clock_skew_resyncs_and_retries_once(self):
        responses = [(400, {"code": -1021, "msg": "Timestamp outside recvWindow."}), (200, READ_ONLY)]
        fake = FakeBinance({"/sapi/v1/account/apiRestrictions": lambda q: responses.pop(0)})
        self.assertTrue(self.run_helper("verify", fake)["ok"])
        self.assertEqual(fake.count("/api/v3/time"), 2)

    def test_persistent_clock_skew_is_reported(self):
        fake = FakeBinance({"/sapi/v1/account/apiRestrictions":
                            lambda q: (400, {"code": -1021, "msg": "Timestamp outside recvWindow."})})
        self.assertEqual(self.run_helper("verify", fake)["error"], "clock_skew")
        self.assertEqual(fake.count("/sapi/v1/account/apiRestrictions"), 2)

    def test_rate_limit_pause_survives_restart(self):
        fake = self.restrictions({"code": -1003, "msg": "Too many requests"}, status=429)
        fake.routes["/sapi/v1/account/apiRestrictions"] = lambda q: (429, {}, {"retry-after": "120"})
        first = self.run_helper("verify", fake)
        self.assertEqual(first["error"], "rate_limited")
        self.assertGreaterEqual(first["until_ms"], helper.now_ms() + 110_000)
        # A new process must not call Binance until the pause ends.
        second = self.run_helper("verify")
        self.assertEqual(second["error"], "rate_limited")

    def test_unreadable_pause_file_counts_as_paused(self):
        self.data_dir.mkdir(parents=True)
        (self.data_dir / "ratelimit-public.json").write_text('{"until_ms": ')
        self.assertEqual(self.run_helper("verify")["error"], "rate_limited")


class NetworkTests(unittest.TestCase):
    def test_errors_never_carry_query_or_signature(self):
        url = "https://api.binance.com/sapi/v1/x?timestamp=1&signature=abc%2Bdef"
        with patch.object(helper.OPENER, "open", side_effect=urllib.error.URLError(f"failed {url}")):
            with self.assertRaises(helper.HelperError) as caught:
                helper.http_get(url, {})
        detail = caught.exception.detail["detail"]
        self.assertNotIn("signature", detail)
        self.assertNotIn("timestamp", detail)

    def test_only_the_api_host_is_contacted(self):
        for url in ("https://evil.example/sapi", "http://api.binance.com/sapi",
                    "https://api.binance.com.evil.example/sapi"):
            with self.subTest(url), patch.object(helper.OPENER, "open") as opened:
                with self.assertRaises(helper.HelperError):
                    helper.http_get(url, {})
                opened.assert_not_called()


class ShapeTests(unittest.TestCase):
    def test_mixed_rows_merge_into_a_small_order_independent_shape(self):
        # Real failure: 57 order rows with a nullable price grew the redacted
        # file to gigabytes because unions nested stringified JSON.
        rows = [{
            "orderId": i,
            "status": ("FILLED", "CANCELED")[i % 2],
            "avgFilledPrice": None if i % 2 else "12.5",
            "note": ("x", None, {"a": 1})[i % 3],
            "detail": {"tag": "t"} if i % 4 == 0 else {"tag": "t", "fee": None if i % 2 else "0.1"},
        } for i in range(500)]
        expected_item = {
            "avgFilledPrice": {"nullable": "decimal-str"},
            "detail": {"fee": {"optional": {"nullable": "decimal-str"}}, "tag": "str"},
            "note": {"nullable": {"one_of": ["str", {"a": "int"}]}},
            "orderId": "int",
            "status": {"enum": ["CANCELED", "FILLED"]},
        }
        shaped = helper.shape(rows)
        self.assertEqual(shaped, {"type": "list", "count": 500, "item": expected_item})
        self.assertLess(len(json.dumps(shaped)), 600)
        self.assertEqual(helper.shape(rows[::-1])["item"], expected_item)
        self.assertEqual(helper.shape(rows[:57])["item"], expected_item)


def order(symbol, side, filled, total, fee, at, **extra):
    return {"orderId": f"{symbol}-{at}", "symbol": symbol, "side": side, "orderType": "LIMIT",
            "status": "FILLED", "filledQty": filled, "filledTotal": total, "fee": fee,
            "createdAt": at, "updatedAt": at + 5, **extra}


class ReplayTests(unittest.TestCase):
    def test_average_cost_includes_fees_and_sells_realize_at_the_running_average(self):
        orders = [
            # Listed out of order: the replay must sort by time.
            order("AAA", "SELL", "3", "360", "1.5", 4),
            order("AAA", "BUY", "2", "200", "1", 1, orderType="MARKET", avgFilledPrice="100"),
            # Partial fill of a 10-share limit order, then canceled; no avgFilledPrice.
            order("AAA", "BUY", "4", "440", "2", 2, status="CANCELED", qty="10"),
            order("AAA", "BUY", "0", "0", "0", 3, status="CANCELED"),
            order("BBB", "BUY", "1", "50", "0", 5),
            order("BBB", "SELL", "1", "60", "0", 6),
        ]
        positions, closed = helper.replay_stocks(orders, [], {})
        # Cost 201 + 442 = 643 for 6 shares; selling 3 removes 321.5 and
        # realizes 360 - 1.5 - 321.5 = 37.
        self.assertEqual(positions, [{
            "symbol": "AAA", "qty": "3", "avg_cost": "107.16666667", "cost": "321.5",
            "cost_known": True, "cost_approx": False, "tokenized_shares": "0", "realized_pnl": "37",
            "fees": "4.5", "orders": 3,
        }])
        self.assertEqual(closed, [{"symbol": "BBB", "realized_pnl": "10", "fees": "0", "orders": 2}])

    def test_tokenized_shares_are_counted_once(self):
        orders = [order("NVDA", "BUY", "5", "500", "0", 1)]
        conversions = [
            {"underlyingAsset": "NVDA", "underlyingAssetAmount": "2", "convertType": "MINT",
             "status": "S", "updatedAt": 10},
            # Still processing: must not move shares yet.
            {"underlyingAsset": "NVDA", "underlyingAssetAmount": "3", "convertType": "MINT",
             "status": "P", "updatedAt": 11},
        ]
        tokens = {"NVDA": Decimal("2"), "TSLA": Decimal("1")}
        positions, _ = helper.replay_stocks(orders, conversions, tokens)
        by_symbol = {p["symbol"]: p for p in positions}
        self.assertEqual(
            (by_symbol["NVDA"]["qty"], by_symbol["NVDA"]["tokenized_shares"], by_symbol["NVDA"]["avg_cost"]),
            ("5", "2", "100"),
        )
        # Tokens bought on the market, never minted: held, but no cost basis.
        self.assertEqual((by_symbol["TSLA"]["qty"], by_symbol["TSLA"]["cost_known"]), ("1", False))


    def test_wallet_share_count_wins_and_flags_the_cost_basis(self):
        orders = [order("NVDA", "BUY", "4", "400", "0", 1), order("AMD", "BUY", "2", "100", "0", 2)]
        # The wallet holds 8 NVDA (a 2:1 split the orders never saw), the
        # replayed 2 AMD, and GOOG shares with no order history at all.
        equities = {"NVDA": Decimal("8"), "AMD": Decimal("2"), "GOOG": Decimal("1")}
        positions, _ = helper.replay_stocks(orders, [], {}, equities)
        by_symbol = {p["symbol"]: p for p in positions}
        nvda = by_symbol["NVDA"]
        self.assertEqual((nvda["qty"], nvda["avg_cost"], nvda["cost"], nvda["cost_approx"]),
                         ("8", "100", "800", True))
        self.assertEqual((by_symbol["AMD"]["qty"], by_symbol["AMD"]["cost_approx"]), ("2", False))
        self.assertEqual((by_symbol["GOOG"]["qty"], by_symbol["GOOG"]["cost_known"]), ("1", False))

    def test_tokens_leaving_or_entering_outside_orders_keep_the_order_average(self):
        orders = [order("NVDA", "BUY", "10", "1000", "0", 1)]
        mint = {"underlyingAsset": "NVDA", "underlyingAssetAmount": "5", "convertType": "MINT",
                "status": "S", "updatedAt": 2}
        # 5 shares minted, then the tokens sold on Spot: 5 shares left.
        positions, _ = helper.replay_stocks(orders, [mint], {}, {"NVDA": Decimal("5")})
        p = positions[0]
        self.assertEqual((p["qty"], p["avg_cost"], p["cost"], p["cost_approx"]), ("5", "100", "500", False))
        # 5 tokens bought on Spot next to 10 bought shares: no known basis for them.
        positions, _ = helper.replay_stocks(orders, [], {"NVDA": Decimal("5")}, {"NVDA": Decimal("10")})
        p = positions[0]
        self.assertEqual((p["qty"], p["avg_cost"], p["cost_approx"]), ("15", "100", True))

    def test_orders_without_filled_total_use_the_average_price_or_drop_the_basis(self):
        priced = order("AAA", "BUY", "2", None, "1", 1, avgFilledPrice="100")
        bare = order("BBB", "BUY", "2", None, "1", 1)
        positions, _ = helper.replay_stocks([priced, bare], [], {})
        by_symbol = {p["symbol"]: p for p in positions}
        self.assertEqual((by_symbol["AAA"]["avg_cost"], by_symbol["AAA"]["cost_known"]), ("100.5", True))
        self.assertFalse(by_symbol["BBB"]["cost_known"])

    def test_a_sell_without_a_total_has_no_realized_result(self):
        orders = [order("AAA", "BUY", "10", "1000", "0", 1), order("AAA", "SELL", "4", None, "0", 2),
                  order("BBB", "BUY", "2", None, "0", 1), order("BBB", "SELL", "2", "300", "0", 2)]
        positions, closed = helper.replay_stocks(orders, [], {})
        self.assertNotIn("realized_pnl", positions[0])
        self.assertNotIn("realized_pnl", closed[0])

    def test_shares_sold_outside_the_order_history_close_the_position(self):
        orders = [order("NVDA", "BUY", "4", "400", "0", 1)]
        positions, closed = helper.replay_stocks(orders, [], {}, {})
        self.assertEqual((positions, [c["symbol"] for c in closed]), ([], ["NVDA"]))


class DataTests(HelperTestCase):
    DAY = 86_400_000
    T0 = 1_792_411_200_000  # 2026-10-19 12:00 UTC

    def setUp(self):
        super().setUp()
        pem = pem_from_seed("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        self.seed_keyring({("pair", "active"): json.dumps({"api_key": API_KEY, "private_key_pem": pem})})
        self.now = self.T0
        clock = patch.object(helper, "now_ms", lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)
        self.wallets = [
            {"activate": True, "balance": "0.01", "walletName": "Spot", "assetBalances": [
                {"asset": "BTC", "assetName": "Bitcoin", "free": "0.01", "locked": "0", "btcValuation": "0.01"},
                {"asset": "ETH", "free": "0", "locked": "0"}]},
            {"activate": True, "balance": "0.02", "walletName": "Funding", "assetBalances": [
                {"asset": "BTC", "free": "0.005", "locked": "0.001", "freeze": "0", "withdrawing": "0"},
                {"asset": "NVDAB", "free": "4", "locked": "0"},
                # Untokenized shares bought in the Stocks app.
                {"asset": "EQ_NVDA", "assetName": "EQ_NVDA", "free": "3", "locked": "0", "btcValuation": "0.003"}]},
        ]
        self.orders = [order("NVDA", "BUY", "3", "300", "0.3", self.T0 - self.DAY)]
        self.quote = {"symbol": "NVDA", "bidPrice": "110", "askPrice": "112"}
        self.fake = FakeBinance({
            "/sapi/v1/asset/wallet/balance": lambda q: (200, self.wallets),
            "/sapi/v1/equity/market/tokenized-assets": lambda q: (200, [
                {"assetCode": "NVDAB", "underlyingEquitySymbol": "NVDA", "multiplier": "0.5"}]),
            "/sapi/v1/equity/order/history": self.order_pages,
            "/sapi/v1/equity/tokenized/history": lambda q: (200, {"rows": [], "hasMore": False}),
            "/sapi/v1/equity/market/quote": lambda q: (200, self.quote),
            "/sapi/v1/equity/market/exchangeInfo": lambda q: (200, {"symbols": [{"symbol": "NVDA"}]}),
        })

    def order_pages(self, query):
        page = int(query["current"])
        rows = self.orders[(page - 1) * 100:page * 100]
        return 200, {"total": len(self.orders), "page": page, "size": 100, "rows": rows}

    def read(self, name):
        return json.loads((self.data_dir / name).read_text())

    def test_balances_keep_stocks_and_stock_tokens_out_of_crypto(self):
        result = self.run_helper("balances", self.fake)
        self.assertEqual((result["ok"], result["assets"], result["tokenized_held"]), (True, 1, 1))
        balances = self.read("balances.json")
        funding = balances["wallets"][1]
        self.assertEqual([a["asset"] for a in funding["assets"]], ["BTC"])
        self.assertEqual(funding["assets"][0]["total"], "0.006")
        self.assertEqual(balances["wallets"][0]["assets"][0]["total"], "0.01")  # zero ETH row dropped
        self.assertEqual(balances["tokenized"], [{
            "asset": "NVDAB", "symbol": "NVDA", "multiplier": "0.5", "wallet": "Funding",
            "qty": "4", "shares": "2"}])
        self.assertEqual(balances["equities"], [
            {"asset": "EQ_NVDA", "symbol": "NVDA", "wallet": "Funding", "qty": "3"}])
        ledger = self.read("ledger.json")
        self.assertEqual(ledger["days"]["2026-10-19"], {"crypto": {"BTC": "0.016"}})

    def test_stocks_sync_values_positions_and_feeds_the_ledger(self):
        self.run_helper("balances", self.fake)
        result = self.run_helper("stocks-sync", self.fake)
        self.assertEqual((result["done"], result["positions"], result["quotes_ok"]), (True, 1, 1))
        position = self.read("stocks.json")["positions"][0]
        # 3 bought + 2 shares held as NVDAB tokens (4 tokens x 0.5).
        self.assertEqual((position["qty"], position["tokenized_shares"]), ("5", "2"))
        self.assertEqual(position["quote"]["mid"], "111")
        self.assertEqual(self.read("marks.json")["marks"]["NVDA"]["2026-10-19"]["mid"], "111")

        # Next day: only balances run, yet the row keeps yesterday's shares.
        self.now += self.DAY
        self.run_helper("balances", self.fake)
        days = self.read("ledger.json")["days"]
        self.assertEqual(days["2026-10-20"], {"crypto": {"BTC": "0.016"}, "stocks": {"NVDA": "5"}})
        self.assertEqual(self.read("ledger.json")["first_day"], "2026-10-19")

    def test_missing_quote_keeps_last_mid_marked_stale(self):
        self.run_helper("stocks-sync", self.fake)
        self.now += 60_000
        self.quote = b""  # what the quote endpoint returns for a halted ticker
        result = self.run_helper("stocks-sync", self.fake)
        self.assertEqual((result["quotes_ok"], result["quotes_stale"]), (0, 1))
        quote = self.read("stocks.json")["positions"][0]["quote"]
        self.assertEqual((quote["mid"], quote["stale"], quote["at_ms"]), ("111", True, self.T0))

    def test_stocks_sync_pages_resume_across_runs(self):
        self.orders = [order("AAA", "BUY", "1", "10", "0", self.T0 - i) for i in range(850)]
        first = self.run_helper("stocks-sync", self.fake)
        self.assertEqual((first["done"], first["pages"]), (False, 8))
        self.assertIn("stocks", self.read("cursors.json"))
        self.now += 60_000
        second = self.run_helper("stocks-sync", self.fake)
        self.assertTrue(second["done"], second)
        pages = [(q["current"], q["endTime"]) for p, q, _ in self.fake.calls if p.endswith("order/history")]
        # Pages 1-9 once each, all against the window fixed by the first run.
        self.assertEqual([c for c, _ in pages], [str(i) for i in range(1, 10)])
        self.assertEqual({e for _, e in pages}, {str(self.T0)})
        self.assertEqual(self.read("stocks.json")["positions"][0]["qty"], "850")
        self.assertNotIn("stocks", self.read("cursors.json"))
        self.assertFalse((self.data_dir / "stock-orders.json.partial").exists())


    def test_a_slow_network_saves_pages_and_the_next_run_resumes(self):
        self.orders = [order("AAA", "BUY", "1", "10", "0", self.T0 - i) for i in range(250)]
        clock = iter(range(0, 1000, 7))  # each monotonic read 7 s later
        with patch.object(helper.time, "monotonic", lambda: next(clock)):
            first = self.run_helper("stocks-sync", self.fake)
        self.assertFalse(first["done"])
        self.assertTrue((self.data_dir / "stock-orders.json.partial").exists())
        self.assertTrue(self.run_helper("stocks-sync", self.fake)["done"])
        self.assertEqual(self.read("stocks.json")["positions"][0]["qty"], "250")

    def test_a_slow_keyring_unlock_counts_against_the_time_limit(self):
        self.orders = [order("AAA", "BUY", "1", "10", "0", self.T0)]
        assert_waited_on_keyring(self, "stocks-sync", "order/history")

    def test_stock_quotes_cover_watched_listed_tickers_with_the_key(self):
        (self.data_dir).mkdir(parents=True, exist_ok=True)
        (self.data_dir / "prefs.json").write_text(json.dumps({"v": 1, "watchlist": ["BTCUSDT", "EQ_NVDA", "EQ_ZZZZ"],
            "alerts": [{"id": "a1", "symbol": "EQ_AAPL", "kind": "above", "value": 1, "enabled": False}]}))
        self.fake.routes["/sapi/v1/equity/market/exchangeInfo"] = lambda q: (200, {"timezone": "UTC", "symbols": [
            {"symbol": "NVDA", "overnightSupported": True}, {"symbol": "AAPL", "overnightSupported": False}]})
        result = self.run_helper("stock-quotes", self.fake)
        self.assertEqual((result["quotes"], result["unknown"]), (1, 1), result)
        quotes = self.read("stock-quotes.json")
        self.assertEqual(quotes["unknown"], ["ZZZZ"])
        self.assertEqual(quotes["quotes"]["NVDA"]["mid"], "111")
        # Only listed, watched tickers are quoted, each with the API key.
        asked = [(q["symbol"], h.get("X-MBX-APIKEY")) for p, q, h in self.fake.calls if p.endswith("market/quote")]
        self.assertEqual(asked, [("NVDA", API_KEY)])
        self.assertEqual(self.read("equity-symbols.json")["symbols"]["NVDA"], {"overnight": True, "extended": True})

    def test_stocks_sync_refreshes_the_listing_for_held_stocks_daily(self):
        # Catches: held stocks showing CLOSED overnight when no stock is
        # watched, because only stock-quotes fetched the listing.
        self.fake.routes["/sapi/v1/equity/market/exchangeInfo"] = lambda q: (200, {"symbols": [
            {"symbol": "NVDA", "overnightSupported": True, "extendedSession": False}]})
        self.run_helper("balances", self.fake)
        self.assertTrue(self.run_helper("stocks-sync", self.fake)["done"])
        self.assertEqual(self.read("equity-symbols.json")["symbols"]["NVDA"], {"overnight": True, "extended": False})
        self.now += 60_000
        self.run_helper("stocks-sync", self.fake)
        self.assertEqual(self.fake.count("/sapi/v1/equity/market/exchangeInfo"), 1)

    def test_stock_quote_day_change_is_against_an_earlier_days_last_quote(self):
        (self.data_dir).mkdir(parents=True, exist_ok=True)
        (self.data_dir / "prefs.json").write_text(json.dumps({"v": 1, "watchlist": ["EQ_NVDA"]}))
        self.fake.routes["/sapi/v1/equity/market/exchangeInfo"] = lambda q: (200, {"symbols": [{"symbol": "NVDA"}]})
        self.run_helper("stock-quotes", self.fake)  # mid 111 on day 1
        self.now += self.DAY
        self.quote = {"bidPrice": "120", "askPrice": "122"}
        self.run_helper("stock-quotes", self.fake)
        self.now += 60_000
        self.quote = {"bidPrice": "130", "askPrice": "132"}
        self.run_helper("stock-quotes", self.fake)
        quote = self.read("stock-quotes.json")["quotes"]["NVDA"]
        # A later run the same day keeps the previous day's base.
        self.assertEqual((quote["mid"], quote["prev_mid"], quote["prev_day"]), ("131", "111", "2026-10-19"))
        self.assertEqual(self.fake.count("/sapi/v1/equity/market/exchangeInfo"), 2)  # once a day


def assert_waited_on_keyring(case, command, endpoint):
    """Runs `command` with the keyring unlock taking 16 s: past both time
    limits, so no history request may start (it could outlive the kill)."""
    clock = [0]
    load = helper.load_active_pair

    def slow_unlock(*args):
        clock[0] += 16
        return load(*args)

    with patch.object(helper.time, "monotonic", lambda: clock[0]), \
            patch.object(helper, "load_active_pair", slow_unlock):
        result = case.run_helper(command, case.fake)
    case.assertFalse(result["done"], result)
    case.assertFalse([p for p, _, _ in case.fake.calls if p.endswith(endpoint)])


class FlowTests(HelperTestCase):
    """flows-sync against a fake Binance that enforces each endpoint's
    documented window, lookback and UID weight limits."""

    DAY = 86_400_000
    T0 = 1_792_411_200_000  # 2026-10-19 12:00 UTC
    UID = {"/sapi/v1/capital/withdraw/history": 18_000, "/sapi/v1/fiat/orders": 45_000,
           "/sapi/v1/pay/transactions": 3_000}
    MAX_WINDOW_DAYS = {"/sapi/v1/capital/deposit/hisrec": 90, "/sapi/v1/capital/withdraw/history": 90,
                       "/sapi/v1/c2c/orderMatch/listUserOrderHistory": 30, "/sapi/v1/pay/transactions": 90,
                       # Fiat: undocumented; the helper must discover it.
                       "/sapi/v1/fiat/orders": 100, "/sapi/v1/fiat/payments": 100}
    LOOKBACK_DAYS = {"/sapi/v1/c2c/orderMatch/listUserOrderHistory": 183, "/sapi/v1/pay/transactions": 548}

    def setUp(self):
        super().setUp()
        pem = pem_from_seed("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        self.seed_keyring({("pair", "active"): json.dumps({"api_key": API_KEY, "private_key_pem": pem})})
        self.now = self.T0
        clock = patch.object(helper, "now_ms", lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)
        t = self.T0
        self.deposits = [
            {"id": "d1", "coin": "BTC", "amount": "0.1", "status": 1, "insertTime": t - 400 * self.DAY},
            {"id": "d2", "coin": "USDT", "amount": "100", "status": 1, "insertTime": t - 10 * self.DAY},
            {"id": "d3", "coin": "USDT", "amount": "70", "status": 0, "insertTime": t - 2 * self.DAY},
        ]
        self.withdrawals = [
            {"id": "w1", "coin": "USDT", "amount": "50", "transactionFee": "1", "status": 6,
             "applyTime": "2026-10-14 12:00:00"},
            {"id": "w2", "coin": "USDT", "amount": "9", "status": 3, "applyTime": "2026-10-15 12:00:00"},
        ]
        self.fiat = {"0": [
            {"orderNo": "f1", "fiatCurrency": "EUR", "indicatedAmount": "200", "amount": "198",
             "totalFee": "2", "status": "Successful", "createTime": t - 30 * self.DAY},
            {"orderNo": "f2", "fiatCurrency": "EUR", "indicatedAmount": "500", "amount": "500",
             "status": "Failed", "createTime": t - 29 * self.DAY}], "1": []}
        self.cards = [
            {"orderNo": "c1", "sourceAmount": "30", "fiatCurrency": "EUR", "status": "Completed",
             "paymentMethod": "Credit Card", "createTime": t - 40 * self.DAY},
            # Paid from the fiat balance, already counted as a fiat deposit.
            {"orderNo": "c2", "sourceAmount": "40", "fiatCurrency": "EUR", "status": "Completed",
             "paymentMethod": "Cash Balance", "createTime": t - 41 * self.DAY},
        ]
        self.p2p = [{"orderNumber": "p1", "tradeType": "BUY", "asset": "USDT", "fiat": "EUR",
                     "amount": "108", "totalPrice": "100", "orderStatus": "COMPLETED",
                     "createTime": t - 20 * self.DAY}]
        self.pay = [
            {"transactionId": "y1", "amount": "-5", "currency": "USDT", "transactionTime": t - 3 * self.DAY},
            {"transactionId": "y2", "amount": "2", "currency": "BNB", "transactionTime": t - 4 * self.DAY},
        ]
        self.closes = {"BTCUSDT": "50000", "EURUSDT": "1.1", "BNBUSDT": "600"}
        self.uid_log = []  # (now, path, weight)
        self.broken = {}
        self.fake = FakeBinance({
            "/sapi/v1/capital/deposit/hisrec": self.list_route(
                "/sapi/v1/capital/deposit/hisrec", lambda: self.deposits, "insertTime"),
            "/sapi/v1/capital/withdraw/history": self.list_route(
                "/sapi/v1/capital/withdraw/history", lambda: self.withdrawals,
                lambda r: helper.withdraw_time(r)),
            "/sapi/v1/fiat/orders": self.wrapped_route(
                "/sapi/v1/fiat/orders", lambda q: self.fiat[q["transactionType"]], "createTime"),
            "/sapi/v1/fiat/payments": self.wrapped_route(
                "/sapi/v1/fiat/payments", lambda q: self.cards if q["transactionType"] == "0" else [], "createTime"),
            "/sapi/v1/c2c/orderMatch/listUserOrderHistory": self.wrapped_route(
                "/sapi/v1/c2c/orderMatch/listUserOrderHistory", lambda q: self.p2p, "createTime",
                keys=("startTimestamp", "endTimestamp")),
            "/sapi/v1/pay/transactions": self.wrapped_route(
                "/sapi/v1/pay/transactions", lambda q: self.pay, "transactionTime"),
            "/api/v3/klines": self.klines,
        })

    def test_a_slow_keyring_unlock_counts_against_the_time_limit(self):
        assert_waited_on_keyring(self, "flows-sync", "/hisrec")

    def check_window(self, path, start, end):
        start, end = int(start), int(end)
        self.assertLess(start, end)
        self.assertLessEqual(end, self.now)
        self.assertGreaterEqual(start, helper.FLOWS_FLOOR_MS)
        if path in self.LOOKBACK_DAYS:
            self.assertGreaterEqual(start, self.now - self.LOOKBACK_DAYS[path] * self.DAY, path)
        if path in self.UID:
            self.uid_log.append((self.now, path, self.UID[path]))
        if end - start > self.MAX_WINDOW_DAYS[path] * self.DAY:
            return 400, {"code": -1127, "msg": "More than 100 days between startTime and endTime."}
        if self.broken.get(path):
            return self.broken[path]
        return None

    def list_route(self, path, rows, time_key):
        at = time_key if callable(time_key) else (lambda r: r[time_key])

        def route(q):
            error = self.check_window(path, q["startTime"], q["endTime"])
            if error:
                return error
            hits = [r for r in rows() if int(q["startTime"]) <= at(r) <= int(q["endTime"])]
            offset, limit = int(q["offset"]), int(q["limit"])
            return 200, hits[offset:offset + limit]
        return route

    def wrapped_route(self, path, rows, time_key, keys=("beginTime", "endTime")):
        def route(q):
            if path == "/sapi/v1/pay/transactions":
                keys_used = ("startTime", "endTime")
            elif path == "/sapi/v1/c2c/orderMatch/listUserOrderHistory":
                keys_used = keys
            else:
                keys_used = ("beginTime", "endTime")
            start, end = q[keys_used[0]], q[keys_used[1]]
            error = self.check_window(path, start, end)
            if error:
                return error
            hits = [r for r in rows(q) if int(start) <= r[time_key] <= int(end)]
            if path == "/sapi/v1/pay/transactions":
                return 200, {"code": "000000", "message": "success", "data": hits[:int(q["limit"])], "success": True}
            page, size = int(q["page"]), int(q["rows"])
            return 200, {"code": "000000", "message": "success", "success": True,
                         "data": hits[(page - 1) * size:page * size], "total": len(hits)}
        return route

    def klines(self, q):
        if q["symbol"] not in self.closes:
            return 400, {"code": -1121, "msg": "Invalid symbol."}
        start = int(q["startTime"])
        self.assertEqual(start % 3_600_000, 0)
        return 200, [[start, "1", "1", "1", self.closes[q["symbol"]], "0", start + 3_599_999]]

    def sync_until_done(self, limit=200):
        results = []
        for _ in range(limit):
            result = self.run_helper("flows-sync", self.fake)
            results.append(result)
            if result.get("done") is not False:
                return results
            self.now += max(result["wait_ms"], 1000)
        raise AssertionError(f"flows-sync never finished: {results[-1]}")

    def read(self, name):
        return json.loads((self.data_dir / name).read_text())

    def flows(self):
        return {f["id"]: f for f in self.read("flows.json")["flows"]}

    def test_completed_flows_are_kept_and_valued_at_flow_time(self):
        results = self.sync_until_done()
        self.assertTrue(results[-1]["ok"], results[-1])
        flows = self.flows()
        self.assertEqual(sorted(flows), ["card_buy:c1", "deposit:d1", "deposit:d2", "fiat_deposit:f1",
                                         "p2p:p1", "pay:y1", "pay:y2", "withdraw:w1"])
        view = {k: (f["dir"], f["asset"], f["amount"], f.get("usd"), f.get("eurusd")) for k, f in flows.items()}
        self.assertEqual(view["deposit:d1"], ("in", "BTC", "0.1", "5000", "1.1"))
        # Euro amounts stay exact: usd is amount x the flow-time EURUSDT.
        self.assertEqual(view["fiat_deposit:f1"], ("in", "EUR", "200", "220", "1.1"))
        self.assertEqual(view["p2p:p1"], ("in", "EUR", "100", "110", "1.1"))
        # Withdrawals count what arrived; the fee stays a cost.
        self.assertEqual(view["withdraw:w1"], ("out", "USDT", "50", "50", "1.1"))
        self.assertEqual(view["pay:y1"], ("out", "USDT", "5", "5", "1.1"))
        self.assertEqual(view["pay:y2"], ("in", "BNB", "2", "1200", "1.1"))
        self.assertEqual(flows["withdraw:w1"]["at_ms"], self.T0 - 5 * self.DAY)

        stored = self.read("flows.json")
        self.assertTrue(stored["complete"])
        self.assertEqual(stored["since_day"], "2025-09-14")
        self.assertEqual(stored["coverage"]["deposit"]["from_day"], "2017-07-01")
        self.assertEqual(stored["coverage"]["p2p"]["from_day"], "2026-04-22")
        # The first flow predates P2P's 6 months but not Pay's 18.
        self.assertEqual(stored["uncovered"], ["p2p_older_than_6_months", "gifts_and_rewards"])

    def test_requests_stay_inside_window_lookback_and_uid_limits(self):
        results = self.sync_until_done()
        self.assertTrue(all(r.get("ok") for r in results), results[-1])
        # check_window asserted every window; now the per-minute UID weight
        # per endpoint, across invocations.
        for path in self.UID:
            times = [t for t, p, _ in self.uid_log if p == path]
            for start in times:
                used = sum(self.UID[path] for t in times if start <= t < start + 60_000)
                self.assertLessEqual(used, 180_000, path)
        # A chunk never makes more than 8 UID-weighted calls.
        per_chunk = {}
        for t, p, _ in self.uid_log:
            per_chunk[t] = per_chunk.get(t, 0) + 1
        self.assertLessEqual(max(per_chunk.values()), helper.FLOW_MAX_UID_CALLS)
        # Fiat orders rejected 365-day windows; the helper settled on 91 days.
        fiat = [q for p, q, _ in self.fake.calls if p == "/sapi/v1/fiat/orders"]
        self.assertEqual(int(fiat[-1]["endTime"]) - int(fiat[-1]["beginTime"]) <= 100 * self.DAY, True)
        self.assertTrue(self.read("flows.json")["coverage"]["fiat_deposit"]["complete"])

    def test_an_interrupted_sync_resumes_without_rereading_windows(self):
        self.broken["/sapi/v1/capital/withdraw/history"] = (429, {"code": -1003, "msg": "Too many requests."})
        first = self.run_helper("flows-sync", self.fake)
        self.assertEqual(first["error"], "rate_limited")
        self.broken.clear()
        self.now += 600_001
        self.sync_until_done()
        deposit_windows = [(q["startTime"], q["endTime"], q["offset"]) for p, q, _ in self.fake.calls
                           if p == "/sapi/v1/capital/deposit/hisrec"]
        backward = [w for w in deposit_windows if int(w[1]) <= self.T0]
        self.assertEqual(len(backward), len(set(backward)))
        self.assertIn("deposit:d2", self.flows())

    def test_later_runs_catch_up_and_never_revalue(self):
        self.sync_until_done()
        valued = len([c for c in self.fake.calls if c[0] == "/api/v3/klines"])
        self.now += self.DAY
        self.deposits[2]["status"] = 1  # the pending deposit completed
        self.deposits.append({"id": "d4", "coin": "BTC", "amount": "0.2", "status": 1,
                              "insertTime": self.now - 3_600_000})
        result = self.sync_until_done()[-1]
        self.assertEqual((result["done"], result["flows"]), (True, 10))
        new_klines = [c[1]["symbol"] for c in self.fake.calls if c[0] == "/api/v3/klines"][valued:]
        # d3 (USDT) only needs EURUSDT; d4 needs BTCUSDT and EURUSDT.
        self.assertEqual(sorted(new_klines), ["BTCUSDT", "EURUSDT", "EURUSDT"])
        self.assertEqual(self.flows()["deposit:d4"]["usd"], "10000")

    def test_a_failing_source_is_named_and_does_not_block_the_rest(self):
        self.broken["/sapi/v1/fiat/payments"] = (400, {"code": -1000, "msg": "Service unavailable in your region."})
        result = self.sync_until_done()[-1]
        self.assertTrue(result["done"], result)
        stored = self.read("flows.json")
        self.assertEqual(stored["coverage"]["card_buy"]["error"], "api_error")
        self.assertFalse(stored["complete"])
        self.assertIn("card_buy_unavailable", stored["uncovered"])

    def test_recent_deposits_are_read_alone_between_full_syncs(self):
        self.assertTrue(self.run_helper("deposits-recent", self.fake)["skipped"])  # nothing backfilled yet
        self.assertEqual(self.fake.calls, [])
        self.broken["/sapi/v1/fiat/payments"] = (400, {"code": -1000, "msg": "Service unavailable in your region."})
        self.sync_until_done()
        before = len(self.fake.calls)
        self.now += 3_600_000
        self.deposits.append({"id": "d4", "coin": "BTC", "amount": "0.2", "status": 1,
                              "insertTime": self.now - 60_000})
        result = self.run_helper("deposits-recent", self.fake)
        self.assertTrue(result["done"], result)
        paths = {c[0] for c in self.fake.calls[before:]}
        self.assertEqual(paths - {"/api/v3/klines", "/api/v3/time"}, {"/sapi/v1/capital/deposit/hisrec"})
        self.assertEqual(self.flows()["deposit:d4"]["usd"], "10000")
        # A source that failed this run stays named until the next full sync.
        stored = self.read("flows.json")
        self.assertIn("card_buy_unavailable", stored["uncovered"])
        self.assertFalse(stored["complete"])

    def test_assets_without_a_price_are_marked_not_guessed(self):
        self.pay.append({"transactionId": "y3", "amount": "7", "currency": "NOPE", "transactionTime": self.T0 - self.DAY})
        self.sync_until_done()
        flow = self.flows()["pay:y3"]
        self.assertEqual((flow.get("unpriced"), "usd" in flow), (True, False))


    def test_a_pair_binance_rejects_is_marked_unpriced_instead_of_stalling(self):
        self.pay.append({"transactionId": "y3", "amount": "7", "currency": "ODD", "transactionTime": self.T0 - self.DAY})
        self.pay.append({"transactionId": "y4", "amount": "3", "currency": "FLAKY", "transactionTime": self.T0 - self.DAY})
        self.pay.append({"transactionId": "y5", "amount": "2", "currency": "GEO", "transactionTime": self.T0 - 2 * self.DAY})
        rejected = {"ODDUSDT": (400, {"code": -1100, "msg": "Illegal characters found in parameter 'symbol'."}),
                    "FLAKYUSDT": (503, {"code": -1001, "msg": "Internal error."}),
                    "GEOUSDT": (451, {"code": 0, "msg": "Service unavailable from a restricted location."})}
        self.fake.routes["/api/v3/klines"] = lambda q: rejected.get(q["symbol"]) or self.klines(q)
        self.sync_until_done()
        flows = self.flows()
        # Server-side and location errors are transient: the flows wait for a later run.
        self.assertNotIn("unpriced", flows["pay:y5"])
        self.assertNotIn("unpriced", flows["pay:y4"])
        del rejected["FLAKYUSDT"], rejected["GEOUSDT"]
        self.sync_until_done()
        flows = self.flows()
        self.assertEqual((flows["pay:y3"].get("unpriced"), "usd" in flows["pay:y3"]), (True, False))
        self.assertTrue(flows["pay:y4"].get("unpriced"))

class DailyFlowTests(unittest.TestCase):
    def test_flows_sum_per_utc_day_with_what_could_not_be_valued(self):
        day = 1_792_368_000_000  # 2026-10-19 00:00 UTC
        flows = [
            {"dir": "in", "at_ms": day + 1, "usd": "110", "eurusd": "1.1"},
            {"dir": "out", "at_ms": day + 2, "usd": "11", "eurusd": "1.1"},
            {"dir": "in", "at_ms": day + 3, "usd": "50", "no_eurusd": True},  # before EURUSDT listed
            {"dir": "in", "at_ms": day + 86_400_000, "unpriced": True},
            # Lookups ran out this chunk: waiting, not unpriceable.
            {"dir": "in", "at_ms": day + 86_400_001},
            {"dir": "in", "at_ms": day + 86_400_002, "usd": "20"},
        ]
        self.assertEqual(helper.daily_flows(flows), [
            {"day": "2026-10-19", "in_usd": "160", "out_usd": "11", "in_eur": "100", "out_eur": "10",
             "valued": 3, "no_usd": 0, "no_eur": 1, "no_eur_usd": "50", "awaiting": 0},
            {"day": "2026-10-20", "in_usd": "20", "out_usd": "0", "in_eur": "0", "out_eur": "0",
             "valued": 1, "no_usd": 1, "no_eur": 1, "no_eur_usd": "0", "awaiting": 2},
        ])


def fill(fill_id, at, qty, quote_qty, buyer, fee="0", fee_asset="", px="1"):
    row = {"id": fill_id, "at_ms": at, "qty": qty, "quote_qty": quote_qty, "buyer": buyer,
           "fee": fee, "fee_asset": fee_asset}
    return {**row, "px": px} if px is not None else row


class CryptoCostTests(unittest.TestCase):
    def test_buys_and_deposits_set_the_average_and_sells_realize_against_it(self):
        pairs = {"BTCUSDT": {"base": "BTC", "quote": "USDT", "fills": [
            fill(1, 1, "1", "50000", True, fee="50", fee_asset="USDT"),
            fill(2, 3, "0.5", "40000", False),
        ]}}
        # A deposit worth 69,950 when it arrived: 2 BTC for 120,000.
        flows = [{"asset": "BTC", "dir": "in", "amount": "1", "usd": "69950", "at_ms": 2}]
        costs = helper.replay_crypto(pairs, flows, {"BTC": Decimal("1.5")}, {"BTC"})
        self.assertEqual(costs["BTC"], {"avg_cost": "60000", "cost": "90000", "realized_pnl": "10000",
                                        "cost_approx": False})

    def test_paying_with_a_coin_disposes_of_it_at_its_average(self):
        pairs = {
            "BTCUSDT": {"base": "BTC", "quote": "USDT", "fills": [fill(1, 1, "1", "40000", True)]},
            # 10 ETH for 0.5 BTC when BTC was worth 60,000.
            "ETHBTC": {"base": "ETH", "quote": "BTC", "fills": [fill(1, 2, "10", "0.5", True, px="60000")]},
        }
        costs = helper.replay_crypto(pairs, [], {"BTC": Decimal("0.5"), "ETH": Decimal("10")}, {"BTC", "ETH"})
        self.assertEqual(costs["ETH"]["avg_cost"], "3000")
        self.assertEqual((costs["BTC"]["avg_cost"], costs["BTC"]["realized_pnl"]), ("40000", "10000"))

    def test_a_fee_paid_in_bnb_costs_the_buy_and_leaves_the_bnb_book(self):
        pairs = {
            "BNBUSDT": {"base": "BNB", "quote": "USDT", "fills": [fill(1, 1, "10", "6000", True)]},
            "ETHUSDT": {"base": "ETH", "quote": "USDT", "fills": [
                {**fill(1, 2, "1", "1000", True, fee="0.1", fee_asset="BNB"), "fee_usd": "60"}]},
        }
        costs = helper.replay_crypto(pairs, [], {"BNB": Decimal("9.9"), "ETH": Decimal("1")}, {"BNB", "ETH"})
        self.assertEqual(costs["ETH"]["avg_cost"], "1060")
        self.assertEqual((costs["BNB"]["avg_cost"], costs["BNB"]["cost_approx"]), ("600", False))

    def test_a_wallet_the_history_does_not_explain_flags_or_drops_the_basis(self):
        pairs = {"SOLUSDT": {"base": "SOL", "quote": "USDT", "fills": [fill(1, 1, "10", "1000", True)]}}
        wallet = {"SOL": Decimal("10.5"), "DOGE": Decimal("100")}  # Earn rewards; DOGE from an airdrop
        costs = helper.replay_crypto(pairs, [], wallet, {"SOL", "DOGE"})
        self.assertEqual((costs["SOL"]["avg_cost"], costs["SOL"]["cost"], costs["SOL"]["cost_approx"]),
                         ("100", "1050", True))
        self.assertNotIn("DOGE", costs)

    def test_a_deposit_without_a_price_makes_the_basis_approximate(self):
        pairs = {"SOLUSDT": {"base": "SOL", "quote": "USDT", "fills": [fill(1, 1, "10", "1000", True)]}}
        flows = [{"asset": "SOL", "dir": "in", "amount": "0.05", "unpriced": True, "at_ms": 2}]
        costs = helper.replay_crypto(pairs, flows, {"SOL": Decimal("10.05")}, {"SOL"})
        self.assertTrue(costs["SOL"]["cost_approx"])


class TradesSyncTests(HelperTestCase):
    T0 = 1_792_411_200_000

    def setUp(self):
        super().setUp()
        pem = pem_from_seed("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        self.seed_keyring({("pair", "active"): json.dumps({"api_key": API_KEY, "private_key_pem": pem})})
        self.now = self.T0
        clock = patch.object(helper, "now_ms", lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)
        self.data_dir.mkdir(parents=True)
        (self.data_dir / "balances.json").write_text(json.dumps({"v": 1, "wallets": [{"name": "Spot", "assets": [
            {"asset": "BTC", "total": "0.5"}, {"asset": "USDT", "total": "100"}]}]}))
        (self.data_dir / "flows.json").write_text(json.dumps({"v": 1, "complete": True, "flows": []}))
        self.fake = FakeBinance({"/api/v3/myTrades": self.my_trades})

    def my_trades(self, query):
        if query["symbol"] != "BTCUSDT":
            return 400, {"code": -1121, "msg": "Invalid symbol."}
        rows = [{"id": 7, "time": self.T0 - 1000, "qty": "0.5", "quoteQty": "30000", "isBuyer": True,
                 "commission": "0", "commissionAsset": "BTC"}]
        return 200, [r for r in rows if r["id"] >= int(query["fromId"])]

    def test_fills_become_a_cost_basis_and_pairs_that_do_not_exist_are_skipped_after(self):
        result = self.run_helper("trades-sync", self.fake)
        self.assertEqual((result["done"], result["assets"]), (True, 1), result)
        costs = json.loads((self.data_dir / "crypto-costs.json").read_text())["assets"]
        self.assertEqual((costs["BTC"]["avg_cost"], costs["BTC"]["cost_approx"]), ("60000", False))
        first = self.fake.count("/api/v3/myTrades")
        self.assertEqual(first, len(helper.TRADE_QUOTES) - 1)  # every quote but BTC itself; USDT is cash
        # An hour later only the pair that exists is read again, from the next id.
        self.now += 3_600_000
        self.run_helper("trades-sync", self.fake)
        calls = [q for p, q, _ in self.fake.calls if p == "/api/v3/myTrades"][first:]
        self.assertEqual([(q["symbol"], q["fromId"]) for q in calls], [("BTCUSDT", "8")])
        costs = json.loads((self.data_dir / "crypto-costs.json").read_text())["assets"]
        self.assertEqual(costs["BTC"]["cost"], "30000")


class ExportTests(HelperTestCase):
    def setUp(self):
        super().setUp()
        self.data_dir.mkdir(parents=True)
        self.downloads = self.root / "home" / "Downloads"
        self.downloads.mkdir()

    def stage(self, text="kind,asset\ncrypto,BTC\n", **request):
        staged = self.data_dir / "export.csv"
        staged.write_text(text)
        (self.data_dir / "export-request.json").write_text(json.dumps(
            {"v": 1, "dir": str(self.downloads), "day": "2026-10-19"} | request))

    def test_export_creates_a_private_file_beside_earlier_ones(self):
        (self.downloads / "binance-portfolio-2026-10-19.csv").write_text("older export")
        self.stage()
        result = self.run_helper("export-csv")
        target = self.downloads / "binance-portfolio-2026-10-19-2.csv"
        self.assertEqual(result, {"ok": True, "path": str(target), "name": target.name})
        self.assertEqual(target.read_text(), "kind,asset\ncrypto,BTC\n")
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertEqual((self.downloads / "binance-portfolio-2026-10-19.csv").read_text(), "older export")
        self.assertEqual(sorted(p.name for p in self.data_dir.iterdir() if p.name.startswith("export")), [])

    def test_export_never_writes_through_a_dangling_symlink(self):
        # Catches: writing through a planted link to wherever it points.
        elsewhere = self.root / "elsewhere.csv"
        (self.downloads / "binance-portfolio-2026-10-19.csv").symlink_to(elsewhere)
        self.stage()
        result = self.run_helper("export-csv")
        self.assertEqual(result["name"], "binance-portfolio-2026-10-19-2.csv")
        self.assertFalse(elsewhere.exists())

    def test_export_refuses_a_relative_folder(self):
        self.stage(dir="Downloads")
        self.assertEqual(self.run_helper("export-csv")["error"], "write_failed")
        self.assertEqual(list(self.downloads.iterdir()), [])

    def test_export_only_ever_reads_and_removes_its_own_staged_file(self):
        # Catches: a request naming another data file (the ledger) gets it
        # copied to Downloads and then deleted.
        ledger = self.data_dir / "ledger.json"
        ledger.write_text("{}")
        self.stage(staged=str(ledger))
        result = self.run_helper("export-csv")
        self.assertEqual((self.downloads / result["name"]).read_text(), "kind,asset\ncrypto,BTC\n")
        self.assertTrue(ledger.exists())


class AccountFileTests(HelperTestCase):
    def setUp(self):
        super().setUp()
        self.fake = FakeBinance({"/sapi/v1/account/apiRestrictions": lambda q: (200, READ_ONLY)})

    def account(self):
        return json.loads((self.data_dir / "account.json").read_text())

    def test_connect_steps_are_mirrored_without_secrets(self):
        public_pem = self.run_helper("keygen")["public_key_pem"]
        self.assertEqual(self.account(), {"v": 1, "active": False, "pending": "private",
                                          "public_key_pem": public_pem})
        self.set_clipboard(clipboard=API_KEY, primary=None)
        self.run_helper("store-api-key")
        self.assertEqual(self.account()["pending"], "both")
        result = self.run_helper("verify", self.fake)
        self.assertEqual(self.account(), {"v": 1, "active": True, "pending": "none",
                                          "verified_at_ms": result["verified_at"]})
        text = (self.data_dir / "account.json").read_text()
        self.assertNotIn(API_KEY, text)
        self.assertNotIn("PRIVATE", text)

    def test_failed_verify_is_recorded_and_cleared_by_the_next_success(self):
        pem = pem_from_seed("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        self.seed_keyring({("pair", "active"): json.dumps({"api_key": API_KEY, "private_key_pem": pem})})
        verified_at = self.run_helper("verify", self.fake)["verified_at"]
        self.fake.routes["/sapi/v1/account/apiRestrictions"] = lambda q: (
            200, {**READ_ONLY, "enableWithdrawals": True})
        self.run_helper("verify", self.fake)
        account = self.account()
        self.assertEqual(account["last_error"]["code"], "permissions_too_broad")
        self.assertEqual(account["last_error"]["flags"], ["enableWithdrawals"])
        self.assertEqual((account["active"], account["verified_at_ms"]), (True, verified_at))
        self.fake.routes["/sapi/v1/account/apiRestrictions"] = lambda q: (200, READ_ONLY)
        self.run_helper("verify", self.fake)
        self.assertNotIn("last_error", self.account())

    def test_a_passing_recheck_keeps_the_pending_keys_error(self):
        pem = pem_from_seed("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        self.seed_keyring({
            ("pair", "active"): json.dumps({"api_key": "A" * 64, "private_key_pem": pem}),
            ("private", "pending"): pem,
            ("api", "pending"): API_KEY,
        })
        self.fake.routes["/sapi/v1/account/apiRestrictions"] = lambda q: (
            200, {**READ_ONLY, "enableWithdrawals": True})
        self.run_helper("verify", self.fake)
        self.fake.routes["/sapi/v1/account/apiRestrictions"] = lambda q: (200, READ_ONLY)
        self.assertTrue(self.run_helper("recheck", self.fake)["ok"])
        error = self.account()["last_error"]
        self.assertEqual((error["flags"], error["slot"]), (["enableWithdrawals"], "pending"))

    def test_a_key_failing_the_daily_gate_is_not_used_until_it_passes(self):
        pem = pem_from_seed("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        self.seed_keyring({("pair", "active"): json.dumps({"api_key": API_KEY, "private_key_pem": pem})})
        self.fake.routes["/sapi/v1/account/apiRestrictions"] = lambda q: (
            200, {**READ_ONLY, "enableSpotAndMarginTrading": True})
        self.run_helper("verify", self.fake)
        refused = {"error": "permissions_too_broad", "flags": ["enableSpotAndMarginTrading"], "slot": "active"}
        for command in ("balances", "stocks-sync", "flows-sync", "deposits-recent"):
            with self.subTest(command):
                self.assertEqual(self.run_helper(command), refused)  # no network call made
        # Starting a key rotation does not lift it; only a passing verify does.
        self.run_helper("keygen")
        self.assertEqual(self.run_helper("balances"), refused)
        self.seed_keyring({("pair", "active"): json.dumps({"api_key": API_KEY, "private_key_pem": pem})})
        self.fake.routes["/sapi/v1/account/apiRestrictions"] = lambda q: (200, READ_ONLY)
        self.run_helper("verify", self.fake)
        self.assertNotIn("gate_failed", self.account())


class ProbeTests(HelperTestCase):
    def setUp(self):
        super().setUp()
        pem = pem_from_seed("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        self.seed_keyring({("pair", "active"): json.dumps({"api_key": API_KEY, "private_key_pem": pem})})

    def fake(self, max_hours=2160):
        def orders(query):
            span_hours = (int(query["endTime"]) - int(query["startTime"])) / 3_600_000
            if span_hours > max_hours:
                return 400, {"code": -1127, "msg": f"More than {max_hours} hours between startTime and endTime."}
            return 200, {"total": 1, "page": 1, "size": 100, "rows": [{
                "orderId": "987654321", "symbol": "NVDA", "side": "BUY", "orderType": "MARKET",
                "avgFilledPrice": "123.45", "filledQty": "1.5", "fee": "0.17", "status": "FILLED",
                "createdAt": 1760000000000, "limitPrice": None,
            }]}

        wallets = [
            {"activate": True, "balance": "0.0042", "walletName": "Spot", "assetBalances": [
                {"asset": "BTC", "free": "0.0042", "locked": "0", "btcValuation": "0.0042"}]},
            {"activate": True, "balance": "0.01", "walletName": "Funding", "assetBalances": [
                {"asset": "NVDAB", "free": "2", "locked": "0", "freeze": "0", "withdrawing": "0"},
                {"asset": "AAPLB", "free": "1", "locked": "0"}]},
        ]
        convert = {"rows": [
            {"tokenizedAsset": "NVDAB", "tokenizedAssetAmount": "1", "convertType": "MINT",
             "status": "S", "issuerRequestId": "req-1"},
            {"tokenizedAsset": "AAPLB", "tokenizedAssetAmount": "5", "convertType": "MINT",
             "status": "S", "issuerRequestId": "req-2"},
            {"tokenizedAsset": "NVDAB", "tokenizedAssetAmount": "9", "convertType": "MINT",
             "status": "P", "issuerRequestId": "req-3"},
        ], "hasMore": False}
        return FakeBinance({
            "/sapi/v1/account/apiRestrictions": lambda q: (200, READ_ONLY),
            "/sapi/v1/asset/wallet/balance": lambda q: (200, wallets),
            "/sapi/v1/equity/market/tokenized-assets": lambda q: (200, [
                {"assetCode": "NVDAB", "underlyingEquitySymbol": "NVDA", "multiplier": "1"},
                {"assetCode": "AAPLB", "underlyingEquitySymbol": "AAPL", "multiplier": "1"}]),
            "/sapi/v1/equity/order/history": orders,
            "/sapi/v1/equity/tokenized/history": lambda q: (200, convert),
        })

    def test_probe_records_shapes_and_writes_private_files(self):
        self.data_dir.mkdir(parents=True, mode=0o755)
        fake = self.fake()
        status = self.run_helper("probe", fake)
        self.assertTrue(status["ok"], status)
        self.assertEqual(status["max_window_hours"], 2160)
        self.assertTrue(status["enable_reading_covers_equity"])
        # Stated limit used directly: one too-wide call, then one at the limit.
        self.assertEqual(fake.count("/sapi/v1/equity/order/history"), 2)
        # Market-data endpoint gets the API key but no signature.
        _, query, headers = next(c for c in fake.calls if c[0].endswith("tokenized-assets"))
        self.assertEqual((query, headers), ({}, {"X-MBX-APIKEY": API_KEY}))

        self.assertEqual(stat.S_IMODE(self.data_dir.stat().st_mode), 0o700)
        for name in ("probe.json", "probe-redacted.json"):
            self.assertEqual(stat.S_IMODE((self.data_dir / name).stat().st_mode), 0o600)

        redacted_text = (self.data_dir / "probe-redacted.json").read_text()
        for private in ("987654321", "123.45", "0.0042", "NVDA", "AAPL", "BTC", "req-1", API_KEY):
            self.assertNotIn(private, redacted_text)
        redacted = json.loads(redacted_text)
        summary = redacted["summary"]
        self.assertEqual(summary["wallet_names"], ["Funding", "Spot"])
        # NVDAB: 2 held, 1 minted (pending row ignored). AAPLB: 1 held, 5 minted.
        self.assertEqual((summary["tokens_held"], summary["tokens_exceeding_net_mints"]), (2, 1))
        row = redacted["responses"]["equity_order_history_2160h"]["shape"]["rows"]["item"]
        self.assertEqual(row["status"], {"enum": ["FILLED"]})
        self.assertEqual(row["filledQty"], "decimal-str")
        self.assertEqual(row["limitPrice"], "null")

    def test_redact_rebuilds_the_shared_file_offline(self):
        self.assertTrue(self.run_helper("probe", self.fake())["ok"])
        redacted = self.data_dir / "probe-redacted.json"
        expected = redacted.read_text()
        redacted.unlink()
        # run_helper without a fake fails on any network call.
        result = self.run_helper("redact")
        self.assertTrue(result["ok"], result)
        self.assertEqual(redacted.read_text(), expected)
        self.assertEqual(stat.S_IMODE(redacted.stat().st_mode), 0o600)

    def test_probe_refuses_a_key_that_is_not_read_only(self):
        fake = self.fake()
        fake.routes["/sapi/v1/account/apiRestrictions"] = lambda q: (
            200, {**READ_ONLY, "enableSpotAndMarginTrading": True})
        result = self.run_helper("probe", fake)
        self.assertEqual(result["error"], "permissions_too_broad")
        self.assertEqual(fake.count("/sapi/v1/asset/wallet/balance"), 0)

    def test_disconnect_clears_keys_and_cache(self):
        self.assertTrue(self.run_helper("probe", self.fake())["ok"])
        self.seed_keyring({**{k: "x" for k in self.items()}, ("private", "pending"): "pem"})
        (self.data_dir / ".tmp-abc").write_text("{}")  # left by a killed helper
        with patch.dict(os.environ, {"FAKE_KEYRING_MODE": "clear_noop"}):
            self.assertEqual(self.run_helper("disconnect"), {"error": "keyring_locked"})
        self.assertTrue((self.data_dir / "probe.json").exists())  # nothing deleted yet
        result = self.run_helper("disconnect")
        self.assertEqual(self.items(), {})
        self.assertIn("probe.json", result["removed"])
        self.assertFalse((self.data_dir / "probe-redacted.json").exists())
        self.assertFalse((self.data_dir / ".tmp-abc").exists())


if __name__ == "__main__":
    unittest.main()
