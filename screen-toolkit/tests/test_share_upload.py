import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/share-upload.sh'

class Handler(http.server.BaseHTTPRequestHandler):
    requests = []
    response = {'files': [{'url': 'https://example.test/u/image.png'}]}
    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        self.requests.append((self.path, dict(self.headers), body))
        data = json.dumps(self.response).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        pass

class ZiplineUploadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.file = Path(self.tmp.name) / 'capture.png'
        self.file.write_bytes(b'example image')
        Handler.requests.clear()
        Handler.response = {'files': [{'url': 'https://example.test/u/image.png'}]}
        self.base = f'http://127.0.0.1:{self.server.server_port}'
    def run_upload(self, expiry='7d', token='test-token', url=None):
        return subprocess.run(['bash', str(SCRIPT), '--backend', 'zipline', '--url', url or self.base, str(self.file), token, expiry], text=True, capture_output=True)
    def test_expiry_and_multipart(self):
        for expiry, expected in [('1h','1h'), ('1d','1d'), ('7d','7d'), ('30d','30d'), ('permanent','never')]:
            with self.subTest(expiry=expiry):
                result = self.run_upload(expiry)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), 'https://example.test/u/image.png')
                path, headers, body = Handler.requests[-1]
                self.assertEqual(path, '/api/upload')
                self.assertEqual(headers['Authorization'], 'test-token')
                self.assertEqual(headers['X-Zipline-Deletes-At'], expected)
                self.assertIn(b'example image', body)
    def test_invalid_response(self):
        Handler.response = {'files': []}
        self.assertEqual(self.run_upload().returncode, 5)
    def test_legacy_backend_requests(self):
        fake_bin = Path(self.tmp.name) / 'bin'
        fake_bin.mkdir()
        fake_curl = fake_bin / 'curl'
        fake_curl.write_text("#!/bin/bash\nprintf '%s\\n' \"$@\" > \"$CURL_LOG\"\nif [[ \"$*\" == *up.x02.me* ]]; then echo https://example.test/x02; else echo '{\"files\":[{\"url\":\"https://example.test/uguu\"}]}'; fi\n")
        fake_curl.chmod(0o755)
        env = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ['PATH'], CURL_LOG=str(Path(self.tmp.name) / 'curl.log'))
        for key in ['', 'x02-test-key']:
            with self.subTest(backend='x02' if key else 'uguu'):
                result = subprocess.run(['bash', str(SCRIPT), str(self.file), key, '7d'], env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                args = Path(env['CURL_LOG']).read_text()
                if key:
                    self.assertEqual(result.stdout.strip(), 'https://example.test/x02')
                    self.assertIn('https://up.x02.me/api/upload', args)
                    self.assertIn('x-api-key: x02-test-key', args)
                    self.assertIn('expiry=7d', args)
                else:
                    self.assertEqual(result.stdout.strip(), 'https://example.test/uguu')
                    self.assertIn('https://uguu.se/upload', args)
                    self.assertIn('files[]=@', args)



    def test_bad_config_never_uploads(self):
        self.assertEqual(self.run_upload(token='').returncode, 7)
        self.assertEqual(self.run_upload(expiry='bad').returncode, 7)
        self.assertFalse(Handler.requests)

    def test_named_options_and_extra_operands(self):
        command = ['bash', str(SCRIPT), '--backend=zipline', '--url=' + self.base,
                   str(self.file), 'test-token', '1d']
        self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
        self.assertEqual(subprocess.run(command + ['extra'], capture_output=True).returncode, 7)
        self.assertEqual(subprocess.run(['bash', str(SCRIPT), '--backend'], capture_output=True).returncode, 7)

    def test_forced_backends(self):
        fake_bin = Path(self.tmp.name) / 'bin'
        fake_bin.mkdir()
        fake_curl = fake_bin / 'curl'
        fake_curl.write_text("#!/bin/bash\nprintf '%s\\n' \"$@\" > \"$CURL_LOG\"\nif [[ \"$*\" == *up.x02.me* ]]; then echo https://example.test/x02; else echo '{\"files\":[{\"url\":\"https://example.test/uguu\"}]}'; fi\n")
        fake_curl.chmod(0o755)
        env = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ['PATH'], CURL_LOG=str(Path(self.tmp.name) / 'curl.log'))

        result = subprocess.run(['bash', str(SCRIPT), '--backend', 'x02', str(self.file)], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 7, result.stderr)

        result = subprocess.run(['bash', str(SCRIPT), '--backend', 'x02', str(self.file), 'x02-test-key', '7d'], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'https://example.test/x02')
        self.assertIn('https://up.x02.me/api/upload', Path(env['CURL_LOG']).read_text())

        result = subprocess.run(['bash', str(SCRIPT), '--backend', 'uguu', str(self.file), 'x02-test-key', '7d'], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'https://example.test/uguu')
        self.assertIn('https://uguu.se/upload', Path(env['CURL_LOG']).read_text())

if __name__ == '__main__':
    unittest.main()
