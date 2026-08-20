from __future__ import annotations

import importlib.util
import re
import unittest
from pathlib import Path
from unittest import mock


VALIDATOR_PATH = Path(__file__).with_name("enforce-pr-template.py")
TEMPLATE_PATH = Path(__file__).parents[2] / "PULL_REQUEST_TEMPLATE.md"
SPEC = importlib.util.spec_from_file_location("enforce_pr_template", VALIDATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
enforce_pr_template = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(enforce_pr_template)


def ready_template() -> str:
    body = TEMPLATE_PATH.read_text().replace("- [ ]", "- [x]")
    body = body.replace(
        "- [x] Update to an existing plugin (version bumped in `plugin.toml`)",
        "- [ ] Update to an existing plugin (version bumped in `plugin.toml`)",
    )
    for item in enforce_pr_template.COMPOSITOR_TEST_ITEMS[1:]:
        body = body.replace(f"- [x] {item}", f"- [ ] {item}")
    return body


class TemplateValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.template = TEMPLATE_PATH.read_text()

    def test_accepts_canonical_template(self) -> None:
        self.assertEqual(enforce_pr_template.missing_requirements(self.template), [])

    def test_accepts_checked_checklist_items(self) -> None:
        checked = self.template.replace("- [ ]", "- [x]")
        self.assertEqual(enforce_pr_template.missing_requirements(checked), [])

    def test_accepts_completed_ready_template(self) -> None:
        self.assertEqual(
            enforce_pr_template.missing_requirements(
                ready_template(),
                require_completed=True,
            ),
            [],
        )

    def test_ready_template_requires_every_mandatory_item(self) -> None:
        item = enforce_pr_template.MANDATORY_READY_ITEMS[3]
        body = ready_template().replace(f"- [x] {item}", f"- [ ] {item}")
        self.assertEqual(
            enforce_pr_template.missing_requirements(
                body,
                require_completed=True,
            ),
            [f"the checked checklist entry: {item}"],
        )

    def test_ready_template_requires_exactly_one_plugin_type(self) -> None:
        item = enforce_pr_template.PLUGIN_TYPE_ITEMS[1]
        body = ready_template().replace(f"- [ ] {item}", f"- [x] {item}")
        self.assertEqual(
            enforce_pr_template.missing_requirements(
                body,
                require_completed=True,
            ),
            ["exactly one checked plugin type: New plugin or Update to an existing plugin"],
        )

    def test_ready_template_requires_a_tested_compositor(self) -> None:
        body = ready_template()
        for item in enforce_pr_template.COMPOSITOR_TEST_ITEMS:
            body = body.replace(f"- [x] {item}", f"- [ ] {item}")
        self.assertEqual(
            enforce_pr_template.missing_requirements(
                body,
                require_completed=True,
            ),
            ["at least one checked compositor testing entry"],
        )

    def test_accepts_template_line_wrapping(self) -> None:
        wrapped = self.template.replace(
            "and includes exact panel IPC commands",
            "and includes exact panel IPC\n      commands",
        )
        self.assertEqual(enforce_pr_template.missing_requirements(wrapped), [])

    def test_accepts_body_stripped_of_guidance_comments(self) -> None:
        stripped = re.sub(
            r"<!--(?!\s*noctalia-pr-template:v1\s*-->).*?-->",
            "",
            self.template,
            flags=re.DOTALL,
        )
        self.assertNotIn("guidance", stripped)
        self.assertIn(enforce_pr_template.TEMPLATE_MARKER, stripped)
        self.assertEqual(enforce_pr_template.missing_requirements(stripped), [])

    def test_rejects_missing_version_marker(self) -> None:
        body = self.template.replace(enforce_pr_template.TEMPLATE_MARKER, "")
        self.assertEqual(
            enforce_pr_template.missing_requirements(body),
            ["the template marker line `<!-- noctalia-pr-template:v1 -->`"],
        )

    def test_rejects_removed_section(self) -> None:
        body = self.template.replace("## Testing", "## Verification")
        self.assertEqual(
            enforce_pr_template.missing_requirements(body),
            ["the `## Testing` heading"],
        )

    def test_rejects_removed_required_field(self) -> None:
        body = self.template.replace("- **Plugin API level:**", "- **API:**")
        self.assertEqual(
            enforce_pr_template.missing_requirements(body),
            ["the `- **Plugin API level:**` field"],
        )

    def test_rejects_altered_multiline_checklist_item(self) -> None:
        body = self.template.replace(
            "`README.md` follows the",
            "`README.md` resembles the",
        )
        self.assertEqual(
            enforce_pr_template.missing_requirements(body),
            [
                "the checklist entry: `README.md` follows the "
                "[README template](https://github.com/noctalia-dev/community-plugins/blob/main/README_TEMPLATE.md), "
                "documents every entry id and dependency, and includes exact panel IPC commands and launcher prefixes where applicable."
            ],
        )


class TemplateEnforcementTests(unittest.TestCase):
    ISSUE_URL = "https://api.github.test/repos/noctalia-dev/community-plugins/issues/123"
    PULL_REQUEST_URL = "https://api.github.test/repos/noctalia-dev/community-plugins/pulls/123"

    def event(self, body: str, *, draft: bool = False) -> dict[str, object]:
        return {
            "pull_request": {
                "body": body,
                "draft": draft,
                "issue_url": self.ISSUE_URL,
                "url": self.PULL_REQUEST_URL,
            }
        }

    def test_valid_template_does_not_call_github(self) -> None:
        template = ready_template()
        with mock.patch.object(enforce_pr_template, "github_request") as request:
            self.assertEqual(enforce_pr_template.enforce(self.event(template), "token"), [])
        request.assert_not_called()

    def test_draft_template_allows_unchecked_boxes(self) -> None:
        with mock.patch.object(enforce_pr_template, "github_request") as request:
            self.assertEqual(
                enforce_pr_template.enforce(
                    self.event(TEMPLATE_PATH.read_text(), draft=True),
                    "token",
                ),
                [],
            )
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

        self.assertIn(
            "the template marker line `<!-- noctalia-pr-template:v1 -->`",
            missing,
        )
        comment = enforce_pr_template.build_closure_comment(missing)
        for item in missing:
            self.assertIn(f"- {item}\n", comment)
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
                    payload={"body": comment},
                ),
                mock.call(
                    self.PULL_REQUEST_URL,
                    "token",
                    method="PATCH",
                    payload={"state": "closed"},
                ),
            ],
        )

    def test_identical_enforcement_comment_is_not_duplicated(self) -> None:
        body = "AI-generated replacement body"
        missing = enforce_pr_template.missing_requirements(body, require_completed=True)
        existing_comment = {"body": enforce_pr_template.build_closure_comment(missing)}
        with mock.patch.object(
            enforce_pr_template,
            "github_request",
            side_effect=[[existing_comment], {}],
        ) as request:
            enforce_pr_template.enforce(self.event(body), "token")

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

    def test_stale_enforcement_comment_is_replaced_with_current_findings(self) -> None:
        body = ready_template().replace("## Testing", "## Verification")
        stale = {
            "body": enforce_pr_template.build_closure_comment(
                ["the template marker line `<!-- noctalia-pr-template:v1 -->`"]
            )
        }
        with mock.patch.object(
            enforce_pr_template,
            "github_request",
            side_effect=[[stale], {}, {}],
        ) as request:
            missing = enforce_pr_template.enforce(self.event(body), "token")

        self.assertEqual(missing, ["the `## Testing` heading"])
        self.assertEqual(
            request.call_args_list[1],
            mock.call(
                f"{self.ISSUE_URL}/comments",
                "token",
                method="POST",
                payload={"body": enforce_pr_template.build_closure_comment(missing)},
            ),
        )


if __name__ == "__main__":
    unittest.main()
