#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


TEMPLATE_MARKER = "<!-- noctalia-pr-template:v1 -->"
COMMENT_MARKER = "<!-- noctalia-pr-template-enforcement -->"
REQUIRED_HEADINGS = (
    "## Plugin",
    "## What it does",
    "## External dependencies",
    "## Testing",
    "## Screenshots / Videos",
    "## Checklist",
    "## Code review attestation",
)
REQUIRED_FIELD_PREFIXES = (
    "- **Id:**",
    "- **Noctalia version tested against:**",
    "- **Plugin API level:**",
)
PLUGIN_TYPE_ITEMS = (
    "New plugin",
    "Update to an existing plugin (version bumped in `plugin.toml`)",
)
COMPOSITOR_TEST_ITEMS = (
    "Tested on Niri",
    "Tested on Hyprland",
    "Tested on Sway",
    "Tested on another compositor:",
)
MANDATORY_READY_ITEMS = (
    "The directory name matches the part of `id` after the `/` in `plugin.toml` exactly.",
    "It ships `plugin.toml`, `README.md`, `thumbnail.webp`, and `translations/en.json`.",
    "`README.md` follows the [README template](https://github.com/noctalia-dev/community-plugins/blob/main/README_TEMPLATE.md), documents every entry id and dependency, and includes exact panel IPC commands and launcher prefixes where applicable.",
    "I created `thumbnail.webp` with the [thumbnail generator](https://assets.noctalia.dev/plugins/thumbnail-generator.html).",
    "`version` follows semver and is bumped in this PR; `plugin_api` is the oldest API level this plugin requires.",
    "Every non-English translation in this PR uses a locale supported by Noctalia core, and I can read, write, and understand that language well enough to review and maintain it (no unreviewed machine/LLM translations).",
    "I did not edit `catalog.toml`; CI generates it.",
    "This PR touches exactly one plugin directory.",
    "The code is readable and not obfuscated, minified, or generated.",
    "It does not download and execute remote code.",
    "Every network call, filesystem write, and spawned process is something the description above accounts for.",
    "I have the right to publish this code under the `license` declared in `plugin.toml`.",
)
REQUIRED_CHECKLIST_ITEMS = PLUGIN_TYPE_ITEMS + COMPOSITOR_TEST_ITEMS + MANDATORY_READY_ITEMS
CLOSURE_INTRO = f"""{COMMENT_MARKER}
This pull request was automatically closed because its description no longer contains
every part of [the pull request template](https://github.com/noctalia-dev/community-plugins/blob/main/.github/PULL_REQUEST_TEMPLATE.md)
that this repository requires.

Missing:
"""
CLOSURE_OUTRO = """
Please add the items listed above back to the description, keeping their exact wording, then
reopen the pull request. Reopening re-runs this check. Draft pull requests may leave boxes
unchecked. Before a pull request is ready for review, exactly one plugin type, at least one
tested compositor, and every item under Checklist and Code review attestation must be checked.
"""


def build_closure_comment(missing: list[str]) -> str:
    bullets = "".join(f"- {item}\n" for item in missing)
    return f"{CLOSURE_INTRO}{bullets}{CLOSURE_OUTRO}"


def checklist_state(normalized_body: str, item: str) -> str | None:
    for state in (" ", "x", "X"):
        if f"- [{state}] {item}" in normalized_body:
            return state
    return None


def missing_requirements(body: object, *, require_completed: bool = False) -> list[str]:
    if not isinstance(body, str):
        body = ""

    lines = {line.strip() for line in body.splitlines()}
    normalized_body = " ".join(body.split())
    missing: list[str] = []

    if TEMPLATE_MARKER not in normalized_body:
        missing.append(f"the template marker line `{TEMPLATE_MARKER}`")

    for heading in REQUIRED_HEADINGS:
        if heading not in lines:
            missing.append(f"the `{heading}` heading")

    for prefix in REQUIRED_FIELD_PREFIXES:
        if prefix not in normalized_body:
            missing.append(f"the `{prefix}` field")

    states = {
        item: checklist_state(normalized_body, item)
        for item in REQUIRED_CHECKLIST_ITEMS
    }
    for item, state in states.items():
        if state is None:
            missing.append(f"the checklist entry: {item}")

    if not require_completed:
        return missing

    checked_plugin_types = sum(states[item] in ("x", "X") for item in PLUGIN_TYPE_ITEMS)
    if checked_plugin_types != 1:
        missing.append("exactly one checked plugin type: New plugin or Update to an existing plugin")

    if not any(states[item] in ("x", "X") for item in COMPOSITOR_TEST_ITEMS):
        missing.append("at least one checked compositor testing entry")

    for item in MANDATORY_READY_ITEMS:
        if states[item] == " ":
            missing.append(f"the checked checklist entry: {item}")

    return missing


def github_request(
    url: str,
    token: str,
    *,
    method: str = "GET",
    payload: dict[str, object] | None = None,
) -> Any:
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "noctalia-pr-template-enforcement",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        response_body = response.read()
    return json.loads(response_body) if response_body else None


def latest_enforcement_comment(issue_url: str, token: str) -> str | None:
    page = 1
    latest: str | None = None
    while True:
        comments = github_request(
            f"{issue_url}/comments?per_page=100&page={page}",
            token,
        )
        if not isinstance(comments, list):
            raise RuntimeError("GitHub returned an invalid pull request comment list")
        for comment in comments:
            if not isinstance(comment, dict):
                continue
            body = str(comment.get("body", ""))
            if COMMENT_MARKER in body:
                latest = body
        if len(comments) < 100:
            return latest
        page += 1


def enforce(event: dict[str, object], token: str) -> list[str]:
    pull_request = event.get("pull_request")
    if not isinstance(pull_request, dict):
        raise ValueError("event does not contain a pull_request object")

    is_draft = pull_request.get("draft") is True
    missing = missing_requirements(
        pull_request.get("body"),
        require_completed=not is_draft,
    )
    if not missing:
        return []

    issue_url = pull_request.get("issue_url")
    pull_request_url = pull_request.get("url")
    if not isinstance(issue_url, str) or not isinstance(pull_request_url, str):
        raise ValueError("pull request event is missing GitHub API URLs")
    if not token:
        raise ValueError("GITHUB_TOKEN is required to close an invalid pull request")

    comment = build_closure_comment(missing)
    if latest_enforcement_comment(issue_url, token) != comment:
        github_request(
            f"{issue_url}/comments",
            token,
            method="POST",
            payload={"body": comment},
        )
    github_request(
        pull_request_url,
        token,
        method="PATCH",
        payload={"state": "closed"},
    )
    return missing


def main(argv: list[str]) -> int:
    event_path = Path(argv[1] if len(argv) > 1 else os.environ["GITHUB_EVENT_PATH"])
    try:
        event = json.loads(event_path.read_text())
        if not isinstance(event, dict):
            raise ValueError("GitHub event payload must be a JSON object")
        missing = enforce(event, os.environ.get("GITHUB_TOKEN", ""))
    except (OSError, ValueError, RuntimeError, urllib.error.URLError) as error:
        print(f"::error title=PR template enforcement failed::{error}")
        return 1

    if missing:
        print(
            "::error title=Pull request description is missing required template content::"
            + "; ".join(missing)
        )
        return 1

    print("Pull request description retains the required template structure.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
