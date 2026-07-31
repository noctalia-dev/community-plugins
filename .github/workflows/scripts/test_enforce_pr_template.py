from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from unittest import mock


VALIDATOR_PATH = Path(__file__).with_name("enforce-pr-template.py")
TEMPLATE_PATH = Path(__file__).parents[2] / "PULL_REQUEST_TEMPLATE.md"
SPEC = importlib.util.spec_from_file_location("enforce_pr_template", VALIDATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
enforce_pr_template = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(enforce_pr_template)


class TemplateValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.template = TEMPLATE_PATH.read_text()

    def test_accepts_canonical_template(self) -> None:
        self.assertEqual(enforce_pr_template.missing_requirements(self.template), [])

    def test_accepts_checked_checklist_items(self) -> None:
        checked = self.template.replace("- [ ]", "- [x]")
        self.assertEqual(enforce_pr_template.missing_requirements(checked), [])

    def test_accepts_template_line_wrapping(self) -> None:
        wrapped = self.template.replace(
            "and includes exact panel IPC commands",
            "and includes exact panel IPC\n      commands",
        )
        self.assertEqual(enforce_pr_template.missing_requirements(wrapped), [])

    def test_rejects_missing_version_marker(self) -> None:
        body = self.template.replace(enforce_pr_template.TEMPLATE_MARKER, "")
        self.assertEqual(
            enforce_pr_template.missing_requirements(body),
            ["template version marker"],
        )

    def test_rejects_removed_section(self) -> None:
        body = self.template.replace("## Testing", "## Verification")
        self.assertEqual(
            enforce_pr_template.missing_requirements(body),
            ["## Testing section"],
        )

    def test_rejects_removed_required_field(self) -> None:
        body = self.template.replace("- **Plugin API level:**", "- **API:**")
        self.assertEqual(
            enforce_pr_template.missing_requirements(body),
            ["field: **Plugin API level:**"],
        )

    def test_rejects_altered_multiline_checklist_item(self) -> None:
        body = self.template.replace(
            "`README.md` follows the",
            "`README.md` resembles the",
        )
        self.assertEqual(
            enforce_pr_template.missing_requirements(body),
            [
                "checklist item: `README.md` follows the "
                "[README template](https://github.com/noctalia-dev/community-plugins/blob/main/README_TEMPLATE.md), "
                "documents every entry id and dependency, and includes exact panel IPC commands and launcher prefixes where applicable."
            ],
        )


class TemplateEnforcementTests(unittest.TestCase):
    ISSUE_URL = "https://api.github.test/repos/noctalia-dev/community-plugins/issues/123"
    PULL_REQUEST_URL = "https://api.github.test/repos/noctalia-dev/community-plugins/pulls/123"

    def event(self, body: str) -> dict[str, object]:
        return {
            "pull_request": {
                "body": body,
                "issue_url": self.ISSUE_URL,
                "url": self.PULL_REQUEST_URL,
            }
        }

    def test_valid_template_does_not_call_github(self) -> None:
        template = TEMPLATE_PATH.read_text()
        with mock.patch.object(enforce_pr_template, "github_request") as request:
            self.assertEqual(enforce_pr_template.enforce(self.event(template), "token"), [])
        request.assert_not_called()

    def test_invalid_template_comments_once_and_closes_pull_request(self) -> None:
        def response(url: str, token: str, **kwargs: object) -> object:
            return [] if kwargs.get("method", "GET") == "GET" else {}

        with mock.patch.object(
            enforce_pr_template,
            "github_request",
            side_effect=response,
        ) as request:
            missing = enforce_pr_template.enforce(
                self.event("AI-generated replacement body"),
                "token",
            )

        self.assertIn("template version marker", missing)
        self.assertEqual(
            request.call_args_list,
            [
                mock.call(
                    f"{self.ISSUE_URL}/comments?per_page=100&page=1",
                    "token",
                ),
                mock.call(
                    f"{self.ISSUE_URL}/comments",
                    "token",
                    method="POST",
                    payload={"body": enforce_pr_template.CLOSURE_COMMENT},
                ),
                mock.call(
                    self.PULL_REQUEST_URL,
                    "token",
                    method="PATCH",
                    payload={"state": "closed"},
                ),
            ],
        )

    def test_existing_enforcement_comment_is_not_duplicated(self) -> None:
        existing_comment = {"body": enforce_pr_template.CLOSURE_COMMENT}
        with mock.patch.object(
            enforce_pr_template,
            "github_request",
            side_effect=[[existing_comment], {}],
        ) as request:
            enforce_pr_template.enforce(
                self.event("AI-generated replacement body"),
                "token",
            )

        self.assertEqual(
            request.call_args_list,
            [
                mock.call(
                    f"{self.ISSUE_URL}/comments?per_page=100&page=1",
                    "token",
                ),
                mock.call(
                    self.PULL_REQUEST_URL,
                    "token",
                    method="PATCH",
                    payload={"state": "closed"},
                ),
            ],
        )


if __name__ == "__main__":
    unittest.main()
