## [1.1.0] - 2026-10-26

### Added
- **Reboot Required Detection**: Detects pending system restart via `dnf needs-restarting -r` with warning banner in panel and widget status indicator.
- **Package Search Filter**: Search bar to filter pending DNF and Flatpak packages by name, repository, or runtime.
- **Header Overview**: Relative last check and last full upgrade timestamps in panel header.
- **Weekly Check Interval**: Extended check interval limit up to 7 days (10080 min).
- **Terminal Confirmation**: Added `-y` flag to terminal updates for promptless execution.

### Fixed
- **Badge Overflow**: Truncated COPR repo names, suppressed redundant native arch and official Fedora repo badges, and capped badge width.
- **State Persistence**: Cached check results in `pluginDataDir()` across restarts to prevent redundant checks on login.
- **Terminal Update Sync**: Triggered auto-recheck via IPC when terminal updates complete, and closed panel on launch.

## [1.0.3] - 2026-10-06

### Added
- **Plugin Version in Header**: Display installed version next to panel title in `panel.luau`.
- **Flatpak Runtime Updates**: Added `include_flatpak_runtimes` setting and row badge in `panel.luau`.

### Fixed
- Fixes noctalia-dev/community-plugins#922: **Flatpak Ghost Updates**: Added `--app` flag to `flatpak remote-ls --updates` to filter unmatched theme extensions and EOL runtimes.
- **Flatpak Selection Crash**: Defined `flatpakCount` scope in `updateFlatpak()` to fix nil comparison crash and infinite loading.
- **Background Upgrade Protection**: Raised background transaction timeout to 10m and wrapped helper with `systemd-inhibit` to prevent SIGKILL and mid-upgrade aborts.
- **Flatpak Parameter Limits**: Removed duplicate Flatpak refs, relaxed validation, and simplified full updates.
- **Timeout Error Reporting**: Added `result.timedOut` handling to DNF and Flatpak update errors advising terminal execution.

## [1.0.2] - 2026-09-22

### Added
- **Installer Script for passwordless background updates**: Added `scripts/install.sh` for remote/local install, group checks (`wheel`/`sudo`), SELinux restore, and uninstallation.

### Fixed
- **Check Retry**: Retried DNF/Flatpak checks once when they time out.
- **Stream Exclusions**: Fixed exclusions for RPM modules and epochs containing colons.
- **Polkit Compatibility**: Added support for both `wheel` and `sudo` groups.
- **Error Capture**: Captured DNF error output when `stderr` is empty.

## [1.0.1] - 2026-09-21

### Security
- **Helper**: Restricted privileged DNF commands to supported operations.
- **Input Validation**: Added validation for DNF package names and Flatpak refs.
- **Shell Quoting**: Safely escaped dynamic terminal arguments.

### Fixed
- **Terminal Updates**: Combined DNF and Flatpak updates into one terminal session.
- **Flatpak Updates**: Fixed full Flatpak updates to include runtimes.
- **Size Parsing**: Improved Flatpak update size parsing.
- **Package Keys**: Fixed inconsistent Flatpak package keys.

## [1.0.0] - 2026-09-19

### Added
- Initial release of DNF Updater.
- DNF5 and Flatpak update monitoring and management.
- Flyout panel with package selection and size estimation.
- Terminal and passwordless Polkit background update modes.
- Status bar widget with update count badges and indicators.
