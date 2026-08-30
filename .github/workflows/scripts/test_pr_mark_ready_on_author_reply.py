from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPTS_DIR))

SPEC = importlib.util.spec_from_file_location(
    "pr_mark_ready_on_author_reply", SCRIPTS_DIR / "pr-mark-ready-on-author-reply.py"
)
assert SPEC is not None and SPEC.loader is not None
pr_mark_ready = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pr_mark_ready)

import plugin_author


class FakeComment:
    def __init__(self, body: str):
        self.body = body


class FakePullRequest:
    def __init__(self, *, state: str = "open", draft: bool = True, comments: list[FakeComment] | None = None, number: int = 42):
        self.state = state
        self.draft = draft
        self.number = number
        self._comments = comments or []
        self.mark_ready_for_review = mock.Mock()

    def get_issue_comments(self) -> list[FakeComment]:
        return self._comments


def marker_comment() -> FakeComment:
    return FakeComment(
        f"<!-- {pr_mark_ready.NOTIFY_MARKER} -->\nCC @tordex — this pull request was automatically moved to draft..."
    )


class MarkReadyTests(unittest.TestCase):
    def test_author_reply_marks_pr_ready(self) -> None:
        pull_request = FakePullRequest(comments=[marker_comment()])
        with mock.patch.object(plugin_author, "plugin_author", return_value=(1, "tordex")):
            code = pr_mark_ready.mark_ready(None, pull_request, "tordex")
        self.assertEqual(code, 0)
        pull_request.mark_ready_for_review.assert_called_once()

    def test_non_author_comment_does_nothing(self) -> None:
        pull_request = FakePullRequest(comments=[marker_comment()])
        with mock.patch.object(plugin_author, "plugin_author", return_value=(1, "tordex")):
            pr_mark_ready.mark_ready(None, pull_request, "someone-else")
        pull_request.mark_ready_for_review.assert_not_called()

    def test_without_notification_marker_does_nothing(self) -> None:
        # Draft created by the contributor themselves, not by the notification workflow.
        pull_request = FakePullRequest(comments=[FakeComment("regular comment")])
        with mock.patch.object(plugin_author, "plugin_author", return_value=(1, "tordex")):
            pr_mark_ready.mark_ready(None, pull_request, "tordex")
        pull_request.mark_ready_for_review.assert_not_called()

    def test_no_comments_at_all_does_nothing(self) -> None:
        pull_request = FakePullRequest(comments=[])
        with mock.patch.object(plugin_author, "plugin_author", return_value=(1, "tordex")):
            pr_mark_ready.mark_ready(None, pull_request, "tordex")
        pull_request.mark_ready_for_review.assert_not_called()

    def test_ready_pr_is_left_alone(self) -> None:
        pull_request = FakePullRequest(draft=False, comments=[marker_comment()])
        with mock.patch.object(plugin_author, "plugin_author", return_value=(1, "tordex")):
            pr_mark_ready.mark_ready(None, pull_request, "tordex")
        pull_request.mark_ready_for_review.assert_not_called()

    def test_closed_pr_is_left_alone(self) -> None:
        pull_request = FakePullRequest(state="closed", comments=[marker_comment()])
        with mock.patch.object(plugin_author, "plugin_author", return_value=(1, "tordex")):
            pr_mark_ready.mark_ready(None, pull_request, "tordex")
        pull_request.mark_ready_for_review.assert_not_called()


if __name__ == "__main__":
    unittest.main()
