# Changelog

All notable changes to Keymap are documented in this file.

## [1.5.0] - 2026-08-10

### Added

- New `merge_similar` setting: shortcuts that trigger the same action (for
  example "Close Window" on Super+W and Alt+F4) collapse into a single
  read-only row listing every key combination.

### Fixed

- Fixed panel stuck on "Loading keybindings" after reopening: refreshes were
  replaying the full request backlog. Refresh execution is also deferred
  from the 25 ms state-watch callback into the service's own update tick, so
  a parse can no longer be aborted by a shared callback budget mid-flight;
- Fixed missing debugging logs/errors: Internal parser errors now surface their
  actual Lua error text on the error panel instead of an opaque "unknown error";
- Fixed `show_undescribed=false` option, which now also hides Niri binds whose
  `hotkey-overlay-title` is missing, empty (`""`), or `null` values;
- Fixed `merge_sequential` option, which now correctly merges numbered runs (such
  as Workspace 1–9);
- Fixed long keybindings being replaced with a single merged keybind.
- Enabled safe in-place editing of the program and arguments in ordinary Niri
  `spawn` actions without converting them to shell commands, and added a clear
  explanation for native actions that remain read-only.

### Changed

- Unified the key display-name tables across Hyprland, Niri, and MangoWC so
  the same key reads identically for every compositor (including missing
  `XF86Calculator`, `XF86Mail`, touchpad scrolls, and punctuation).

### Tests

- Added `coroutine_slice_test.lua` and `parser_lifecycle_test.lua` covering
  bounded parser resumes, multi-tick completion, and stale-generation
  cancellation.
- Added `niri_scanner_test.lua` covering the rewritten scanners against a
  reference corpus and fuzzed inputs.
- Added `niri_settings_test.lua` covering sequential merging,
  undescribed-title filtering, similar-action merging, refresh-watcher echo
  suppression, and editable native `spawn` detection.
- Added `merge_similar_test.lua` covering MangoWC and Hyprland similar-action
  merging plus Hyprland watcher echo suppression.
- Extended writer tests with merged-combination conflict detection and safe
  native Niri `spawn` updates, validation failures, and rollback.

## [1.3.4] - 2026-07-29

### Fixed

- Prevented Niri startup CPU-budget failures on large, split configurations.
- Prevented Hyprland refreshes from exhausting the callback CPU budget and
  leaving the shortcut snapshot stuck in its loading state.
- Restored editing for literal native-Lua binds after the optimized refresh.

### Changed

- Skipped the hidden-bind scan for files without Keymap hidden sentinels.
- Skipped character-level parsing for included files that cannot contain binds
  or nested includes.
- Added fast paths for common Hyprland Lua literals and dispatcher expressions.
- Switched active Hyprland source validation to exact snippet comparison while
  retaining legacy fingerprints for hidden blocks and older snapshots.

### Tests

- Added a 127-bind split-config regression with a large unrelated include.
- Added a split native-Lua regression covering invalid Hyprland JSON fallback,
  callback instruction budgets, and editable source provenance.

## [1.3.1] - 2026-07-21

### Fixed

- Prevented startup timeouts while parsing larger Niri, Hyprland, and MangoWC configurations.
- Prevented intermittent callback timeouts when rapidly switching keyboard modifier layers.

### Changed

- Accelerated stable fingerprints with Luau's native `bit32` operations while retaining a plain-Lua fallback.
- Avoided reading Niri's root configuration twice during a refresh.
- Made loading snapshots lightweight instead of serializing the previous bind tree again.
- Cached panel translations, settings, keyboard indexes, colors, and dynamic key callbacks between renders.

### Tests

- Added 93-bind scale regressions for Niri, Hyprland, and MangoWC.
