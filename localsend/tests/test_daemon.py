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
HDR = {"X-LocalSend-Ctl": "1", "Content-Type": "application/json"}


def ctl(port, method, path, body=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request(method, path, json.dumps(body) if body is not None else None, HDR)
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

    def test_control_requires_header(self):
        c = http.client.HTTPConnection("127.0.0.1", 53341)
        c.request("GET", "/state")
        self.assertEqual(c.getresponse().status, 403)

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
