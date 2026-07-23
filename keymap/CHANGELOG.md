# Changelog

All notable changes to Keymap are documented in this file.

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
