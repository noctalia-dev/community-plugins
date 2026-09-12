# Panel Switcher

List every registered Noctalia panel (built-in or from any installed plugin)
in the launcher and toggle the selected one.

## Plugin

| Field           | Value                         |
| --------------- | ----------------------------- |
| ID              | `theskyentist/panel-switcher` |
| Entries         | Launcher provider: `panels`   |
| Launcher Prefix | `/pan`                        |

## Requirements

None beyond Noctalia itself.

## Usage

Open the launcher and type `/pan`, then keep typing to fuzzy-filter results.
Selecting a result toggles that panel (`noctalia.togglePanel()` — opens it if
closed, closes it if it's the active panel).

Results show a friendly name and icon rather than the raw panel id where one
is available:

- **Built-in panels** (`clipboard`, `control-center`, `launcher`, `session`,
  `wallpaper`, `polkit`, `setup-wizard`, `tray-drawer`, `test`) use a small
  hardcoded table, since they ship in Noctalia's core and have no manifest to
  read a name/icon from.
- **Plugin panels** (`author/plugin:entry`) show the owning plugin's declared
  `name`/`icon` from its `plugin.toml` — the plugin's entry id is shown as the
  subtitle so panels from the same plugin stay distinguishable.
- Anything not resolved (a plugin whose manifest can't be located) falls back
  to showing the raw id, so nothing silently disappears from the list.
- Filtering matches against both the friendly name and the raw id, so typing
  either finds the result.

Control Center also gets one extra row per sub-tab (Media, Audio, Monitor,
System, Power, Network, Bluetooth, Weather, Calendar, Notifications, Screen
Time), so you can jump straight to, say, Wi-Fi or Bluetooth instead of landing
on whichever tab Control Center last had open. The plain "Control Center" row
still opens/closes it without changing tabs. See [Settings](#settings) to turn
these off, either entirely or one tab at a time.

The launcher prefix (`/pan`) and whether this provider also appears in the
un-prefixed (default) search are not plugin settings — they're controlled the
same way for every plugin launcher provider, via your own config:

```toml
[shell.launcher.providers."theskyentist/panel-switcher:panels"]
prefix = "panels"   # overrides "pan"
global = true        # also show results without typing the prefix
```

## Settings

Configured under **Settings → Plugins** (the gear on this plugin's row).

| Setting                  | Type   | Default | Description                                                                                                                           |
| ------------------------ | ------ | ------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `show_cc_tabs`           | `bool` | `true`  | Master toggle for whether Control Center's sub-tabs (Audio, Network, Bluetooth, etc.) get their own launcher rows at all.             |
| `show_tab_media`         | `bool` | `true`  | Show a Media row (only shown once `show_cc_tabs` is on).                                                                              |
| `show_tab_audio`         | `bool` | `true`  | Show an Audio row.                                                                                                                    |
| `show_tab_monitor`       | `bool` | `true`  | Show a Monitor row.                                                                                                                   |
| `show_tab_system`        | `bool` | `true`  | Show a System row.                                                                                                                    |
| `show_tab_power`         | `bool` | `true`  | Show a Power row.                                                                                                                     |
| `show_tab_network`       | `bool` | `true`  | Show a Network row.                                                                                                                   |
| `show_tab_bluetooth`     | `bool` | `true`  | Show a Bluetooth row.                                                                                                                 |
| `show_tab_weather`       | `bool` | `true`  | Show a Weather row.                                                                                                                   |
| `show_tab_calendar`      | `bool` | `true`  | Show a Calendar row.                                                                                                                  |
| `show_tab_notifications` | `bool` | `true`  | Show a Notifications row.                                                                                                             |
| `show_tab_screen_time`   | `bool` | `true`  | Show a Screen Time row. Has no effect if Noctalia's Screen Time feature is disabled — Noctalia falls back to the Home tab either way. |

## Notes

Discovery works by calling `noctalia msg panel-toggle <bogus-id>` once per
launcher session and parsing the `(available: a, b, c)` list out of its
"unknown panel" error response, then caching it. This is safe from a plugin
because `noctalia.runAsync()` runs the probe on its own thread with a
callback — it cannot block the thread that services Noctalia's IPC socket.

The same trick is **not** safe as a `[shell.launcher.dmenu.entry.*]` config
entry: a dmenu entry's `command` runs synchronously on Noctalia's single
UI/IPC thread, so shelling out to `noctalia msg` there calls back into the
very thread that's blocked waiting for it — a self-deadlock that only
resolves via a ~2s timeout and yields an empty result list.

Activation calls the native `noctalia.togglePanel(id)` binding directly,
in-process, for every plain panel row. The one exception is a control-center
sub-tab row: `noctalia.togglePanel()` has no way to pass a context (it only
takes a bare panel id), so those instead run
`noctalia msg panel-toggle control-center <tab>` via `noctalia.runAsync()` —
the same safe, off-thread pattern discovery already uses, just for
activation. It's not in-process, but it's not the synchronous dmenu-style
call that can deadlock either.

The panel list is cached for the launcher session (until the script reloads);
Noctalia's own panel registry only changes when plugins are enabled/disabled
or Noctalia restarts.

Name/icon lookups read each plugin's `plugin.toml` directly off disk — the
same file Noctalia itself reads for the same purpose — checked in this order:
a hand-placed local plugin (`~/.local/share/noctalia/plugins/<plugin>/`), a
`path`-kind source (`<source location>/<plugin>/`), or a `git`-kind source's
materialized export (`~/.local/state/noctalia/plugins/materialized/<source
name>/<plugin>/`), honoring `NOCTALIA_STATE_HOME`/`XDG_STATE_HOME` and
`NOCTALIA_DATA_HOME`/`XDG_DATA_HOME` overrides. There's no TOML parser
available to plugins, so only the manifest's root-level `name`/`icon` string
fields are pulled out with a line-oriented pattern match (stopping at the
first `[`-prefixed table header), not a full parse. Results are cached in
memory per plugin id for the session.
