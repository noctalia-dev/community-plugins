# Local agent instructions

These instructions are local to this checkout and are not part of the public
repository. Follow the user's request before changing any of the constraints
below.

## Plugin contracts

- Preserve the plugin identifier `alexmnrs/github-activity`, minimum plugin API
  `24`, and the `activity` widget, `calendar` panel, and `sync` service entries
  unless the user explicitly asks to change the public plugin contract.
- Preserve the data flow: `gh api graphql` → validation and normalization →
  shared Noctalia state → credential-free local cache.
- Never read, write, display, log, or add configuration for GitHub tokens.
- Keep cached data backward-compatible. If its format needs to change, provide
  a safe migration or retain compatibility with existing caches.

## Change discipline

- Treat `github-activity/lib/activity.luau` as the source of truth for
  contribution levels, streak calculations, and cache validation.
- Update `tests/activity_spec.luau` whenever activity parsing, normalization,
  streaks, levels, or cache compatibility changes. Run
  `luau tests/activity_spec.luau` after such changes.
- Keep `plugin.toml`, `catalog.toml`, translations, and both READMEs consistent
  whenever public metadata, dependencies, behavior, or user instructions
  change.
- Preserve the theme-aware Noctalia UI, the non-blocking grid construction,
  and meaningful loading, offline, authentication, and error states. Consult
  `DESIGN.md` before making visual or interaction changes.
- Record user-visible changes under `Unreleased` in `CHANGELOG.md` using its
  Keep a Changelog categories. Do not use it as a per-commit work log.

## Noctalia settings

- Read only settings declared in `plugin.toml` through `noctalia.getConfig`.
  Do not use `noctalia.getSetting`, which requires plugin API 26; retain API 24
  unless a requested capability actually requires a higher level.
- Put settings used by the service in root-level `[[setting]]` blocks, per-bar
  presentation choices in `[[widget.setting]]` blocks, and panel-only choices
  in `[[panel.setting]]` blocks.
- Every setting must use `label_key` (never literal labels). Add every label,
  description, and select-option key to `translations/en.json`.
- Reload Noctalia configuration after modifying `plugin.toml`; Luau hot reload
  alone does not pick up manifest changes.
- When preparing a change for `noctalia-dev/community-plugins`, bump the
  plugin's semantic version and update its README and changelog. Include a
  visual capture for a visible UI change.
