<!-- noctalia-pr-template:v1 -->
<!-- ^ Keep the marker line above this comment.

     A bot closes pull requests whose description loses required template structure.
     Draft pull requests may leave checkboxes incomplete. Before marking a pull request
     ready for review:
     - check exactly one plugin type;
     - check at least one compositor under Testing; and
     - check every item under Checklist and Code review attestation.

     An explanation does not replace a required check. If a required statement is not
     true yet, keep the pull request as Draft.

     Everything else, including every one of these guidance comments, is yours to delete. -->

## Plugin

<!-- The canonical id. The part after the "/" is the plugin's directory in this repo. -->

- **Id:** `<author>/<plugin>`
<!-- Check exactly one plugin type. -->
- [ ] New plugin
- [ ] Update to an existing plugin (version bumped in `plugin.toml`)

## What it does

<!-- A short description, and what a user gets out of it. -->

## External dependencies

<!-- Any command or service the plugin shells out to, and why. List them in `dependencies` in plugin.toml too.
     Write "None" if it is self-contained. -->

## Testing

<!-- How you exercised it: entries opened, IPC messages sent, settings toggled. -->
<!-- Check every compositor on which you actually tested the plugin. At least one is required before review. -->

- [ ] Tested on Niri
- [ ] Tested on Hyprland
- [ ] Tested on Sway
- [ ] Tested on another compositor:
- **Noctalia version tested against:**
- **Plugin API level:** <!-- must match plugin_api in plugin.toml -->

## Screenshots / Videos

<!-- Show the plugin running. Required for anything with a visual surface. -->

## Checklist
**Ready-for-review requirement:** Every box in this section must be checked. If any statement is not true, keep the
pull request as Draft. An explanation does not replace a required check.

- [ ] The directory name matches the part of `id` after the `/` in `plugin.toml` exactly.
- [ ] It ships `plugin.toml`, `README.md`, `thumbnail.webp`, and `translations/en.json`.
- [ ] `README.md` follows the
      [README template](https://github.com/noctalia-dev/community-plugins/blob/main/README_TEMPLATE.md), documents
      every entry id and dependency, and includes exact panel IPC commands and launcher prefixes where applicable.
- [ ] I created `thumbnail.webp` with the [thumbnail generator](https://assets.noctalia.dev/plugins/thumbnail-generator.html).
- [ ] `version` follows semver and is bumped in this PR; `plugin_api` is the oldest API level this plugin requires.
- [ ] Every non-English translation in this PR uses a locale supported by Noctalia core, and I can read, write, and
      understand that language well enough to review and maintain it (no unreviewed machine/LLM translations).
- [ ] I did not edit `catalog.toml`; CI generates it.
- [ ] This PR touches exactly one plugin directory.

## Code review attestation

Plugins run as trusted, unsandboxed Luau in the user's session. Confirm:
**Ready-for-review requirement:** Every attestation below must be checked.

- [ ] The code is readable and not obfuscated, minified, or generated.
- [ ] It does not download and execute remote code.
- [ ] Every network call, filesystem write, and spawned process is something the description above accounts for.
- [ ] I have the right to publish this code under the `license` declared in `plugin.toml`.
