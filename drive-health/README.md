# Drive Health

Drive Health is a storage-health monitor for Noctalia Shell. It discovers SSDs
and HDDs, shows temperature and mounted-space usage, and can optionally expose
full SMART health, endurance, error counters, trends, alerts, and background
self-tests through a read-only system collector.

## Plugin

| Field | Value |
| --- | --- |
| ID | `gustav0ar/drive-health` |
| Entries | Bar widget: `summary`; panel: `drives`; services: `collector`, `alerts`, `history` |

## Requirements

Drive Health runs on Linux with Noctalia Shell v5 and uses the following
commands declared in `plugin.toml`:

`lsblk`, `smartctl`, `sh`, `date`, `dirname`, `mkdir`, `mktemp`, `rm`, `sed`,
`cat`, `chmod`, `mv`, `sudo`, `env`, `bash`, `install`, `systemctl`, `pkexec`,
`id`, and `tr`.

Most are standard system utilities. Install `smartctl` from the
`smartmontools` package and `lsblk` from `util-linux`. `systemctl`, `sudo`, and
`pkexec` are needed only for the optional collector and SMART self-tests.

The dependency card can open a terminal with a package-manager command for
`pacman`, `apt-get`, `dnf`, `zypper`, `apk`, `xbps-install`, or `emerge`. The
command is shown for review before any privileged prompt.

## Usage

Enable Drive Health from Noctalia's community source, then add the `summary`
widget to a bar. Select the widget to open the drives panel. The same panel can
be toggled with:

```sh
noctalia msg panel-toggle gustav0ar/drive-health:drives
```

Basic mode discovers drives, mounted folders, storage use, and temperatures
available to the user session. Open the collector controls from the gear in
the panel header to compare basic mode with optional Full SMART mode.

Full SMART installation always opens a terminal with the exact command. After
the user reviews and approves `sudo`, the installer adds a hardened systemd
oneshot and timer. Disabling Full SMART in settings makes Drive Health ignore
the collector cache; use **Stop background service** to stop an installed
timer as well.

Expand a drive for detailed counters, trend history, per-drive preferences,
and SMART self-tests. A self-test requires explicit confirmation and a Polkit
authorization prompt, then runs in the background while progress and its final
firmware result appear in the panel. Sleeping HDDs are not spun up merely to
refresh their SMART data.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `system_collector_enabled` | `bool` | `false` | Read the optional root collector cache for complete SMART data. |
| `refresh_seconds` | `int` | `30` | Seconds between user-session refreshes (15–300). The root timer independently refreshes every 30 seconds. |
| `warning_temperature` | `int` | `65` | Global warning temperature in °C. |
| `critical_temperature` | `int` | `80` | Global critical temperature in °C. |
| `life_warning_percent` | `int` | `20` | Remaining SSD-life percentage that triggers a warning. |
| `alerts_enabled` | `bool` | `true` | Show notifications for new or worsening issues. |
| `notify_recovery` | `bool` | `true` | Notify when an active issue clears. |
| `show_hdd` | `bool` | `true` | Include rotational drives in the panel. |
| `alert_hdd` | `bool` | `true` | Evaluate rotational drives for health alerts. |
| `drive_missing_alerts` | `bool` | `true` | Alert when an established internal drive disappears. |
| `missing_grace_scans` | `int` | `3` | Successful scans a drive may be absent before alerting (1–20). |
| `use_hotspot_temperature` | `bool` | `true` | Use the hottest valid NVMe sensor for summaries and alerts. |
| `history_interval_minutes` | `int` | `60` | Minutes between saved trend samples (15–1440). |
| `history_retention_days` | `int` | `30` | Days of bounded trend history to retain (1–365). |

Per-drive controls can set an alias and alert thresholds, reorder or hide a
drive, and enable missing-drive alerts. Dismissed alerts are dropped and only
return when the condition clears and later recurs or escalates.

## IPC

The normal public entry is the panel command above. The plugin's internal
services communicate through Noctalia state and do not require manual IPC.

## Notes

Drive Health makes no network requests and does not download or execute code.
It spawns only the commands documented under Requirements. Conditional
package-manager commands are generated locally and opened in a terminal for
review.

The plugin stores bounded local state in its Noctalia data directory:

- `alert-state.json` for current and dismissed alert state;
- `history.json` for temperature and endurance samples;
- `drive-preferences.json` for per-drive display and alert preferences;
- `last-collector-snapshot.json` for monotonic-counter comparisons.

Full SMART mode installs these system files only after explicit approval:

- `/usr/local/libexec/noctalia-gustav0ar-drive-health/collect_raw.sh`;
- `/usr/local/libexec/noctalia-gustav0ar-drive-health/smart-action.sh`;
- `/etc/systemd/system/noctalia-gustav0ar-drive-health.service`;
- `/etc/systemd/system/noctalia-gustav0ar-drive-health.timer`;
- `/run/noctalia-gustav0ar-drive-health/raw.json`.

The runtime directory is mode `0750`, the cache is mode `0640`, and access is
limited to root plus the desktop user's primary group. SMART serials and mount
paths stay inside the local cache and panel; they are never transmitted.

The system collector performs read-only `smartctl --all` queries. SMART
self-tests are separate, explicitly authorized firmware operations. They can
take minutes or hours, may increase drive activity, and should not be confused
with filesystem repair or data recovery.

To remove the optional collector, use **Remove collector** in its controls and
approve the terminal command. Removing the Noctalia entry alone does not
silently remove system files.

## Development

Run the unit, shell, translation, lint, privacy, and packaging checks from this
directory:

```sh
make test
```

This source is licensed under the MIT License.
