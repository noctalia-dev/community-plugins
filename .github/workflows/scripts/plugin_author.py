"""Shared lookup of a plugin's original author for pull request automation.

Both the author-notification workflow (pr-notify-plugin-authors.py) and the
author-reply workflow (pr-mark-ready-on-author-reply.py) need to know who
originally authored the plugin touched by a pull request.
"""

import os


def plugin_author(repo, pull_request) -> tuple[int, str | None]:
    """Return ``(plugin_dir_count, author_login)``.

    ``plugin_dir_count`` is the number of non-hidden top-level plugin
    directories the pull request touches. ``author_login`` is the login of
    the author of the first commit that touched the plugin manifest, or
    ``None`` when the count is not exactly one, the manifest is missing, or
    the manifest commit has no author.
    """
    plugin_dirs = set()

    for file in pull_request.get_files():
        file_split = file.filename.split("/")
        if len(file_split) > 1 and not file_split[0].startswith("."):
            plugin_dirs.add(file_split[0])

    if len(plugin_dirs) != 1:
        return len(plugin_dirs), None

    manifest_file = f"{plugin_dirs.pop()}/plugin.toml"

    if not os.path.exists(manifest_file):
        return 1, None

    file_commits = repo.get_commits(path=manifest_file).reversed
    author = file_commits[0].author
    return 1, author.login if author is not None else None
