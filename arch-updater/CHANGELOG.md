# Changelog

All notable changes to Arch Updater are documented here. The panel's changelog
icon (the history icon next to Check) shows this same file.

## 2.0.2 - 2026-08-28

- Fixed: Update in terminal mode always failed on the Flatpak step, auto-declining its confirmation prompt with "n" (exit 1) even when nothing was typed. flatpak's prompt refuses to be interactive once its stdout isn't a real terminal, which is the case here since the whole run is piped into `tee` for the log; pacman/AUR prompts aren't affected by this. The Flatpak step now runs non-interactively (`-y --noninteractive`) in terminal mode too, same as background mode already did; pacman/AUR review stays fully interactive.

## 2.0.1 - 2026-08-21

- Added: a changelog view in the panel. Click the history icon next to Check to see what changed in each release. It also opens automatically once an update finishes, unless turned off in settings (Show changelog after updating).
- Fixed: hitting Update in terminal mode now closes the panel right away, instead of leaving it open with nothing left to show.
- Fixed: closing the terminal window before an update finished left the panel stuck showing "Updating in a terminal window…" forever. The engine now notices the terminal is gone and reports the run as failed, with the usual retry option.

## 2.0.0 - 2026-08-19

- Added: an update mode setting. Run updates in a terminal window like before, or fully in the background with a live log, progress bar and one polkit password for the whole run.
- Added: an Ignored section in the panel to see and manage packages held back by pacman.conf's IgnorePkg or the plugin's own ignore list.
- Added: update history with per-package and whole-run rollback, resolved against the pacman/AUR cache.
- Added: an opt-in activity graph tracking pending-update counts across recent checks.
- Fixed: the Arch news check re-firing every few seconds after the first run, which could get the whole plugin auto-disabled shortly after login.
- Fixed: pacman's translated "[ignored]"/progress lines breaking the pending count and progress bar on non-English systems.

## 1.1.0 - 2026-08-08

- Added: per-source icons in the package list header.
- Added: an activity graph showing pending-update counts over time, with per-point hover detail.
- Fixed: Dismiss now actually clears the pending list, and hitting Update closes the panel.
- Fixed: tightened package list spacing and icon sizing.

## 1.0.1 - 2026-08-04

- Fixed: reduced CPU work in the Arch news HTTP callback.

## 1.0.0 - 2026-07-28

- Initial release: check pacman, AUR and Flatpak for updates from the panel and the bar widget.
