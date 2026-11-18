"""Integration tests for the daemon: run with `python3 -m unittest discover -s tests`.

Starts two real daemon instances on loopback (ports 53340-53343) and drives them
through the control API and the LocalSend HTTPS API.
"""
import hashlib
import http.client
import json
import os
import ssl
import subprocess
import sys
import tempfile
import time
import unittest

DAEMON = os.path.join(os.path.dirname(__file__), "..", "daemon", "localsendd.py")
TOKENS = {}  # control port -> secret read from the daemon's data dir


def ctl(port, method, path, body=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request(method, path, json.dumps(body) if body is not None else None,
              {"X-LocalSend-Token": TOKENS.get(port, ""), "Content-Type": "application/json"})
    r = c.getresponse()
    data = r.read()
    c.close()
    return r.status, json.loads(data or b"{}")


def https(port, method, path, body=None, headers=None):
    ctx = ssl.create_default_context()
    ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    c = http.client.HTTPSConnection("127.0.0.1", port, timeout=10, context=ctx)
    c.request(method, path, body, headers or {})
    r = c.getresponse()
    data = r.read()
    c.close()
    return r.status, data


def wait_for(fn, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.1)
    raise AssertionError("timed out")


class DaemonTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        t = cls.tmp.name
        cls.procs = []
        for name, port, cport, extra in (("A", 53340, 53341, []),
                                         ("B", 53342, 53343, ["--auto-accept"])):
            cls.procs.append(subprocess.Popen(
                [sys.executable, DAEMON, "--data-dir", f"{t}/{name}/data", "--save-dir",
                 f"{t}/{name}/in", "--alias", name, "--port", str(port),
                 "--control-port", str(cport)] + extra,
                stderr=subprocess.DEVNULL))
        for name, cport in (("A", 53341), ("B", 53343)):
            tok = f"{t}/{name}/data/control.token"
            wait_for(lambda: os.path.exists(tok) and os.path.getsize(tok) > 0)
            TOKENS[cport] = open(tok).read()
        wait_for(lambda: all(cls._up(p) for p in (53341, 53343)))
        cls.fp_b = ctl(53343, "GET", "/state")[1]["self"]["fingerprint"]
        # Multicast needs fixed ports, so introduce B to A the way a LAN peer would.
        https(53340, "POST", "/api/localsend/v2/register",
              json.dumps({"alias": "B", "fingerprint": cls.fp_b, "port": 53342, "protocol": "https"}))
        cls.in_b = f"{t}/B/in"

    @staticmethod
    def _up(port):
        try:
            return ctl(port, "GET", "/state")[0] == 200
        except OSError:
            return False

    @classmethod
    def tearDownClass(cls):
        for port in (53341, 53343):
            try:
                ctl(port, "POST", "/quit", {})
            except OSError:
                pass
        for p in cls.procs:
            p.wait(timeout=10)
        cls.tmp.cleanup()

    def send(self, **kw):
        status, resp = ctl(53341, "POST", "/send", {"fingerprint": self.fp_b} | kw)
        self.assertEqual(status, 200, resp)
        sid = resp["session"]

        def finished():
            s = next(x for x in ctl(53341, "GET", "/state")[1]["sessions"] if x["id"] == sid)
            return s if s["status"] in ("done", "failed", "rejected") else None
        return wait_for(finished)

    def raw_ctl(self, headers):
        c = http.client.HTTPConnection("127.0.0.1", 53341)
        c.request("GET", "/state", headers=headers)
        status = c.getresponse().status
        c.close()
        return status

    def test_control_requires_private_token(self):
        self.assertEqual(self.raw_ctl({}), 403)
        self.assertEqual(self.raw_ctl({"X-LocalSend-Ctl": "1"}), 403)  # the old public constant
        self.assertEqual(self.raw_ctl({"X-LocalSend-Token": "wrong"}), 403)
        self.assertEqual(self.raw_ctl({"X-LocalSend-Token": TOKENS[53343]}), 403)  # other instance
        self.assertEqual(self.raw_ctl({"X-LocalSend-Token": TOKENS[53341]}), 200)
        # DNS-rebinding style request: right token, wrong Host
        self.assertEqual(self.raw_ctl({"X-LocalSend-Token": TOKENS[53341], "Host": "evil.example"}), 403)

    def test_failed_start_keeps_live_token(self):
        tok = os.path.join(self.tmp.name, "A", "data", "control.token")
        before = open(tok).read()
        dup = subprocess.run(
            [sys.executable, DAEMON, "--data-dir", os.path.dirname(tok), "--save-dir",
             os.path.join(self.tmp.name, "A", "in"), "--port", "53340", "--control-port", "53341"],
            stderr=subprocess.DEVNULL, timeout=20)
        self.assertNotEqual(dup.returncode, 0)  # ports are taken by the live daemon
        self.assertEqual(open(tok).read(), before)
        self.assertEqual(ctl(53341, "GET", "/state")[0], 200)

    def test_secrets_are_private(self):
        data = os.path.join(self.tmp.name, "A", "data")
        self.assertEqual(os.stat(data).st_mode & 0o777, 0o700)
        for name in ("control.token", "key.pem"):
            self.assertEqual(os.stat(os.path.join(data, name)).st_mode & 0o777, 0o600, name)

    def test_file_and_folder_transfer(self):
        src = tempfile.mkdtemp()
        big = os.path.join(src, "big.bin")
        with open(big, "wb") as f:
            f.write(os.urandom(1_500_000))
        os.makedirs(os.path.join(src, "dir", "sub"))
        with open(os.path.join(src, "dir", "sub", "n.txt"), "w") as f:
            f.write("nested")
        s = self.send(paths=[big, os.path.join(src, "dir")])
        self.assertEqual(s["status"], "done", s)
        with open(big, "rb") as a, open(os.path.join(self.in_b, "big.bin"), "rb") as b:
            self.assertEqual(a.read(), b.read())
        with open(os.path.join(self.in_b, "dir", "sub", "n.txt")) as f:
            self.assertEqual(f.read(), "nested")

    def test_text_message(self):
        s = self.send(text="hello from A")
        self.assertEqual(s["status"], "done", s)
        got = wait_for(lambda: next((x for x in ctl(53343, "GET", "/state")[1]["sessions"]
                                     if x["text"] == "hello from A"), None))
        self.assertEqual(got["status"], "done")

    def test_chunked_upload_and_checksum(self):
        data = os.urandom(300_000)
        body = {"info": {"alias": "t", "fingerprint": "x"}, "files": {"1": {
            "id": "1", "fileName": "c.bin", "size": len(data), "fileType": "application/octet-stream",
            "sha256": hashlib.sha256(data).hexdigest()}}}
        st, resp = https(53342, "POST", "/api/localsend/v2/prepare-upload", json.dumps(body))
        self.assertEqual(st, 200)
        r = json.loads(resp)
        chunked = b"".join(b"%x\r\n%s\r\n" % (len(data[i:i + 65536]), data[i:i + 65536])
                           for i in range(0, len(data), 65536)) + b"0\r\n\r\n"
        ctx = ssl.create_default_context()
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
        c = http.client.HTTPSConnection("127.0.0.1", 53342, context=ctx)
        c.putrequest("POST", f"/api/localsend/v2/upload?sessionId={r['sessionId']}&fileId=1&token={r['files']['1']}")
        c.putheader("Transfer-Encoding", "chunked")
        c.endheaders(chunked)
        self.assertEqual(c.getresponse().status, 200)
        with open(os.path.join(self.in_b, "c.bin"), "rb") as f:
            self.assertEqual(f.read(), data)

    def test_path_traversal_is_contained(self):
        body = {"info": {"alias": "t", "fingerprint": "x"}, "files": {"1": {
            "id": "1", "fileName": "../../evil.txt", "size": 1, "fileType": "text/x"}}}
        st, resp = https(53342, "POST", "/api/localsend/v2/prepare-upload", json.dumps(body))
        r = json.loads(resp)
        c = http.client.HTTPSConnection("127.0.0.1", 53342, context=ssl._create_unverified_context())
        c.request("POST", f"/api/localsend/v2/upload?sessionId={r['sessionId']}&fileId=1&token={r['files']['1']}", b"x")
        self.assertEqual(c.getresponse().status, 200)
        self.assertTrue(os.path.exists(os.path.join(self.in_b, "evil.txt")))
        self.assertFalse(os.path.exists(os.path.join(self.in_b, "..", "..", "evil.txt")))

    def upload_to_b(self, name, content=b"new"):
        body = {"info": {"alias": "t", "fingerprint": "x"}, "files": {"1": {
            "id": "1", "fileName": name, "size": len(content), "fileType": "text/x"}}}
        st, resp = https(53342, "POST", "/api/localsend/v2/prepare-upload", json.dumps(body))
        self.assertEqual(st, 200)
        r = json.loads(resp)
        st, _ = https(53342, "POST",
                      f"/api/localsend/v2/upload?sessionId={r['sessionId']}&fileId=1&token={r['files']['1']}",
                      content)
        return st

    def test_part_files_never_follow_symlinks_or_clobber(self):
        os.makedirs(self.in_b, exist_ok=True)
        outside = os.path.join(self.tmp.name, "outside.txt")
        with open(outside, "w") as f:
            f.write("precious")
        os.symlink(outside, os.path.join(self.in_b, "escape.txt.part"))
        with open(os.path.join(self.in_b, "report.txt.part"), "w") as f:
            f.write("keep me")
        self.assertEqual(self.upload_to_b("escape.txt"), 200)
        self.assertEqual(self.upload_to_b("report.txt"), 200)
        with open(outside) as f:
            self.assertEqual(f.read(), "precious")
        with open(os.path.join(self.in_b, "report.txt.part")) as f:
            self.assertEqual(f.read(), "keep me")
        with open(os.path.join(self.in_b, "escape.txt")) as f:
            self.assertEqual(f.read(), "new")

    def test_existing_files_are_not_replaced(self):
        os.makedirs(self.in_b, exist_ok=True)
        with open(os.path.join(self.in_b, "keep.txt"), "w") as f:
            f.write("original")
        # A dangling symlink at the destination must not be written through either.
        target = os.path.join(self.tmp.name, "dangling-target.txt")
        os.symlink(target, os.path.join(self.in_b, "link.txt"))
        self.assertEqual(self.upload_to_b("keep.txt"), 200)
        self.assertEqual(self.upload_to_b("link.txt"), 200)
        with open(os.path.join(self.in_b, "keep.txt")) as f:
            self.assertEqual(f.read(), "original")
        self.assertFalse(os.path.exists(target))
        self.assertTrue(os.path.exists(os.path.join(self.in_b, "keep (1).txt")))
        self.assertTrue(os.path.exists(os.path.join(self.in_b, "link (1).txt")))
        leftovers = [n for n in os.listdir(self.in_b) if n.endswith(".part") and n.startswith(".")]
        self.assertEqual(leftovers, [])

    def test_reject(self):
        # A rejects: only B (auto-accept) is the other side, so reject via a fresh A-side request.
        body = {"info": {"alias": "t", "fingerprint": "x"}, "files": {"1": {
            "id": "1", "fileName": "r.txt", "size": 1, "fileType": "text/x"}}}
        import threading
        result = {}
        th = threading.Thread(target=lambda: result.update(
            zip(("st", "body"), https(53340, "POST", "/api/localsend/v2/prepare-upload", json.dumps(body)))))
        th.start()
        sess = wait_for(lambda: next((s for s in ctl(53341, "GET", "/state")[1]["sessions"]
                                      if s["status"] == "pending"), None))
        ctl(53341, "POST", "/reject", {"session": sess["id"]})
        th.join(10)
        self.assertEqual(result["st"], 403)


if __name__ == "__main__":
    unittest.main()
