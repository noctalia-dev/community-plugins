import os
from types import SimpleNamespace

from backend.http.control import ControlServer


def _control(token: str = "right-token", token_file=None) -> ControlServer:
    state = SimpleNamespace(
        status_listeners=[], server_list_listeners=[], log_listeners=[]
    )
    service = SimpleNamespace(state=state, add_traffic_listener=lambda cb: None)
    return ControlServer(service, token=token, token_file=token_file)


def _request(header: str | None):
    headers = {} if header is None else {"Authorization": header}
    return SimpleNamespace(headers=headers)


def test_missing_header_rejected():
    assert not _control()._authorized(_request(None))


def test_wrong_token_rejected():
    assert not _control()._authorized(_request("Bearer wrong"))


def test_wrong_scheme_rejected():
    assert not _control()._authorized(_request("Basic right-token"))


def test_correct_token_accepted():
    assert _control()._authorized(_request("Bearer right-token"))


def test_empty_configured_token_rejects_everything():
    # A backend that somehow starts without a token must fail closed.
    assert not _control(token="")._authorized(_request("Bearer "))


def test_token_file_written_0600(tmp_path):
    path = tmp_path / "control.token"
    _control(token="secret", token_file=path)._publish_token()
    assert path.read_text().strip() == "secret"
    assert (os.stat(path).st_mode & 0o777) == 0o600
