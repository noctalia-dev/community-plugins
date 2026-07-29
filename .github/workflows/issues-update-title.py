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
plugin_split = plugin.split('/')

# The Plugin field is free text, so accept both the canonical "<author>/<plugin>" id and
# a bare plugin name, and skip quietly on anything else instead of failing the run.
if len(plugin_split) == 2:
    plugin_name = plugin_split[1].strip()
elif len(plugin_split) == 1:
    plugin_name = plugin_split[0]
else:
    print(f"Unknown format of plugin name, got {plugin}")
    sys.exit(0)

if not plugin_name:
    print("No plugin name given!")
    sys.exit(0)


title = issue.title

if title.startswith(f"[{plugin_name}]"):
    print("Plugin name already exists in the title of the issue.")
    sys.exit(0)

new_title = f"[{plugin_name}]{title}"

issue.edit(title=new_title)
