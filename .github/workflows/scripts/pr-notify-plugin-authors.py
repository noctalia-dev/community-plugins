import os
import sys

from github import Auth, Github

import plugin_author

NOTIFY_MARKER = "noctalia-pr-author-notify:v1"


def notify(repo, pull_request) -> int:
    """Notify the plugin's original author and move the pull request to draft.

    A pull request opened by someone other than the plugin's original author
    is moved to draft until the author replies; pr-mark-ready-on-author-reply.py
    marks it ready for review again once they do.
    """
    plugin_count, author = plugin_author.plugin_author(repo, pull_request)

    if plugin_count > 1:
        print("Multiple plugin changes in one PR!")
        pull_request.create_issue_comment(
            "This pull request was automatically closed because it contains changes for two or more plugins in one PR!"
        )
        pull_request.edit(state="closed")
        return 0

    if plugin_count != 1:
        print("This is a non-plugin change, returning!")
        return 0

    if author is None:
        print("Could not determine the plugin author, returning!")
        return 0

    pr_author = pull_request.user.login

    if pr_author == author:
        print("The author and maintainer of the plugin are the same!")
        return 0

    pull_request.create_issue_comment(
        f"<!-- {NOTIFY_MARKER} -->\n"
        f"CC @{author} — this pull request was automatically moved to draft until you have had a chance "
        "to look at it. It will be marked ready for review automatically once you reply here."
    )

    if pull_request.state == "open" and not pull_request.draft:
        pull_request.convert_to_draft()

    return 0


def main(argv: list[str]) -> int:
    token = os.environ.get("GITHUB_TOKEN", "")
    repo_name = os.environ.get("REPOSITORY", "")
    pull_request_number = os.environ.get("PULL_REQUEST_NUMBER", "")

    if not pull_request_number.isdigit():
        print("Pull Request number is not numeric!")
        return 1

    auth = Auth.Token(token)
    gh = Github(auth=auth)
    repo = gh.get_repo(repo_name)
    pull_request = repo.get_pull(int(pull_request_number))

    return notify(repo, pull_request)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
