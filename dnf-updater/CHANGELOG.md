## [1.0.1] - 2026-09-21

### Security
- **Scoped Privileged Helper for Passwordless Upgrades**: Replaced the unrestricted `pkexec dnf5` Polkit rule with a dedicated, hardened privileged helper (`scripts/dnf-updater-helper.sh`) and scoped Polkit rule (`polkit/50-dnf-updater.rules`). The helper strictly enforces that only `upgrade` operations with validated `--exclude` arguments can be executed as root, eliminating arbitrary root execution while preserving passwordless background updates as an optional feature.
- **Dynamic Argument Validation**: Added strict identifier validation for DNF package names (`isValidPackageName`) and Flatpak application IDs / refs (`isValidFlatpakId`) to reject invalid characters and prevent flag or command injection.
- **Shell-Safe Argument Quoting**: Added `shellQuote` escaping for all dynamic arguments passed into `noctalia.runInTerminal()`.

### Fixed
- **Flatpak Update Execution in Terminal**: Chained DNF and Flatpak commands sequentially in a single terminal session (`sudo dnf5 upgrade ... && flatpak update ...`) when "Update All" runs with `update_in_terminal = true`, resolving an issue where back-to-back terminal launches caused Flatpak updates to be dropped.
- **Flatpak Update Scope & Ref Resolution**: Updated `flatpak update` invocation to run without package arguments when all pending Flatpak updates are selected (ensuring runtimes and dependencies update cleanly), and accurately target explicit refs when a subset is selected.
- **Total Estimated Update Size**: Added `parseSizeToBytes` and `getPackageDownloadBytes` to parse GLib/Flatpak formatted size strings (accounting for UTF-8 non-breaking spaces and SI/IEC units), correctly incorporating Flatpak download sizes into the total size badge, panel headers, and widget tooltips.
- **Panel Package Key Consistency**: Standardized Flatpak package keys across selection toggles, row click handlers, and exclusion filters using `getFlatpakKey`.

## [1.0.0] - 2026-09-19

### Added
- Initial release of DNF Updater.
- Monitoring for DNF5 system packages and Flatpak application updates.
- Interactive panel with per-package inclusion/exclusion.
- Download and installed size estimations.
- Terminal execution mode and background Polkit execution mode.
- Bar widget with badge counts and status indicators.
