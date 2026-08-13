def get_plugins() -> list[str]:
    from pathlib import Path

    return sorted(manifest.parent.name for manifest in Path(".").glob("*/plugin.toml"))


def build_dropdown_component(plugins: list[str]) -> str:
    return f"""\
  - type: dropdown
    id: plugin-id
    attributes:
      label: Plugin
      description: The plugin id.
      default: 0
      options:
        - --- SELECT ---
{
"".join([f"""\
        - {plugin}
""" for plugin in plugins])
}
    validations:
      required: true
"""


def build_bug_report(plugins: list[str]) -> str:
    return f"""\
name: Bug Report
description: Report a bug in a community plugin
title: "[BUG] "
labels: ["bug"]
type: "Bug"

body:
  - type: checkboxes
    id: submission-checklist
    attributes:
      label: Submission checklist
      description: Please confirm the following before submitting.
      options:
        - label: I have searched existing issues and confirmed this is not a duplicate.
          required: true
        - label: I am using the latest available version of Noctalia and of the plugin.
          required: true
        - label: This is a bug in a community plugin, not in Noctalia itself (those belong in the noctalia repo).
          required: true

{build_dropdown_component(plugins)}

  - type: input
    id: plugin-version
    attributes:
      label: Plugin version
      description: The version shown in the plugin's plugin.toml.
      placeholder: "1.0.0"
    validations:
      required: true

  - type: textarea
    id: description
    attributes:
      label: Bug description
      description: A clear and concise description of the issue.
      placeholder: Describe the problem...
    validations:
      required: true

  - type: textarea
    id: steps
    attributes:
      label: Steps to reproduce
      description: Steps required to reproduce the issue.
      placeholder: |
        1. Enable ...
        2. Click ...
        3. Observe ...
    validations:
      required: true

  - type: textarea
    id: expected
    attributes:
      label: Expected behavior
      description: What did you expect to happen?
    validations:
      required: true

  - type: textarea
    id: actual
    attributes:
      label: Actual behavior
      description: What actually happened?
    validations:
      required: true

  - type: textarea
    id: logs
    attributes:
      label: Logs / error output
      description: |
        Paste any relevant logs here. Plugin errors are logged by the shell.

        Large outputs can be wrapped in a `<details>` block.
      render: text

  - type: input
    id: noctalia-version
    attributes:
      label: Noctalia version
      description: Enter the version shown by Noctalia, or the commit hash if you are running a development build.
      placeholder: "v5.x.x (commit hash)"
    validations:
      required: true

  - type: dropdown
    id: compositor
    attributes:
      label: Compositor
      description: Select the compositor where the issue occurs.
      options:
        - Niri
        - Hyprland
        - Sway
        - Scroll
        - Labwc
        - Mango
        - Other
    validations:
      required: true

  - type: textarea
    id: environment
    attributes:
      label: Environment information
      description: |
        Anything else about your system that matters: distribution, installation method, and any external
        command the plugin depends on (and its version).

        If you selected `Other` for compositor, please specify it here.
      render: text

  - type: textarea
    id: additional
    attributes:
      label: Additional context
      description: |
        Add any other context, screenshots, or relevant information here.
"""


def build_feature_request(plugins: list[str]) -> str:
    return f"""\
name: Feature Request
description: Suggest an improvement to a community plugin
title: "[FEATURE] "
labels: ["feature"]
type: "Feature"

body:
  - type: checkboxes
    id: submission-checklist
    attributes:
      label: Submission checklist
      description: Please confirm the following before submitting.
      options:
        - label: I have searched existing issues and confirmed this has not been requested before.
          required: true
        - label: I have checked existing pull requests for similar changes.
          required: true
        - label: This is about a community plugin, not about Noctalia itself (those belong in the noctalia repo).
          required: true

{build_dropdown_component(plugins)}

  - type: dropdown
    id: feature-type
    attributes:
      label: Feature type
      description: What kind of feature or improvement is this?
      options:
        - UI / visual improvement
        - New functionality
        - Performance improvement
        - Configuration / customization
        - Accessibility improvement
        - Integration support
        - Documentation improvement
        - Other
    validations:
      required: true

  - type: textarea
    id: summary
    attributes:
      label: Feature summary
      description: A concise description of the feature or enhancement.
      placeholder: What would you like to see added or changed?
    validations:
      required: true

  - type: textarea
    id: motivation
    attributes:
      label: Motivation / use case
      description: |
        Why would this feature be useful?
        What problem does it solve or improve?
      placeholder: Explain the benefit or real-world use case...
    validations:
      required: true

  - type: textarea
    id: proposed-solution
    attributes:
      label: Proposed solution
      description: |
        Describe how you think this could work.

        Mockups, examples, screenshots, or references are welcome.
      placeholder: Describe your idea...
    validations:
      required: true

  - type: textarea
    id: alternatives
    attributes:
      label: Alternatives considered
      description: |
        Have you considered any alternative solutions or workarounds?
      placeholder: Optional...

  - type: textarea
    id: references
    attributes:
      label: References / related projects
      description: |
        Link any related projects, concepts, screenshots, issues, or examples here.
      placeholder: |
        https://github.com/...
        https://example.com/...

  - type: textarea
    id: additional
    attributes:
      label: Additional context
      description: |
        Add any additional information, screenshots, mockups, or context here.
"""


def replace_templates():
    print("Starting to replace templates...")

    plugins = get_plugins()

    bug_report_string = build_bug_report(plugins)
    feature_request_string = build_feature_request(plugins)

    with open(".github/ISSUE_TEMPLATE/bug_report.yml", "wt") as file:
        print("Replacing bug_report.yml")
        file.write(bug_report_string)
        file.close()

    with open(".github/ISSUE_TEMPLATE/feature_request.yml", "wt") as file:
        print("Replacing feature_request.yml")
        file.write(feature_request_string)
        file.close()

    print("Replacing complete...")

if __name__ == "__main__":
    replace_templates()
