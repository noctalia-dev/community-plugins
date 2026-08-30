# Review of PR #520: feat: add Cloudflare WARP plugin

## Findings

```text
1. non-blocking - warp/translations/de.json:22-23
   The panel.mode_proxy_description and panel.mode_tunnel_only_description strings are
   shipped untranslated in every non-English locale (all 13 files carry the identical
   English text at the same two lines: de, es, fr, hu, it, ja, ku, nl, pl, pt, ru, tr,
   uk-UA, vi, zh-CN). The panel renders these as the description under the mode selector
   (warp/panel.luau:35-42), so users of non-English locales see English copy when the
   proxy or tunnel-only mode is selected. Translate the two strings in each locale, or
   accept the English fallback. No key-parity or schema issue: the validator checks all
   locale files pass, so this is a translation completeness concern only.
```

No blocking findings. The thumbnail concern raised in the discussion thread was checked
against the asset itself and does not hold: the file is a 960x540 WebP (48,502 bytes),
which is exactly the thumbnail generator's export size enforced by the repository
validator (THUMBNAIL_SIZE = (960, 540), under the 512 KiB limit), and visual inspection
confirms a clean, readable branded hero image consistent with the generator's output.

## PR

PR #520: https://github.com/noctalia-dev/community-plugins/pull/520

Reviewed PR head SHA: 8b4929c9f27148ce10aee279d930e3042af2b3d7
Base main SHA (latest remote main at review time, merged cleanly): 7a772f2675f2fab6b81ebb00edf572262f52352b
PR baseRefOid (branch point): caed21ab081948435cd770d2e954c99b8bbb72cf

## Validation

- Repo validator on the head-into-main merge: PASS, "Validated 125 plugin manifest(s)."
- Validator unit tests on the merge: PASS, 79 tests, OK.
- CI check on the PR head: validate, SUCCESS.
- No clean-main baseline run was needed: the merge passed both validator and tests, so
  there are no pre-existing base failures to attribute.

## Asset inspection

- thumbnail.webp: 960x540 WebP, 48,502 bytes, exactly the generator-export size enforced
  by the validator; vision inspection confirms a readable branded hero image titled
  "Cloudflare WARP" with subtitle "Control WARP from your Noctalia desktop" and tag
  "Network Privacy". Relevant and consistent with the plugin description.
- All required files present (plugin.toml, README.md, thumbnail.webp,
  translations/en.json), plus LICENSE (MIT) and 13 additional locale files. The
  validator's format, dimension, size, required-file, symlink, README, and Luau API
  checks all pass. The warp directory name matches the id suffix, and the manifest
  declares the warp-cli dependency.

## Security screen

- Subprocesses: spawns warp-cli only, via a fixed CLI prefix; the sole interpolated
  argument is the mode, which is validated against a hardcoded whitelist before use.
  No shell metacharacter or user-controlled interpolation risk.
- Network: no HTTP requests, downloads, or remote code loading in the plugin code; WARP
  connectivity is the documented job of the warp-cli dependency.
- Filesystem: no file reads, writes, deletes, or path traversal; only in-memory plugin
  state (noctalia.state) and subprocess output are used.
- Credentials/secrets: none accessed.
- Dynamic code/obfuscation: none; plain, readable, non-minified Luau.
- Behavior matches the stated purpose (status/settings/stats queries plus connect,
  disconnect, and mode actions). No unsafe or deceptive behavior found.

## Checklist gate

Non-draft PR. Exactly one of "New plugin" and "Update to an existing plugin" is checked,
at least one compositor testing item is checked (Hyprland), and every item under
Checklist and Code review attestation is checked. No gate violation.

## Verdict

ready

This was a bounded community-plugin review focused on the acceptance gate, assets,
manifest, and security screen, not an exhaustive functional verification of the plugin
logic.
