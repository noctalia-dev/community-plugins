import os
import sys

from github import Auth, Github

PR_ID_LABEL = "- **Id:**"

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

pr = repo.get_pull(pull_request_number)
body = pr.body
lines = body.splitlines()

pr_author = pr.user.login

for i in range(len(lines)):
    line = lines[i]
    if PR_ID_LABEL in line:
        id_line = line
        break
else:
    print(f"Pull Request '{pull_request_number}' had no id label. Not a plugin PR probably.")
    sys.exit(0)

plugin = id_line.replace(PR_ID_LABEL, "").replace("`", "").strip()
plugin_split = plugin.split("/")

if len(plugin_split) != 2:
    print(f"Unknown format of plugin name, got {plugin}")
    sys.exit(1)

author_name = plugin_split[0]
plugin_name = plugin_split[1]

def is_same_author(author: str):
    if author == pr_author:
        print("The author and maintainer of the plugin are the same!")
        sys.exit(0)

is_same_author(author_name)

manifest_file = f"{plugin_name}/plugin.toml"

if os.path.exists(manifest_file):
    file_commits = repo.get_commits(path=manifest_file).reversed
    author = file_commits[0].author.login
else:
    print(f"Plugin manifest doesn't exist, {manifest_file}")
    sys.exit(1)

is_same_author(author)

if author:
    pr.create_issue_comment(f"CC @{author}")
else:
    print("Could not get the author.")
    sys.exit(1)


