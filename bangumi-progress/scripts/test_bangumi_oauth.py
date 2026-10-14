#!/usr/bin/env python3
"""Isolated stdlib tests: fake browser/API, real loopback callback sockets."""

import contextlib
import http.client
import http.server
import io
import json
import os
from pathlib import Path
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from unittest import mock

import bangumi_oauth as oauth


ATTEMPT = "test_attempt_1234567890"


class OAuthTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "data"
        self.client_file = Path(self.temp.name) / "client.json"
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        self.client = {"client_id": "fixture-client", "client_secret": "fixture-secret",
                       "redirect_uri": f"http://127.0.0.1:{self.port}/callback"}
        self.write_client()
        self.now = 1000
        self.calls = []
        self.token_response = {"access_token": "fixture-access", "refresh_token": "fixture-refresh",
                               "expires_in": 60, "token_type": "Bearer"}
        self.profile = {"id": 42, "username": "fixture-user", "nickname": "Fixture User"}
        self.browser_ready = threading.Event()
        self.browser_url = None
        self.helper = oauth.Helper(str(self.directory), str(self.client_file),
                                   transport=self.transport, browser=self.browser,
                                   clock=lambda: self.now, login_timeout=3)
        self.threads = []
        self.addCleanup(self.stop_threads)

    def write_client(self):
        self.client_file.write_text(json.dumps(self.client))

    def transport(self, method, url, data=None, token=None):
        self.calls.append((method, url, data, token))
        if url == oauth.TOKEN_URL:
            return dict(self.token_response)
        self.assertEqual(url, oauth.ME_URL)
        self.assertEqual(token, self.token_response["access_token"])
        return dict(self.profile)

    def browser(self, url):
        self.browser_url = url
        self.browser_ready.set()
        return True

    def stop_threads(self):
        if any(t.is_alive() for t in self.threads):
            self.helper.run("logout")
        for thread in self.threads:
            thread.join(5)

    def start(self, command="login", attempt=ATTEMPT):
        result = []
        thread = threading.Thread(target=lambda: result.append(self.helper.run(command, attempt)))
        self.threads.append(thread)
        thread.start()
        if command == "login":
            self.assertTrue(self.browser_ready.wait(2), "browser did not start")
        return thread, result

    def callback(self, state=None, code="fixture-code", path="/callback", host=None,
                 query=None):
        state = state or urllib.parse.parse_qs(urllib.parse.urlsplit(
            self.browser_url).query)["state"][0]
        query = query or urllib.parse.urlencode({"state": state, "code": code})
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        try:
            connection.request("GET", path + "?" + query,
                               headers={"Host": host or f"127.0.0.1:{self.port}"})
            response = connection.getresponse()
            return response.status, response.read().decode()
        finally:
            connection.close()

    def finish(self, thread, result):
        thread.join(4)
        self.assertFalse(thread.is_alive(), "operation did not finish")
        self.assertEqual(len(result), 1)
        return result[0]

    def login(self):
        thread, result = self.start()
        self.assertEqual(self.callback()[0], 200)
        answer = self.finish(thread, result)
        self.assertTrue(answer["ok"], answer)
        return answer

    def session(self):
        return self.helper.store.read("oauth-session.json")

    @contextlib.contextmanager
    def slow_callback(self):
        """Keep sending incomplete headers faster than an idle timeout."""
        connection = socket.create_connection(("127.0.0.1", self.port), timeout=2)
        stopped, started = threading.Event(), threading.Event()
        connection.sendall(b"GET /callback?code=fixture-code HTTP/1.1\r\nX-Slow: ")

        def drip():
            try:
                while not stopped.is_set():
                    connection.sendall(b"x")
                    started.set()
                    stopped.wait(0.03)
            except OSError:
                pass  # The expected server close may race the next send.

        sender = threading.Thread(target=drip)
        sender.start()
        try:
            self.assertTrue(started.wait(1), "slow callback did not start")
            yield connection
        finally:
            stopped.set()
            connection.close()
            sender.join(2)
            self.assertFalse(sender.is_alive(), "slow callback sender did not stop")

    def assert_disconnected(self, connection):
        try:
            self.assertEqual(connection.recv(1), b"", "callback connection is still open")
        except ConnectionResetError:
            pass

    def login_again(self):
        self.browser_ready.clear()
        self.helper.login_timeout = 3
        thread, result = self.start(attempt=ATTEMPT + "-next")
        self.assertEqual(self.callback()[0], 200)
        self.assertTrue(self.finish(thread, result)["ok"])

    @contextlib.contextmanager
    def fake_xdg_open(self, *, exit_code=None):
        """A real launcher held open until teardown; never starts a browser."""
        binary_dir = Path(self.temp.name) / "bin"
        binary_dir.mkdir(exist_ok=True)
        started = binary_dir / "started"
        release = binary_dir / "release"
        started.unlink(missing_ok=True)
        release.unlink(missing_ok=True)
        launcher = binary_dir / "xdg-open"
        launcher.write_text(
            f"#!{sys.executable}\n"
            "from pathlib import Path\nimport time\n"
            f"Path({str(started)!r}).touch()\n"
            + (f"raise SystemExit({exit_code})\n" if exit_code is not None else
               f"deadline = time.monotonic() + 6\n"
               f"while not Path({str(release)!r}).exists() and time.monotonic() < deadline:\n"
               "    time.sleep(0.01)\n"))
        launcher.chmod(0o700)
        processes = []

        def browser(url):
            self.browser_url = url
            self.browser_ready.set()
            result = oauth.open_browser(url)
            if hasattr(result, "poll"):
                processes.append(result)
            return result

        self.helper.browser = browser
        with mock.patch.dict(os.environ, {"PATH": str(binary_dir)}):
            try:
                yield started, processes
            finally:
                release.touch()
                for thread in self.threads:
                    thread.join(2)
                for process in processes:
                    process.wait(timeout=2)

    def wait_for_launcher(self, started):
        deadline = time.monotonic() + 2
        while not started.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(started.exists(), "fake launcher did not start")

    def test_live_launcher_does_not_block_callback_or_kill_browser(self):
        with self.fake_xdg_open() as (started, processes):
            thread, result = self.start()
            self.wait_for_launcher(started)
            self.assertEqual(self.callback(state="wrong-state")[0], 400)
            self.assertEqual(self.callback()[0], 200)
            self.assertTrue(self.finish(thread, result)["ok"])
            self.assertIsNone(processes[0].poll(), "launcher must survive successful login")

    def test_live_launcher_does_not_delay_cancel_or_timeout(self):
        for command in ("cancel", "timeout"):
            with self.subTest(command=command), self.fake_xdg_open() as (started, processes):
                self.browser_ready.clear()
                self.helper.login_timeout = 0.3 if command == "timeout" else 3
                thread, result = self.start(attempt=ATTEMPT + command)
                self.wait_for_launcher(started)
                if command == "cancel":
                    self.helper.run("cancel", ATTEMPT + command)
                thread.join(1)
                self.assertFalse(thread.is_alive(), "launcher blocked cancellation or timeout")
                expected = "oauth_cancelled" if command == "cancel" else "oauth_timeout"
                self.assertEqual(result, [oauth.error(expected)])
                self.assertIsNone(self.session())
                self.assertEqual(self.calls, [])
                self.assertIsNone(processes[0].poll(), "helper must not terminate the browser")
                with socket.socket() as listener:
                    listener.bind(("127.0.0.1", self.port))

    def test_launcher_early_failure_is_reported_before_login_timeout(self):
        with self.fake_xdg_open(exit_code=9) as (started, _processes):
            thread, result = self.start()
            self.wait_for_launcher(started)
            thread.join(1)
            self.assertFalse(thread.is_alive(), "early launcher failure was not reported")
            self.assertEqual(result, [oauth.error("browser_open_failed")])
            self.assertIsNone(self.session())
            self.assertEqual(self.calls, [])

    def test_login_profile_and_no_credential_in_result_or_status(self):
        answer = self.login()
        self.assertEqual(answer["user_id"], 42)
        self.assertEqual(self.session()["version"], 1)
        self.assertEqual(self.session()["expires_at"], 1060)
        self.assertEqual(self.session()["nickname"], "Fixture User")
        status = self.helper.run("status")
        self.assertEqual(status["configured"], True)
        self.assertEqual(status["expired"], False)
        for secret in ("fixture-access", "fixture-refresh", "fixture-secret", "fixture-code"):
            self.assertNotIn(secret, json.dumps(answer) + json.dumps(status))
        self.assertEqual(self.calls[0][0:2], ("POST", oauth.TOKEN_URL))
        self.assertEqual(self.calls[0][2]["grant_type"], "authorization_code")
        self.assertEqual(self.calls[1][0:2], ("GET", oauth.ME_URL))

    def test_atomic_storage_syncs_parent_after_private_file_replace(self):
        operations = []
        original_fsync, original_replace = os.fsync, os.replace

        def sync(fd):
            info = os.fstat(fd)
            operations.append("directory" if stat.S_ISDIR(info.st_mode) else "file")
            original_fsync(fd)

        def replace(source, destination):
            operations.append("replace")
            original_replace(source, destination)

        with mock.patch.object(oauth.os, "fsync", side_effect=sync), \
                mock.patch.object(oauth.os, "replace", side_effect=replace):
            self.helper.store.write("fixture.json", {"synthetic": True})
        self.assertEqual(operations, ["file", "replace", "directory"])
        self.assertEqual(stat.S_IMODE((self.directory / "fixture.json").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)

    def test_directory_sync_failure_is_reported_without_private_exception_text(self):
        original_fsync = os.fsync

        def sync(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError("fixture-private-storage")
            original_fsync(fd)

        with mock.patch.object(oauth.os, "fsync", side_effect=sync):
            answer = self.helper.run("cancel", ATTEMPT)
        self.assertEqual(answer, oauth.error("oauth_storage_error"))
        self.assertEqual(list(self.directory.glob(".oauth-*")), [])

    def test_wrong_state_host_and_path_rejected_then_valid_code_once(self):
        thread, result = self.start()
        self.assertEqual(self.callback(state="wrong-state")[0], 400)
        self.assertEqual(self.callback(path="/other")[0], 400)
        self.assertEqual(self.callback(host="evil.invalid")[0], 400)
        state = urllib.parse.parse_qs(urllib.parse.urlsplit(self.browser_url).query)["state"][0]
        self.assertEqual(self.callback(query=f"state={state}&state={state}&code=x")[0], 400)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.callback()[0], 200)
        self.assertTrue(self.finish(thread, result)["ok"])
        self.assertEqual(sum(c[1] == oauth.TOKEN_URL for c in self.calls), 1)

    def test_access_denied(self):
        thread, result = self.start()
        state = urllib.parse.parse_qs(urllib.parse.urlsplit(self.browser_url).query)["state"][0]
        self.assertEqual(self.callback(query=f"state={state}&error=access_denied")[0], 200)
        self.assertEqual(self.finish(thread, result), oauth.error("oauth_access_denied"))
        self.assertIsNone(self.session())
        self.assertEqual(self.calls, [])

    def test_cancel_while_waiting(self):
        thread, result = self.start()
        self.assertTrue(self.helper.run("cancel", ATTEMPT)["ok"])
        self.assertEqual(self.finish(thread, result), oauth.error("oauth_cancelled"))
        self.assertIsNone(self.session())

    def test_slow_header_request_has_absolute_deadline_then_valid_callback_works(self):
        with mock.patch.object(oauth, "CALLBACK_REQUEST_TIMEOUT", 0.35):
            thread, result = self.start()
            with self.slow_callback() as connection:
                started = time.monotonic()
                self.assert_disconnected(connection)
                self.assertLess(time.monotonic() - started, 1)
                self.assertTrue(thread.is_alive(), "request timeout must leave login available")
                self.assertEqual(self.calls, [])
                self.assertEqual(self.callback()[0], 200)
                self.assertTrue(self.finish(thread, result)["ok"])

    def test_slow_header_login_deadline_closes_socket_and_releases_next_login(self):
        self.helper.login_timeout = 0.3
        thread, result = self.start()
        with self.slow_callback() as connection:
            thread.join(1)
            self.assertFalse(thread.is_alive(), "dripped headers extended the login deadline")
            self.assertEqual(result, [oauth.error("oauth_timeout")])
            self.assert_disconnected(connection)
            self.assertIsNone(self.session())
            self.assertEqual(self.calls, [])
            # The first client's socket remains open while we reuse the port and
            # operation lock, so client teardown cannot make this assertion pass.
            self.login_again()

    def test_slow_header_cancel_closes_socket_and_releases_next_login(self):
        thread, result = self.start()
        with self.slow_callback() as connection:
            self.assertTrue(self.helper.run("cancel", ATTEMPT)["cancelled"])
            thread.join(1)
            self.assertFalse(thread.is_alive(), "dripped headers blocked cancellation")
            self.assertEqual(result, [oauth.error("oauth_cancelled")])
            self.assert_disconnected(connection)
            self.assertIsNone(self.session())
            self.assertEqual(self.calls, [])
            self.login_again()

    def test_oversized_incomplete_header_is_closed_without_exchanging_tokens(self):
        thread, result = self.start()
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as connection:
            try:
                connection.sendall(b"GET /callback HTTP/1.1\r\nX-Large: "
                                   + b"x" * oauth.CALLBACK_HEADER_LIMIT)
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.assert_disconnected(connection)
            self.assertEqual(self.calls, [])
            self.assertEqual(self.callback()[0], 200)
            self.assertTrue(self.finish(thread, result)["ok"])

    def test_cancel_wrong_attempt_does_not_cancel_login(self):
        thread, result = self.start()
        self.helper.run("cancel", "different_attempt_12345")
        self.callback()
        self.assertTrue(self.finish(thread, result)["ok"])

    def test_cancel_before_login_process_begins(self):
        self.helper.run("cancel", ATTEMPT)
        self.assertEqual(self.helper.run("login", ATTEMPT), oauth.error("oauth_cancelled"))
        self.assertIsNone(self.browser_url)

    def test_commit_before_cancel_reports_completed_before_login_result_arrives(self):
        committed, release = threading.Event(), threading.Event()
        original_commit = self.helper.commit

        def delayed_result(*args, **kwargs):
            original_commit(*args, **kwargs)
            committed.set()
            self.assertTrue(release.wait(3), "login result was not released")

        self.helper.commit = delayed_result
        thread, result = self.start()
        try:
            self.assertEqual(self.callback()[0], 200)
            self.assertTrue(committed.wait(2), "session was not committed")
            saved = self.session()
            self.assertEqual(saved["login_attempt_id"], ATTEMPT)
            self.assertEqual(result, [], "fixture did not hold the login result")
            generation = self.helper.store.control()["generation"]
            cancelled = self.helper.run("cancel", ATTEMPT)
            self.assertEqual(cancelled, {"ok": True, "cancelled": False,
                                         "completed": True, "authenticated": True})
            self.assertEqual(self.session(), saved)
            self.assertEqual(self.helper.store.control()["generation"], generation)
            for secret in ("fixture-access", "fixture-refresh", "fixture-secret"):
                self.assertNotIn(secret, json.dumps(cancelled))
        finally:
            release.set()
        self.assertTrue(self.finish(thread, result)["ok"])

    def test_cancel_before_commit_retains_previous_account_session(self):
        self.login()
        previous = self.session()
        self.browser_ready.clear()
        self.profile = {"id": 84, "username": "next-user", "nickname": "Next User"}
        entered, release = threading.Event(), threading.Event()
        original_commit = self.helper.commit

        def before_commit(*args, **kwargs):
            entered.set()
            self.assertTrue(release.wait(3), "commit was not released")
            original_commit(*args, **kwargs)

        self.helper.commit = before_commit
        attempt = ATTEMPT + "-next"
        thread, result = self.start(attempt=attempt)
        try:
            self.assertEqual(self.callback()[0], 200)
            self.assertTrue(entered.wait(2), "login did not reach the commit boundary")
            cancelled = self.helper.run("cancel", attempt)
            self.assertTrue(cancelled["cancelled"])
            self.assertFalse(cancelled.get("completed", False))
            self.assertEqual(self.session(), previous)
        finally:
            release.set()
        self.assertEqual(self.finish(thread, result), oauth.error("oauth_cancelled"))
        self.assertEqual(self.session(), previous)

    def test_old_completed_cancel_does_not_invalidate_new_login_attempt(self):
        self.login()
        previous = self.session()
        self.browser_ready.clear()
        self.profile = {"id": 84, "username": "next-user", "nickname": "Next User"}
        thread, result = self.start(attempt=ATTEMPT + "-next")
        generation = self.helper.store.control()["generation"]
        cancelled = self.helper.run("cancel", ATTEMPT)
        self.assertTrue(cancelled["completed"])
        self.assertFalse(cancelled["cancelled"])
        self.assertEqual(self.helper.store.control()["generation"], generation)
        self.assertEqual(self.helper.store.control()["attempt_id"], ATTEMPT + "-next")
        self.assertEqual(self.session(), previous)
        self.assertEqual(self.callback()[0], 200)
        self.assertTrue(self.finish(thread, result)["ok"])
        self.assertEqual(self.session()["user_id"], 84)
        self.assertEqual(self.session()["login_attempt_id"], ATTEMPT + "-next")

    def test_logout_or_cancel_during_exchange_cannot_commit(self):
        for command in ("cancel", "logout"):
            with self.subTest(command=command):
                self.browser_ready.clear()
                entered, release = threading.Event(), threading.Event()
                original = self.transport
                def blocked(*args, **kwargs):
                    if args[1] == oauth.TOKEN_URL:
                        entered.set()
                        self.assertTrue(release.wait(3))
                    return original(*args, **kwargs)
                self.helper.transport = blocked
                attempt = ATTEMPT + command
                thread, result = self.start(attempt=attempt)
                self.callback()
                self.assertTrue(entered.wait(2))
                self.helper.run(command, attempt)
                release.set()
                self.assertEqual(self.finish(thread, result), oauth.error("oauth_cancelled"))
                self.assertIsNone(self.session())

    def test_timeout_and_browser_failure(self):
        self.helper.browser = lambda _url: False
        self.assertEqual(self.helper.run("login"), oauth.error("browser_open_failed"))
        self.helper.browser = self.browser
        self.helper.login_timeout = 0.05
        thread, result = self.start()
        self.assertEqual(self.finish(thread, result), oauth.error("oauth_timeout"))
        self.assertIsNone(self.session())

    def test_port_in_use_does_not_start_browser(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", self.port))
            listener.listen()
            self.assertEqual(self.helper.run("login"), oauth.error("callback_port_in_use"))
        self.assertIsNone(self.browser_url)

    def test_directory_and_every_stored_file_are_private(self):
        self.login()
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)
        for filename in self.directory.iterdir():
            self.assertEqual(stat.S_IMODE(filename.stat().st_mode), 0o600, filename)

    def test_symlink_storage_is_rejected_without_touching_target(self):
        target = Path(self.temp.name) / "target"
        target.write_text("{}")
        target.chmod(0o644)
        (self.directory / "oauth-session.json").symlink_to(target)
        self.assertEqual(self.helper.run("status"), oauth.error("oauth_storage_error"))
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)

    def test_missing_or_empty_configuration_is_honest(self):
        for contents in ("", "{}", "[]", '{"client_id":""}'):
            with self.subTest(contents=contents):
                self.client_file.write_text(contents)
                self.assertEqual(self.helper.run("login"), oauth.error("oauth_not_configured"))
                self.assertEqual(self.helper.run("status"),
                                 {"ok": True, "configured": False, "authenticated": False})

    def test_redirect_must_be_exact_ipv4_loopback_callback(self):
        for uri in ("http://0.0.0.0:1234/callback", "http://localhost:1234/callback",
                    "http://remote.invalid:1234/callback", "https://127.0.0.1:1234/callback",
                    "http://127.0.0.1/callback", "http://127.0.0.1:1234/wrong",
                    "http://127.0.0.1:1234/callback?q=x", "http://a@127.0.0.1:1234/callback"):
            with self.subTest(uri=uri):
                self.client["redirect_uri"] = uri
                self.write_client()
                self.assertEqual(self.helper.run("login"), oauth.error("oauth_not_configured"))

    def test_client_fingerprint_change_requires_login(self):
        self.login()
        self.client["client_secret"] = "changed-secret"
        self.write_client()
        self.assertEqual(self.helper.run("status")["error"], "oauth_client_changed")
        self.assertEqual(self.helper.run("refresh"), oauth.error("oauth_client_changed"))

    def test_expiry_and_rotated_refresh(self):
        self.login()
        self.now = 1061
        self.assertTrue(self.helper.run("status")["expired"])
        self.token_response.update(access_token="rotated-access", refresh_token="rotated-refresh")
        result = self.helper.run("refresh")
        self.assertTrue(result["ok"], result)
        self.assertEqual(self.session()["access_token"], "rotated-access")
        self.assertEqual(self.session()["refresh_token"], "rotated-refresh")
        self.assertEqual(self.session()["expires_at"], 1121)
        self.assertEqual(self.calls[-1][2]["refresh_token"], "fixture-refresh")
        self.helper.run("refresh")
        self.assertEqual(self.calls[-1][2]["refresh_token"], "rotated-refresh")

    def test_missing_refresh_token_retains_old_but_empty_does_not(self):
        self.login()
        del self.token_response["refresh_token"]
        self.assertTrue(self.helper.run("refresh")["ok"])
        self.assertEqual(self.session()["refresh_token"], "fixture-refresh")
        original = self.session()
        for invalid in ("", None, 7):
            self.token_response["refresh_token"] = invalid
            self.assertEqual(self.helper.run("refresh"), oauth.error("oauth_exchange_failed"))
            self.assertEqual(self.session(), original)

    def test_invalid_grant_marks_relogin_and_never_exposes_error_body(self):
        self.login()
        old_token = self.session()["access_token"]
        def invalid(*_args, **_kwargs):
            raise oauth.OAuthError("oauth_invalid_grant")
        self.helper.transport = invalid
        self.assertEqual(self.helper.run("refresh"), oauth.error("oauth_invalid_grant"))
        self.assertEqual(self.session()["access_token"], old_token)
        self.assertTrue(self.helper.run("status")["relogin_required"])

    def test_transient_refresh_failure_retains_valid_session(self):
        self.login()
        original = self.session()
        def unavailable(*_args, **_kwargs):
            raise oauth.OAuthError("oauth_network_error")
        self.helper.transport = unavailable
        self.assertEqual(self.helper.run("refresh"), oauth.error("oauth_network_error"))
        self.assertEqual(self.session(), original)
        self.assertFalse(self.helper.run("status")["expired"])

    def test_bad_profile_cannot_save_tokens_or_change_identity(self):
        self.profile = {"id": "42"}
        thread, result = self.start()
        self.callback()
        self.assertEqual(self.finish(thread, result), oauth.error("oauth_profile_failed"))
        self.assertIsNone(self.session())
        self.profile = {"id": 42, "username": "fixture-user"}
        self.browser_ready.clear()
        self.login()
        original = self.session()
        self.token_response["user_id"] = 99
        self.assertEqual(self.helper.run("refresh"), oauth.error("oauth_profile_failed"))
        self.assertEqual(self.session(), original)

    def test_login_rejects_missing_empty_or_whitespace_username(self):
        for index, username in enumerate((None, "", "   ", 42)):
            with self.subTest(username=username):
                self.profile["username"] = username
                self.browser_ready.clear()
                thread, result = self.start(attempt=ATTEMPT + str(index))
                self.callback()
                self.assertEqual(self.finish(thread, result), oauth.error("oauth_profile_failed"))
                self.assertIsNone(self.session())

    def test_refresh_rotation_survives_profile_outage_without_me_request(self):
        self.login()
        identity = {key: self.session()[key] for key in ("user_id", "username", "nickname")}
        self.calls.clear()
        current_refresh = ["fixture-refresh"]
        def rotating(method, url, data=None, token=None):
            self.calls.append((method, url, data, token))
            if url == oauth.ME_URL:
                raise oauth.OAuthError("oauth_network_error")
            self.assertEqual(data["refresh_token"], current_refresh[0])
            current_refresh[0] += "-rotated"
            return {"access_token": "rotated-access", "refresh_token": current_refresh[0],
                    "expires_in": 120, "user_id": 42}
        self.helper.transport = rotating
        for _ in range(2):
            self.assertTrue(self.helper.run("refresh")["ok"])
            self.assertEqual(self.session()["refresh_token"], current_refresh[0])
            self.assertEqual({key: self.session()[key] for key in identity}, identity)
        self.assertEqual([call[1] for call in self.calls], [oauth.TOKEN_URL, oauth.TOKEN_URL])

    def test_damaged_local_identity_fails_before_refresh_token_is_consumed(self):
        self.login()
        session = self.session()
        session["username"] = ""
        self.helper.store.write("oauth-session.json", session)
        self.calls.clear()
        self.assertEqual(self.helper.run("refresh"), oauth.error("oauth_profile_failed"))
        self.assertEqual(self.calls, [])

    def test_unknown_exceptions_never_escape_with_secret_messages(self):
        def unexpected(*_args, **_kwargs):
            raise RuntimeError("fixture-secret fixture-access fixture-code")
        self.login()
        self.helper.transport = unexpected
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(self.helper.run("refresh"), oauth.error("oauth_internal_error"))
            with mock.patch.object(oauth, "Helper", side_effect=unexpected):
                result = oauth.main(["status", "--data-dir", str(self.directory),
                                     "--client-file", str(self.client_file)])
        self.assertEqual(result, 1)
        self.assertEqual(json.loads(output.getvalue()), oauth.error("oauth_internal_error"))
        self.assertEqual(errors.getvalue(), "")
        self.assertNotIn("fixture-", output.getvalue())

    def test_concurrent_refresh_is_busy_and_logout_fences_inflight_refresh(self):
        self.login()
        entered, release = threading.Event(), threading.Event()
        original = self.transport
        def blocked(*args, **kwargs):
            if args[1] == oauth.TOKEN_URL:
                entered.set()
                self.assertTrue(release.wait(3))
            return original(*args, **kwargs)
        self.helper.transport = blocked
        thread, result = self.start("refresh")
        self.assertTrue(entered.wait(2))
        self.assertEqual(self.helper.run("refresh"), oauth.error("oauth_busy"))
        self.assertEqual(self.helper.run("login"), oauth.error("oauth_busy"))
        self.helper.run("logout")
        release.set()
        self.assertEqual(self.finish(thread, result), oauth.error("oauth_cancelled"))
        self.assertIsNone(self.session())

    def test_cli_stdout_is_one_metadata_json_and_logout_deletes_session(self):
        self.login()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = oauth.main(["status", "--data-dir", str(self.directory),
                                 "--client-file", str(self.client_file)])
        self.assertEqual(result, 0)
        self.assertEqual(len(output.getvalue().splitlines()), 1)
        self.assertTrue(json.loads(output.getvalue())["authenticated"])
        for secret in ("fixture-access", "fixture-refresh", "fixture-secret"):
            self.assertNotIn(secret, output.getvalue())
        self.assertTrue(self.helper.run("logout")["ok"])
        self.assertIsNone(self.session())
        self.assertFalse(self.helper.run("status")["authenticated"])

    def test_fake_http_token_endpoint_uses_form_and_bearer(self):
        received = []
        response = dict(self.token_response)
        profile = dict(self.profile)
        class API(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass
            def send_json(self, payload):
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                received.append((self.path, self.headers["Content-Type"],
                                 urllib.parse.parse_qs(body.decode())))
                self.send_json(response)
            def do_GET(self):
                received.append((self.path, self.headers.get("Authorization")))
                self.send_json(profile)
        server = http.server.HTTPServer(("127.0.0.1", 0), API)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        def local_transport(method, url, **kwargs):
            path = "/token" if url == oauth.TOKEN_URL else "/me"
            return oauth.request_json(method, f"http://127.0.0.1:{server.server_port}{path}", **kwargs)
        self.helper.transport = local_transport
        try:
            self.login()
        finally:
            server.shutdown()
            thread.join()
            server.server_close()
        self.assertEqual(received[0][0:2], ("/token", "application/x-www-form-urlencoded"))
        self.assertEqual(received[0][2]["code"], ["fixture-code"])
        self.assertEqual(received[1], ("/me", "Bearer fixture-access"))

    def test_browser_is_argv_and_does_not_capture_or_emit_remote_output(self):
        with mock.patch.object(oauth.subprocess, "Popen") as launch, \
                mock.patch.object(oauth.threading, "Thread") as reaper:
            self.assertIs(oauth.open_browser("https://bgm.tv/oauth/authorize?state=x"),
                          launch.return_value)
            args, kwargs = launch.call_args
            self.assertEqual(args[0], ["xdg-open", "https://bgm.tv/oauth/authorize?state=x"])
            self.assertNotIn("shell", kwargs)
            self.assertNotIn("timeout", kwargs)
            self.assertEqual(kwargs["stdin"], oauth.subprocess.DEVNULL)
            self.assertEqual(kwargs["stdout"], oauth.subprocess.DEVNULL)
            self.assertEqual(kwargs["stderr"], oauth.subprocess.DEVNULL)
            self.assertTrue(kwargs["start_new_session"])
            reaper.assert_called_once_with(target=launch.return_value.wait, daemon=True)
            reaper.return_value.start.assert_called_once_with()

    def test_missing_browser_launcher_returns_private_failure(self):
        with mock.patch.object(oauth.subprocess, "Popen", side_effect=OSError("fixture-private")):
            self.assertFalse(oauth.open_browser("https://bgm.tv/oauth/authorize?state=x"))

    def test_http_redirect_is_not_followed_and_error_body_is_private(self):
        visited = []
        class API(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass
            def do_GET(self):
                visited.append(self.path)
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", "/steal-token")
                    self.end_headers()
                else:
                    body = json.dumps({"error": "invalid_grant", "access_token": "leaked-access",
                                       "refresh_token": "leaked-refresh"}).encode()
                    self.send_response(400)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
        server = http.server.HTTPServer(("127.0.0.1", 0), API)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        output, errors = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                with self.assertRaises(oauth.OAuthError) as redirect:
                    oauth.request_json("GET", base + "/redirect", token="leaked-access")
                with self.assertRaises(oauth.OAuthError) as invalid:
                    oauth.request_json("GET", base + "/error", token="leaked-access")
        finally:
            server.shutdown()
            thread.join()
            server.server_close()
        self.assertEqual(redirect.exception.code, "oauth_exchange_failed")
        self.assertEqual(invalid.exception.code, "oauth_invalid_grant")
        self.assertEqual(str(invalid.exception), "oauth_invalid_grant")
        self.assertEqual(visited, ["/redirect", "/error"])
        self.assertEqual(output.getvalue() + errors.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
