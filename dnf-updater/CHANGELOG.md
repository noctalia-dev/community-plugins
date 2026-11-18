## [1.2.0] - 2026-11-12

### Added
- **Disk Space Impact**: Tooltip now displays the real disk space added or freed by updates alongside the download size.
- **Last Updated Time**: Moved last update time from panel to tooltip.
- **Refresh Metadata Setting**: Added an optional `refresh_on_update` setting to refresh DNF cache before upgrading (#7).

### Fixed
- **Replaced Packages Count**: Fixed packages that replace older versions (like `kernel-headers`) not showing up in the update list.
- **Multi-arch Packages**: Fixed size and selection issues when both 32-bit and 64-bit versions of a package are installed.
- **Faster Checks**: Update checks now use local cache directly, which finishes faster.
- **Cleaned Up Skipped Packages**: Unchecked packages are now reset when updates change instead of staying skipped forever.
- **Panel Header**: Removed redundant timestamps to cleanup panel.
- **Last Update Memory**: Fixed last update time being lost when restarting the shell without checking (#6).

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
