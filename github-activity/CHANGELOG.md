# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog 1.0.0](https://keepachangelog.com/es-ES/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Per-widget controls for showing only the GitHub icon or pairing it with
  today's contributions, the current streak, or the annual contribution total.

## [1.2.1] - 2026-08-25

### Fixed

- Localized the calendar's month labels, weekday labels, and preparation state.

## [1.2.0] - 2026-08-25

### Added

- Last-update and automatic-refresh feedback in the calendar panel and widget
  tooltip.

### Fixed

- Render widget tooltip line breaks instead of literal `\\n` text.

## [1.1.0] - 2026-08-25

### Added

- Configurable automatic contribution refresh interval with 15-, 30-, and
  60-minute options.

## [1.0.0] - 2026-08-24

### Added

- Initial release of GitHub Activity for Noctalia v5.
- Native bar widget with today's contribution count and manual refresh.
- Theme-aware, interactive annual contribution calendar with per-day details.
- Today, current streak, best streak, and annual contribution metrics.
- GitHub CLI-based authenticated data retrieval and credential-free offline cache.
- Standalone Luau coverage for contribution parsing and streak calculations.
