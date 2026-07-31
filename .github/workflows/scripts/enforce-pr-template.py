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
REQUIRED_CHECKLIST_ITEMS = (
    "New plugin",
    "Update to an existing plugin (version bumped in `plugin.toml`)",
    "Tested on Niri",
    "Tested on Hyprland",
    "Tested on Sway",
    "Tested on another compositor:",
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
CLOSURE_COMMENT = f"""{COMMENT_MARKER}
This pull request was automatically closed because its description removed or altered required sections of the repository's pull request template.

Restore the current contents of `.github/PULL_REQUEST_TEMPLATE.md`, complete it without deleting its sections, fields, or checklist entries, and then reopen the pull request. Checklist boxes may remain unchecked while the pull request is a draft.
"""


def missing_requirements(body: object) -> list[str]:
    if not isinstance(body, str):
        body = ""

    lines = {line.strip() for line in body.splitlines()}
    normalized_body = " ".join(body.split())
    missing: list[str] = []

    if TEMPLATE_MARKER not in lines:
        missing.append("template version marker")

    for heading in REQUIRED_HEADINGS:
        if heading not in lines:
            missing.append(f"{heading} section")

    for prefix in REQUIRED_FIELD_PREFIXES:
        if prefix not in normalized_body:
            missing.append(f"field: {prefix.removeprefix('- ')}")

    for item in REQUIRED_CHECKLIST_ITEMS:
        if not any(
            f"- [{state}] {item}" in normalized_body
            for state in (" ", "x", "X")
        ):
            missing.append(f"checklist item: {item}")

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


def has_enforcement_comment(issue_url: str, token: str) -> bool:
    page = 1
    while True:
        comments = github_request(
            f"{issue_url}/comments?per_page=100&page={page}",
            token,
        )
        if not isinstance(comments, list):
            raise RuntimeError("GitHub returned an invalid pull request comment list")
        if any(
            isinstance(comment, dict)
            and COMMENT_MARKER in str(comment.get("body", ""))
            for comment in comments
        ):
            return True
        if len(comments) < 100:
            return False
        page += 1


def enforce(event: dict[str, object], token: str) -> list[str]:
    pull_request = event.get("pull_request")
    if not isinstance(pull_request, dict):
        raise ValueError("event does not contain a pull_request object")

    missing = missing_requirements(pull_request.get("body"))
    if not missing:
        return []

    issue_url = pull_request.get("issue_url")
    pull_request_url = pull_request.get("url")
    if not isinstance(issue_url, str) or not isinstance(pull_request_url, str):
        raise ValueError("pull request event is missing GitHub API URLs")
    if not token:
        raise ValueError("GITHUB_TOKEN is required to close an invalid pull request")

    if not has_enforcement_comment(issue_url, token):
        github_request(
            f"{issue_url}/comments",
            token,
            method="POST",
            payload={"body": CLOSURE_COMMENT},
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
        print("::error title=Required PR template content is missing::" + "; ".join(missing))
        return 1

    print("Pull request description retains the required template structure.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
