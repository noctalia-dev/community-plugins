from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))

import plugin_author


class FakeAuthor:
    def __init__(self, login: str | None):
        self.login = login


class FakeCommit:
    def __init__(self, author: FakeAuthor | None):
        self.author = author


class FakeFile:
    def __init__(self, filename: str):
        self.filename = filename


class FakeCommitList:
    def __init__(self, commits: list[FakeCommit]):
        self._commits = commits

    @property
    def reversed(self) -> list[FakeCommit]:
        return list(self._commits)


class FakeRepo:
    def __init__(self, commits: list[FakeCommit]):
        self._commits = commits

    def get_commits(self, path=None) -> FakeCommitList:
        return FakeCommitList(self._commits)


class FakePullRequest:
    def __init__(self, files: list[str]):
        self._files = [FakeFile(f) for f in files]

    def get_files(self):
        return self._files


class PluginAuthorTests(unittest.TestCase):
    def test_single_plugin_returns_oldest_manifest_author(self) -> None:
        repo = FakeRepo([FakeCommit(FakeAuthor("oldest")), FakeCommit(FakeAuthor("newest"))])
        pull_request = FakePullRequest(["alpha/plugin.toml", "alpha/main.luau"])
        with mock.patch.object(plugin_author.os.path, "exists", return_value=True):
            self.assertEqual(plugin_author.plugin_author(repo, pull_request), (1, "oldest"))

    def test_missing_manifest_returns_no_author(self) -> None:
        repo = FakeRepo([FakeCommit(FakeAuthor("oldest"))])
        pull_request = FakePullRequest(["alpha/main.luau"])
        with mock.patch.object(plugin_author.os.path, "exists", return_value=False):
            self.assertEqual(plugin_author.plugin_author(repo, pull_request), (1, None))

    def test_multiple_plugins_returns_count_without_author(self) -> None:
        repo = FakeRepo([FakeCommit(FakeAuthor("oldest"))])
        pull_request = FakePullRequest(["alpha/plugin.toml", "beta/plugin.toml"])
        self.assertEqual(plugin_author.plugin_author(repo, pull_request), (2, None))

    def test_non_plugin_change_returns_zero(self) -> None:
        repo = FakeRepo([FakeCommit(FakeAuthor("oldest"))])
        pull_request = FakePullRequest(["README.md"])
        self.assertEqual(plugin_author.plugin_author(repo, pull_request), (0, None))

    def test_hidden_directory_is_not_a_plugin(self) -> None:
        repo = FakeRepo([FakeCommit(FakeAuthor("oldest"))])
        pull_request = FakePullRequest([".github/workflows/example.yml"])
        self.assertEqual(plugin_author.plugin_author(repo, pull_request), (0, None))

    def test_commit_without_author_returns_none(self) -> None:
        repo = FakeRepo([FakeCommit(None)])
        pull_request = FakePullRequest(["alpha/plugin.toml"])
        with mock.patch.object(plugin_author.os.path, "exists", return_value=True):
            self.assertEqual(plugin_author.plugin_author(repo, pull_request), (1, None))


if __name__ == "__main__":
    unittest.main()
