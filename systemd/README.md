# Systemd Units

Fuzzy-find systemd units from the launcher and start, stop or restart them.
Units from both the user and the system manager are listed together, with
their current state shown on every row. Units you toggle often can also be
pinned to the bar, each with its state and Start / Stop / Restart controls.

## Plugin

| Field | Value |
| --- | --- |
| ID | `srounce/systemd` |
| Entries | Launcher provider: `units`; bar widget: `unit-status`; panel: `controls`; service: `actions` |
| Launcher Prefix | `/svc` |

## Requirements

`systemctl` must be on `PATH`, which is the case on any systemd-based system.
Controlling system units goes through polkit, so a polkit authentication agent
must be running unless a wrapper command is configured in the settings.

## Usage

### Launcher

Open the launcher and type `/svc` to list units. Failed units are shown first,
then running ones. Keep typing to filter by unit name or description, for
example `/svc sshd`. The launcher's category tabs narrow the list to user or
system units.

Select a unit to drill into its actions: the input becomes `/svc <unit> ` and
the results change to **Stop** and **Restart** for a running unit, or **Start**
for one that is not running. Typing after the unit name filters the actions.
Selecting an action runs `systemctl <action> <unit>` (with `--user` for user
units) and shows a notification with the unit's new state, or the error output
if the command failed.

### Bar widget

Add the **Systemd Units** widget (`unit-status`) to a bar, then middle-click it
to open its settings and enter the unit to watch, for example `sshd.service`,
and whether it is a system or user unit. Add one widget per unit you want to
pin.

The widget shows the unit's state as a circle:

| Icon | State |
| --- | --- |
| Filled circle | active |
| Empty circle | inactive |
| Circle with a dot | activating, deactivating or reloading |
| Circle with a cross | failed |
| Dashed circle | no unit set, unit not found, or state unknown |

Hovering shows the unit, its scope and its exact state. Clicking the widget
opens the `controls` panel for that unit: its state and description, and
**Start**, **Stop** and **Restart** buttons (Start for a stopped unit, Stop and
Restart for a running one). An action shows the same notification as the
launcher, and the panel and widget update once it finishes. The panel can also
be toggled directly; it then controls the unit of the widget clicked last:

```sh
noctalia msg panel-toggle srounce/systemd:controls
```

## Settings

### Plugin

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `scopes` | `select` | `both` | Which managers the launcher lists: user and system, user only, or system only. |
| `unit_types` | `string_list` | `["service"]` | Unit types the launcher lists, such as `service`, `timer` or `socket`. |
| `system_wrapper` | `string` | `""` | Command prepended to `systemctl` for actions on system units (launcher and widget), for example `sudo -n`. Leave empty to rely on polkit. |

### Bar widget (per instance)

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `unit` | `string` | `""` | The unit to show and control, for example `sshd.service`. A name without a suffix is treated as a service. |
| `scope` | `select` | `system` | Whether the unit belongs to the system manager or your user manager. |
| `show_label` | `bool` | `false` | Show the unit name next to the state icon, without a `.service` suffix. |

## Notes

The plugin only spawns `systemctl`: `list-unit-files` and `list-units` to build
the launcher list, `show` to read a pinned unit's state, then `start`, `stop`,
`restart` and `is-active` for the chosen action. Nothing is written to disk and
no network access is made. The launcher's unit list is cached for ten seconds
between queries. Each bar widget reads its unit's state every three seconds;
these reads never go through `system_wrapper`, since querying state needs no
privileges. Panel actions run in the `actions` service, so each action runs
once however many widgets are on the bars.
