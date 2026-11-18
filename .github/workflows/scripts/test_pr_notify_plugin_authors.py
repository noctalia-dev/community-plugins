from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPTS_DIR))

SPEC = importlib.util.spec_from_file_location(
    "pr_notify_plugin_authors", SCRIPTS_DIR / "pr-notify-plugin-authors.py"
)
assert SPEC is not None and SPEC.loader is not None
pr_notify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pr_notify)

import plugin_author


class FakeUser:
    def __init__(self, login: str):
        self.login = login


class FakePullRequest:
    def __init__(self, *, login: str, state: str = "open", draft: bool = False):
        self.user = FakeUser(login)
        self.state = state
        self.draft = draft
        self.comments = []
        self.edits = []
        self.convert_to_draft = mock.Mock()

    def create_issue_comment(self, body: str) -> None:
        self.comments.append(body)

    def edit(self, **kwargs) -> None:
        self.edits.append(kwargs)


class NotifyTests(unittest.TestCase):
    def test_same_author_is_not_notified(self) -> None:
        pull_request = FakePullRequest(login="tordex")
        with mock.patch.object(plugin_author, "plugin_author", return_value=(1, "tordex")):
            code = pr_notify.notify(None, pull_request)
        self.assertEqual(code, 0)
        self.assertEqual(pull_request.comments, [])
        self.assertEqual(pull_request.edits, [])
        pull_request.convert_to_draft.assert_not_called()

    def test_other_author_is_notified_and_pr_drafted(self) -> None:
        pull_request = FakePullRequest(login="contributor")
        with mock.patch.object(plugin_author, "plugin_author", return_value=(1, "tordex")):
            code = pr_notify.notify(None, pull_request)
        self.assertEqual(code, 0)
        self.assertEqual(len(pull_request.comments), 1)
        self.assertIn("@tordex", pull_request.comments[0])
        self.assertIn(pr_notify.NOTIFY_MARKER, pull_request.comments[0])
        pull_request.convert_to_draft.assert_called_once()

    def test_already_draft_pr_is_not_converted_again(self) -> None:
        pull_request = FakePullRequest(login="contributor", draft=True)
        with mock.patch.object(plugin_author, "plugin_author", return_value=(1, "tordex")):
            pr_notify.notify(None, pull_request)
        self.assertEqual(len(pull_request.comments), 1)
        pull_request.convert_to_draft.assert_not_called()

    def test_closed_pr_is_not_converted(self) -> None:
        pull_request = FakePullRequest(login="contributor", state="closed")
        with mock.patch.object(plugin_author, "plugin_author", return_value=(1, "tordex")):
            pr_notify.notify(None, pull_request)
        self.assertEqual(len(pull_request.comments), 1)
        pull_request.convert_to_draft.assert_not_called()

    def test_multi_plugin_pr_is_closed(self) -> None:
        pull_request = FakePullRequest(login="contributor")
        with mock.patch.object(plugin_author, "plugin_author", return_value=(2, None)):
            code = pr_notify.notify(None, pull_request)
        self.assertEqual(code, 0)
        self.assertEqual(len(pull_request.comments), 1)
        self.assertIn("automatically closed", pull_request.comments[0])
        self.assertEqual(pull_request.edits, [{"state": "closed"}])
        pull_request.convert_to_draft.assert_not_called()

    def test_non_plugin_pr_is_ignored(self) -> None:
        pull_request = FakePullRequest(login="contributor")
        with mock.patch.object(plugin_author, "plugin_author", return_value=(0, None)):
            code = pr_notify.notify(None, pull_request)
        self.assertEqual(code, 0)
        self.assertEqual(pull_request.comments, [])
        pull_request.convert_to_draft.assert_not_called()


if __name__ == "__main__":
    unittest.main()
