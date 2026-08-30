import os
import sys

from github import Auth, Github

import plugin_author

NOTIFY_MARKER = "noctalia-pr-author-notify:v1"


def has_notification_marker(pull_request) -> bool:
    """True when the notification workflow moved this pull request to draft.

    Only pull requests carrying our CC comment are un-drafted on author
    reply; drafts the contributor or anyone else created on their own are
    left alone.
    """
    for comment in pull_request.get_issue_comments():
        if NOTIFY_MARKER in (comment.body or ""):
            return True
    return False


def mark_ready(repo, pull_request, comment_author) -> int:
    """Mark a draft pull request ready for review once the plugin author replies."""
    if pull_request.state != "open" or not pull_request.draft:
        print("Pull request is not an open draft, returning!")
        return 0

    if not has_notification_marker(pull_request):
        print("Pull request was not moved to draft by the author-notification workflow, returning!")
        return 0

    plugin_count, author = plugin_author.plugin_author(repo, pull_request)

    if plugin_count != 1 or author is None:
        print("Could not determine the plugin author, returning!")
        return 0

    if comment_author != author:
        print("Comment author is not the plugin author, returning!")
        return 0

    pull_request.mark_ready_for_review()
    print(f"Marked pull request #{pull_request.number} ready for review.")
    return 0


def main(argv: list[str]) -> int:
    token = os.environ.get("GITHUB_TOKEN", "")
    repo_name = os.environ.get("REPOSITORY", "")
    pull_request_number = os.environ.get("PULL_REQUEST_NUMBER", "")
    comment_author = os.environ.get("COMMENT_AUTHOR", "")

    if not pull_request_number.isdigit():
        print("Pull Request number is not numeric!")
        return 1

    auth = Auth.Token(token)
    gh = Github(auth=auth)
    repo = gh.get_repo(repo_name)
    pull_request = repo.get_pull(int(pull_request_number))

    return mark_ready(repo, pull_request, comment_author)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
