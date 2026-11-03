# Minimize Windows

Hyprland has no "minimize" action. This plugin adds one: it sends a window to the special workspace
`special:minimized`, lists the minimized windows in a bar widget (a row of buttons on long bars, a single button with
a menu on short ones) and restores them with a click or a keybind.

## Plugin

| Field | Value |
| --- | --- |
| ID | `fr4j4/hyprland-minimize` |
| Entries | Bar widget: `bar`; panel: `list`; service: `service` |

## Requirements

- `hyprctl` on `PATH` (it ships with Hyprland).
- `socat` on `PATH`, used to read Hyprland's event socket.
- Hyprland running with the Lua config API (tested on Hyprland 0.56.2). The plugin drives Hyprland through Lua
  dispatcher expressions such as `hl.dsp.window.move(...)`.

## Usage

**Bar widget.** Add **Minimize Windows** (`bar`) from the Add-widget picker in the bar settings. It hides itself when
there are no minimized windows (configurable).

- On long bars it shows one button per window with its icon and title. Click a button to restore that window.
- On short or vertical bars it shows a single button with the number of minimized windows. Click it to open the
  panel.
- If there are more windows than **Windows shown**, a `+N` button opens the panel.

**Panel.** Lists every minimized window. Click a window to restore it, or use **Restore all**. Open it with:

```sh
noctalia msg panel-toggle fr4j4/hyprland-minimize:list
```

**Keybinds.** Minimizing and restoring are driven by IPC, so bind them in your Hyprland config. For example:

```lua
local ipc = "noctalia msg plugin fr4j4/hyprland-minimize:service all "
hl.bind("SUPER + ALT + down", hl.dsp.exec_cmd(ipc .. "minimize"))
hl.bind("SUPER + ALT + up", hl.dsp.exec_cmd(ipc .. "restore-last"))
hl.bind("SUPER + ALT + SHIFT + up", hl.dsp.exec_cmd(ipc .. "restore-all"))
hl.bind("SUPER + ALT + M", hl.dsp.exec_cmd(ipc .. "panel"))
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `restore_to` | `select` | `current` | Where a restored window goes: `current` (the focused workspace) or `origin` (the workspace it was minimized from). |
| `mode` | `select` | `auto` | Widget layout: `auto` (a row when the monitor is at least 1500 px wide, otherwise a button), `list` or `button`. |
| `max_items` | `int` | `5` | Windows shown in the row before a `+N` button appears (1 to 12). |
| `show_titles` | `bool` | `true` | Show each window's title next to its icon in the row. |
| `hide_when_empty` | `bool` | `true` | Hide the widget when there are no minimized windows. |

`restore_to` applies to the whole plugin; the other settings belong to each widget instance. The width check of `auto`
uses the monitor's logical width, so a monitor rotated 90° counts as narrow.

## IPC

```sh
noctalia msg plugin fr4j4/hyprland-minimize:service all <event> [payload]
```

| Event | Payload | Effect |
| --- | --- | --- |
| `minimize` | none | Minimizes the focused window. Windows already in a special workspace are ignored. |
| `restore` | window address | Restores that window (`0x...`, as printed by `hyprctl clients -j`). |
| `restore-last` | none | Restores the most recently minimized window. |
| `restore-all` | none | Restores every minimized window. |
| `panel` | none | Toggles the panel. |

## Notes

- **Processes.** `hyprctl` (`clients`, `activewindow`, `activeworkspace`, `monitors` and `dispatch`) and `socat`, which
  stays open reading Hyprland's event socket. If the event stream is not available, the service re-reads the window
  list every 2 seconds instead.
- **Files.** The plugin writes one file, `origins.json`, to its own data directory
  (`noctalia.pluginDataDir()`), to remember which workspace each window came from. Entries for windows that no longer
  exist are removed.
- **Network.** None.
- **Hyprland only.** Other compositors are not supported. Minimized windows live in the `special:minimized`
  workspace, so they stay visible to Hyprland itself, for example with
  `hyprctl dispatch workspace special:minimized`.
- **Config syntax.** Only the Lua dispatcher syntax of Hyprland 0.56 has been tested. Configs that use the older
  hyprlang dispatcher names have not.
