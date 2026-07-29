import os
import sys

from github import Auth, BadCredentialsException, Github, UnknownObjectException

token = os.environ["GITHUB_TOKEN"]
repo_name = os.environ["REPOSITORY"]
issue_number = os.environ["ISSUE_NUMBER"]

auth = Auth.Token(token)
gh = Github(auth=auth)
repo = gh.get_repo(repo_name)

if issue_number.isdigit():
    issue_number = int(issue_number)
else:
    print("Issue number is not numeric!")
    sys.exit(1)


issue = repo.get_issue(issue_number)
body = issue.body
lines = body.splitlines()

title_index = lines.index("### Plugin")
for i in range(title_index + 1, len(lines)):
    if lines[i]:
        break

plugin = lines[i]
plugin_split = plugin.split('/')

if len(plugin_split) != 2:
    print(f"Unknown format of plugin name, got {plugin}")
    sys.exit(1)


author_name = plugin_split[0]
plugin_name = plugin_split[1]

author = ""
try:
    gh.get_user(author_name, lazy=False)
    author = author_name
except UnknownObjectException:
    print(f"User '{author_name}' doesn't exist as a username in github, getting the first commits author!")

    manifest_file = f"{plugin_name}/plugin.toml"
    
    if os.path.exists(manifest_file):
        file_commits = repo.get_commits(path=manifest_file).reversed
        author = file_commits[0].author.login
    else:
        print(f"Plugin manifest doesn't exist, {manifest_file}")
        sys.exit(1)
except BadCredentialsException:
    print("Invalid Github token")
    sys.exit(1)


if author:
    issue.create_comment(f"CC @{author}")
else:
    print("Could not get the author.")
    sys.exit(1)
