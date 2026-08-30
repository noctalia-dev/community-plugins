# Remmina

Opens your saved [Remmina](https://remmina.org/) connections from the Noctalia
launcher. Type `/rmn`, pick a host, and the session opens in Remmina — no
digging through its window, no retyping addresses.

## Plugin

| Field | Value |
| --- | --- |
| ID | `rylos/remmina` |
| Entries | Bar widget: `bar`; panel: `connections`; launcher provider: `launcher` |
| Launcher Prefix | `/rmn` |

## Requirements

Install `remmina` on `PATH`, with the plugin for the protocols you use
(`remmina-plugin-rdp`, `remmina-plugin-vnc`, …, depending on your distribution).

You also need at least one saved connection profile. The plugin reads the
profiles Remmina already wrote; it never creates or edits them.

## Usage

Add the **Remmina** widget to a bar from Settings → Bar. It shows a single
monitor glyph, with the number of saved connections in its tooltip; clicking it
opens the panel. You can also open the panel directly:

```sh
noctalia msg panel-toggle rylos/remmina:connections
```

The panel lists every connection under its Remmina group, with a filter box on
top. Clicking a row opens that connection and closes the panel; the button in
the header opens Remmina's own window instead.

Type `/rmn` in the launcher to list every profile, sorted by group and then by
name. Keep typing to filter — the filter matches the connection name, its
group, the server address and the protocol, so `/rmn rdp` narrows to RDP
connections and `/rmn office` to a group.

Each result shows the connection name, and under it the group, the
`user@server` target and the protocol. Activating one runs:

```sh
remmina -c ~/.local/share/remmina/<profile>.remmina
```

Remmina then handles the session exactly as if you had launched it from its own
window, including the stored password.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `profiles_path` | `file` | `~/.local/share/remmina` | Folder holding the `.remmina` profiles. Change it if your profiles live elsewhere, for example in a synced folder. |
| `show_group` | `bool` | `true` | Show the profile's Remmina group at the start of the subtitle. Turn it off if you do not use groups. |
| `max_results` | `int` | `30` | Maximum number of connections listed at once. |

## Notes

- **No network access, no writes.** The plugin reads the profile files and
  spawns `remmina -c <profile>`. Nothing else.
- **Passwords are never touched.** They are stored encrypted inside the profile
  and only Remmina resolves them; the plugin reads `name`, `group`, `protocol`,
  `server` and `username` and ignores every other key.
- **Profiles are cached** and re-read only when the profile folder's mtime
  changes, so typing in the launcher does no disk I/O. A profile added or
  removed from Remmina therefore shows up on the next query.
- A profile with no `name` falls back to its file name, so it is never
  invisible. Profiles with no group are listed last, under "Ungrouped".
- The launcher filter is fuzzy; the panel filter is a plain substring match on
  the same four fields.
