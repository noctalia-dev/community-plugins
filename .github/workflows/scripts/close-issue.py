import os
import sys

from github import Auth, Github

token = os.environ["GITHUB_TOKEN"]
repo_name = os.environ["REPOSITORY"]
issue_number = os.environ["ISSUE_NUMBER"]
comment_body = os.environ["COMMENT_BODY"]

auth = Auth.Token(token)
gh = Github(auth=auth)
repo = gh.get_repo(repo_name)

try:
    issue_number = int(issue_number)
except:
    print("Issue number is not numeric!")
    sys.exit(1)

issue = repo.get_issue(issue_number)

if "/close" in comment_body:
    g = Github(token)
    repo = g.get_repo(repo_name)
    issue = repo.get_issue(number=issue_number)
    issue.edit(state="closed")
else:
    print("Could not get the author.")
    sys.exit(1)
