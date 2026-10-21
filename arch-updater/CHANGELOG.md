# Changelog

All notable changes to Arch Updater are documented here. The panel's changelog
icon (the history icon next to Check) shows this same file.

## 2.1.0 - 2026-10-21

- Added: config file review. When a check or a finished update finds pacman's `.pacnew`/`.pacsave` files, a Review line appears in the panel (and a badge on the bar widget). Each `.pacnew` opens a 3-way merge: your file, the package's new default, and the previous default pulled from the pacman cache. Changes only one side made are merged automatically; a region both sides touched becomes a conflict with a Keep mine / Take new / Keep both switch. Preview the result, then apply — the write goes through one polkit prompt, keeps the file's owner and mode, backs the file up first, and removes the `.pacnew`. Also: Take new as-is, Discard new, Restore/Remove for `.pacsave`, an external-tool hook (pacdiff or your own, e.g. meld), and an opt-in sweep of `.pacnew` files identical to the live file. Eleven settings under "Config file review", plus a widget toggle.
- Added: terminals opened by the plugin now carry the app id `arch-updater` and a fixed title per job (`Arch Updater - Update`, `- Log`, `- Config`) instead of a generic "sh", so compositor window rules can target them, e.g. to float the update window. Set through the emulator's own flags for kitty, foot, alacritty, Ghostty (`dev.noctalia.arch-updater`), wezterm and xterm, and for `$TERMINAL` too when the Terminal setting is empty; the title is also set by escape sequence for every other emulator. kitty and foot are now launched without the `-e` they don't accept. See "Window rules for the terminal" in the README.
- Changed: expanding a source's package list now hides the activity graph and the update-history strip until you collapse it again, so the list gets that vertical space back while you're reading it. The "checked HH:MM" caption stays.
- Fixed: in terminal update mode, pacman/paru's own download/install progress bar sat static on "downloading packages…"/"installing packages…" until the whole run finished, because tee'ing the run into the update log gave pacman a plain pipe instead of a terminal on its own stdout. The run now goes through `script` first, so pacman still sees a real terminal and its progress bar animates as usual, while the log still gets the same output through `tee`. Two follow-ups: the panel's live log keeps only what that redrawing bar finally shows, so its long `\r` lines no longer trip the script's CPU budget ("exceeded its CPU budget" in noctalia.log); and the wrapped run always uses `/bin/sh`, so it also works when your login shell is fish or nu.
- Fixed: the Flatpak update never ran when the pacman/AUR step failed (one AUR package that won't build, or answering "n" to its prompt), so it could stay skipped indefinitely. Each step now runs regardless; the run is still reported as failed with the failing step's exit status.

## 2.0.3 - 2026-09-03

- Fixed: a background update killed or crashed without writing its exit marker left the panel stuck on "Updating…", even across logins. The engine now spots a run whose log has stopped growing, clears it, and offers the usual retry. Terminal runs, which may legitimately sit idle at a prompt, are unaffected.
- Fixed: the changelog could not be opened while an update was running. It now opens mid-update, and the back button returns to the live log.
- Fixed: long changelog entries were clipped at three lines. They now wrap in full.
- Fixed: the "Custom update command" setting was ignored in terminal update mode (the default); since 2.0.0 it only applied to background updates. It now takes effect in both modes, as it did before 2.0.0.

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
