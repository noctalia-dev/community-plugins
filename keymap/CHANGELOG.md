# Changelog

All notable changes to Keymap are documented in this file.

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
