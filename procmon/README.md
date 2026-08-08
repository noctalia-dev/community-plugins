# Process Monitor

A bottom-style process monitor for Noctalia: live CPU/RAM/swap bars and a
sortable, searchable process table with a per-process kill action, all in a
panel. Great for spotting a runaway process or a zombie and killing it without
opening a terminal.

## Plugin

| Field   | Value                                                    |
| ------- | -------------------------------------------------------- |
| ID      | `weinguyen/procmon`                                      |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service` |

## Requirements

Install `ps` and `kill` on `PATH` (both are present on virtually every Linux
distribution).

## Usage

Add the **Process Monitor** widget to a bar. It shows the current CPU and RAM
usage (plus the process count). Click the widget to toggle the process panel:

```sh
noctalia msg panel-toggle weinguyen/procmon:panel
```

The panel shows CPU, RAM and swap bars with the 1/5/15-minute load averages,
then a process table. Sort by the column dropdown (PID, CPU%, MEM%, RSS,
COMMAND) and flip asc/desc with the arrow button. Type in the filter box to
match a process by name, user or PID. Click the ✕ button on a row to run the
configured kill command against that PID (default `kill -TERM`). Zombie
processes are tinted with the error color so they stand out.

The table refreshes on the interval set in the `refresh_interval` setting. The
panel re-renders automatically as new samples arrive, so the view stays live
while it is open.

## Settings

| Setting            | Type     | Default      | Description                                                                                |
| ------------------ | -------- | ------------ | ------------------------------------------------------------------------------------------ |
| `refresh_interval` | `int`    | `2000`       | Process resample interval in milliseconds.                                                 |
| `sort_by`          | `select` | `cpu`        | Initial sort column when the panel opens (`cpu`, `mem`, `pid`, `cmd`).                     |
| `kill_command`     | `string` | `kill -TERM` | Command run against a selected PID; the PID is appended. Empty falls back to `kill -TERM`. |
| `show_count`       | `bool`   | `true`       | Bar widget also shows the total process count.                                             |

## Notes

- **Spawns processes.** A background service runs `ps` on every refresh
  interval and `runAsync` runs the configured `kill_command` when a row's ✕ is
  clicked. There is no confirmation dialog, so check the PID before clicking.
- The bar widget and panel never run commands themselves; they only render the
  data the service publishes.
- Requires `plugin_api = 12`. CPU% and RAM% bars are derived from the summed
  per-process values in the `ps` output, so they work with no system monitor
  dependency. Swap and load-average readouts show `—` for now.
