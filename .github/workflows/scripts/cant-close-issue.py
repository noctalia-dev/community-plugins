import os
import sys

from github import Auth, Github

token = os.environ["GITHUB_TOKEN"]
repo_name = os.environ["REPOSITORY"]
issue_number = os.environ["ISSUE_NUMBER"]

auth = Auth.Token(token)
gh = Github(auth=auth)
repo = gh.get_repo(repo_name)

try:
    issue_number = int(issue_number)
except:
    print("Issue number is not numeric!")
    sys.exit(1)

issue = repo.get_issue(issue_number)
issue.create_comment("You are not assigned to this issue, so you can't close it.")
