## [1.0.3] - 2026-10-06

### Added
- **Plugin Version in Header**: Display installed version next to panel title in `panel.luau`.
- **Flatpak Runtime Updates**: Added `include_flatpak_runtimes` setting and row badge in `panel.luau`.

### Fixed
- **Flatpak Ghost Updates**: Added `--app` flag to `flatpak remote-ls --updates` to filter unmatched theme extensions and EOL runtimes.
- **Flatpak Selection Crash**: Defined `flatpakCount` scope in `updateFlatpak()` to fix nil comparison crash and infinite loading.
- **Background Upgrade Protection**: Raised background transaction timeout to 10m and wrapped helper with `systemd-inhibit` to prevent SIGKILL and mid-upgrade aborts.
- **Flatpak Parameter Limits**: Deduplicated ref parameters, relaxed ref regex validation, and bypassed arguments on full updates.
- **Timeout Error Reporting**: Added `result.timedOut` handling to DNF and Flatpak update errors advising terminal execution.

## [1.0.2] - 2026-09-22

### Added
- **Installer Script**: Added `scripts/install.sh` for remote/local install, group checks (`wheel`/`sudo`), SELinux restore, and uninstallation.

### Fixed
- **Check Retry**: Added single-retry on DNF/Flatpak check timeouts to prevent transient error badges during cache refreshes.
- **Stream Exclusions**: Supported colons in `scripts/dnf-updater-helper.sh` exclusion regex for RPM modules and epochs.
- **Helper Script**: Set bash shebang and added `-h`/`--help` usage flags to helper script.
- **Polkit Compatibility**: Allowed both `wheel` and `sudo` groups with standard `NOT_HANDLED` fallback in Polkit rule.
- **Error Capture**: Captured `stdout` on failed DNF transactions when `stderr` is empty.

## [1.0.1] - 2026-09-21

### Security
- **Helper**: Replaced broad `pkexec dnf5` with scoped `scripts/dnf-updater-helper.sh` restricted to upgrade and validated exclusions.
- **Input Validation**: Added strict validation for DNF package names and Flatpak refs to prevent command injection.
- **Shell Quoting**: Added `shellQuote` escaping for dynamic arguments passed to terminal runner.

### Fixed
- **Terminal Updates**: Chained DNF and Flatpak commands in single terminal session during Update All.
- **Flatpak Update Scope**: Omitted package arguments when updating all Flatpaks to ensure runtimes update cleanly.
- **Size Parsing**: Added `parseSizeToBytes` to accurately parse Flatpak byte units and non-breaking spaces.
- **Package Key Consistency**: Unified Flatpak package keys across toggles, click handlers, and exclusion filters.

## [1.0.0] - 2026-09-19

### Added
- Initial release of DNF Updater.
- DNF5 and Flatpak update monitoring and management.
- Flyout panel with package selection and size estimation.
- Terminal and passwordless Polkit background update modes.
- Status bar widget with update count badges and indicators.
