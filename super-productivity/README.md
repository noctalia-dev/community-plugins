# Super Productivity

Use Super Productivity from the Noctalia bar: see the next due task, inspect it, capture tasks with Super Productivity's enabled Short Syntax forms, track time, reschedule, complete, undo, and open the exact task in the desktop app.

## Plugin

| Field | Value |
| --- | --- |
| ID | `redxtech/super-productivity` |
| Entries | Bar widget: `next-task`; panel: `details`; service: `service`; launcher provider: `capture` |
| Launcher Prefix | `/sp` |

## Requirements

- Super Productivity desktop 18.19.0 or newer.
- `python3` must be Python 3.11 or newer with `zlib` support; it builds the companion package from its bundled readable source.
- `xdg-open` opens the generated package directory from the panel.
- `flatpak` is optional and is used only when Super Productivity is installed as a Flatpak.
- Super Productivity must be able to read and write its application data directory.

The companion requests Super Productivity's `nodeExecution` permission. This permission gives the companion filesystem access under your user account. Review `companion/plugin.js` before granting it.

## How to connect Super Productivity

1. Install `redxtech/super-productivity` from the Noctalia plugin source.
2. Add the `next-task` widget to a Noctalia bar and open its details panel.
3. Select **Build companion package**.
4. Select **Open package folder** after the build completes.
5. Open Super Productivity.
6. Open **Settings → Plugins → Choose Plugin File**.
7. Select `noctalia-super-productivity.zip` from the generated package directory.
8. Enable **Noctalia Super Productivity Companion**.
9. Approve its desktop file-access prompt.
10. Return to the Noctalia details panel and select **Refresh**.

The plugin generates the ZIP only when you request it. The readable companion source remains in `companion/`, while the generated package and its metadata are stored under:

```text
$XDG_DATA_HOME/noctalia-super-productivity/
```

When `XDG_DATA_HOME` is unset, the directory is `~/.local/share/noctalia-super-productivity/`. After a companion update, select **Rebuild package** and reinstall the generated ZIP in Super Productivity.

The included packager can validate the bundled sources and build the deterministic archive in memory without writing files:

```sh
python3 scripts/package-companion.py --check
```

The panel is also available directly:

```sh
noctalia msg panel-toggle redxtech/super-productivity:details
```

## Usage

### Widget

- **Left click:** open the task details panel.
- **Right click:** complete the displayed task and, when `sound_on_complete` is enabled, play the completion sound after Super Productivity confirms completion.
- **Middle click:** launch or focus Super Productivity and open that exact task.
- **Scroll:** move through due tasks. If a task timer is running and `prefer_tracked_task` is enabled, the tracked task is first.

The details panel provides timer controls when `show_timer_controls` is enabled, `+1 hour`, `Tomorrow`, and `Next week` rescheduling actions, quick capture, undo, and diagnostics.

### Quick capture

In the panel, enter task text and press Enter or select **Add**. In the Noctalia launcher, type `/sp` followed by the task text, then activate the **Add** result to create the task. With no task text, activate **Open Super Productivity** to launch or focus the desktop app.

The companion passes the task text to `PluginAPI.addTask()`. Super Productivity parses the short-syntax forms enabled in its settings; disabled forms remain in the task title. Recurrence syntax such as `@every friday` is only supported in Super Productivity's own Add Task Bar, not through this plugin.

Examples:

```text
/sp Prepare release +Work #urgent @tomorrow 10am 45m
/sp Water plants @friday 15m
/sp Investigate issue 30m/2h
```

Super Productivity can ask for confirmation when short syntax creates a new tag. Open the desktop app to answer that prompt.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `auto_start` | `bool` | `false` | Starts the desktop app when it is not running and no live companion is detected. |
| `launch_method` | `select` | `auto` | Uses Flatpak, a native executable, or automatic detection. |
| `native_command` | `string` | `superproductivity` | Native executable name or absolute path. Arguments are not accepted. |
| `bridge_dir` | `string` | empty | Overrides automatic discovery of the companion data directory. |
| `poll_seconds` | `int` | `2` | Sets the filesystem snapshot polling interval from 1 to 30 seconds. |
| `prefer_tracked_task` | `bool` | `true` | Places the current timer task before due tasks. |
| `show_timer_controls` | `bool` | `true` | Shows timer controls in the details panel. |
| `sound_on_complete` | `bool` | `true` | Plays Super Productivity's default `sounds/ding-small-bell.mp3` after confirmed completion. |
| `notify_due` | `bool` | `false` | Notifies when a displayed task crosses its due time while the service is running. |
| `overdue_text_color` | `color` | `error` | Sets overdue task text color in the bar widget and details panel. |
| `max_upcoming` | `int` | `30` | Limits the widget's scrollable task list to between 5 and 50 tasks. |
| `glyph` | `glyph` | `checks` | Selects the widget icon. |
| `show_due_text` | `bool` | `true` | Shows relative due text in the widget. |
| `max_title_chars` | `int` | `36` | Limits the displayed widget title to between 12 and 80 characters. |

## Notes

The companion writes a local snapshot that can contain task titles, notes, project and tag names, due dates, time estimates, time spent, and the current tracked task. Its snapshot, connection, error, and response JSON files are written with user-only file permissions under the discovered or configured bridge directory. The plugin does not send this data over the network.

Granting the companion's `nodeExecution` permission allows it to run code with your user account's filesystem and process access. Noctalia writes command files to the bridge directory, the companion writes response files there, and Noctalia writes the generated companion package under `$XDG_DATA_HOME/noctalia-super-productivity/`.

The completion sound is Super Productivity's default `ding-small-bell.mp3`, sourced from the upstream repository. Its source and license are recorded in `THIRD_PARTY_LICENSES.md`.

## Behavior and limitations

- The widget includes active, incomplete tasks with a scheduled date or time. Timed tasks use their exact timestamp, date-only tasks are due at the end of their local calendar day, and earlier tasks appear first. Parent tasks and subtasks are both eligible.
- When `prefer_tracked_task` is enabled, the current tracked task appears before scheduled tasks. After the companion is installed or reloaded, it may not learn the current task until the tracked task changes.
- Mutating commands expire after 12 seconds and are not automatically retried. If task creation or completion times out, check Super Productivity before trying again because the action may have succeeded.
- Undo is available for 30 seconds and only during the current Noctalia service runtime. Due notifications are not replayed for deadlines missed while Noctalia was stopped.

## Troubleshooting

1. Open the panel's **Diagnostics** section.
2. Confirm that the status is **Connected** and the protocol is `1`.
3. Copy the bridge directory and check that it contains `snapshot.json`.
4. Re-enable the companion if Super Productivity's file-access prompt was denied.
5. Select **Rebuild package** and reinstall the generated ZIP after a companion update.
