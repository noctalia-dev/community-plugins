import os
import sys

from github import Auth, Github

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

try:
    title_index = lines.index("### Plugin")
except ValueError:
    print("No Plugin title found!")
    sys.exit(0)


for i in range(title_index + 1, len(lines)):
    if lines[i]:
        break

plugin = lines[i].strip()

if "--- SELECT ---" in plugin:
    issue.create_comment("Specify which plugin this issue is about!")
    issue.edit(state='closed', state_reason='null')
