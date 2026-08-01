import os
import sys

from github import Auth, Github

token = os.environ["GITHUB_TOKEN"]
repo_name = os.environ["REPOSITORY"]
pull_request_number = os.environ["PULL_REQUEST_NUMBER"]

auth = Auth.Token(token)
gh = Github(auth=auth)
repo = gh.get_repo(repo_name)

if pull_request_number.isdigit():
    pull_request_number = int(pull_request_number)
else:
    print("Pull Request number is not numeric!")
    sys.exit(1)

pull_request = repo.get_pull(pull_request_number)

plugin_dirs = set()
hidden_dirs = set()
root_files = set()

for file in pull_request.get_files():
    file_split = file.filename.split("/")
    if len(file_split) > 1:
        root_dir = file_split[0]
        if root_dir.startswith('.'):
            hidden_dirs.add(root_dir)
        else:
            plugin_dirs.add(root_dir)
    else:
        root_files.add(file)

if len(plugin_dirs) > 1:
    print("Multiple plugin changes in one PR!")
    pull_request.create_issue_comment("This pull request was automatically closed because it contains changes for two or more plugins in one PR!")
    pull_request.edit(state='closed')
    sys.exit(0)
elif len(plugin_dirs) == 1:
    plugin_dir = plugin_dirs.pop()

    manifest_file = f"{plugin_dir}/plugin.toml"

    if os.path.exists(manifest_file):
        file_commits = repo.get_commits(path=manifest_file).reversed
        author = file_commits[0].author

        if author is not None:
            author = author.login
        else:
            print("Author name is null, returning!")
            sys.exit(1)
    else:
        print(f"Plugin manifest doesn't exist, {manifest_file}")
        sys.exit(0)
else:
    print("This is a non-plugin change, returning!")
    sys.exit(0)


pr_author = pull_request.user.login

if pr_author == author:
    print("The author and maintainer of the plugin are the same!")
    sys.exit(0)
else:
    pull_request.create_issue_comment(f"CC @{author}")
