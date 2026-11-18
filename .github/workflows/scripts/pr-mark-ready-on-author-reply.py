import os
import sys

from github import Auth, Github

import plugin_author

NOTIFY_MARKER = "noctalia-pr-author-notify:v1"
ENFORCEMENT_MARKER = "<!-- noctalia-pr-template-enforcement -->"


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

def is_automation_comment(comment_body: str) -> bool:
    """True when the comment was created by a PR automation workflow."""
    return NOTIFY_MARKER in comment_body or ENFORCEMENT_MARKER in comment_body


def mark_ready(repo, pull_request, comment_author, comment_body: str = "") -> bool:
    """Mark a draft pull request ready for review once the plugin author replies.

    Returns True when the pull request was marked ready for review.
    """
    if is_automation_comment(comment_body):
        print("Automation comment cannot mark a pull request ready, returning!")
        return False
    if pull_request.state != "open" or not pull_request.draft:
        print("Pull request is not an open draft, returning!")
        return False

    if not has_notification_marker(pull_request):
        print("Pull request was not moved to draft by the author-notification workflow, returning!")
        return False

    plugin_count, author = plugin_author.plugin_author(repo, pull_request)

    if plugin_count != 1 or author is None:
        print("Could not determine the plugin author, returning!")
        return False

    if comment_author != author:
        print("Comment author is not the plugin author, returning!")
        return False

    pull_request.mark_ready_for_review()
    print(f"Marked pull request #{pull_request.number} ready for review.")
    return True


def main(argv: list[str]) -> int:
    token = os.environ.get("GITHUB_TOKEN", "")
    repo_name = os.environ.get("REPOSITORY", "")
    pull_request_number = os.environ.get("PULL_REQUEST_NUMBER", "")
    comment_author = os.environ.get("COMMENT_AUTHOR", "")
    comment_body = os.environ.get("COMMENT_BODY", "")

    if not pull_request_number.isdigit():
        print("Pull Request number is not numeric!")
        return 1

    auth = Auth.Token(token)
    gh = Github(auth=auth)
    repo = gh.get_repo(repo_name)
    pull_request = repo.get_pull(int(pull_request_number))

    marked = mark_ready(repo, pull_request, comment_author, comment_body)

    # Events caused by the workflow's built-in token start no other workflow runs, so the
    # ready_for_review event does not re-run enforce-pr-template.yml; the calling workflow
    # runs the template check itself when this step reports marked=true.
    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as output:
            output.write(f"marked={'true' if marked else 'false'}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
