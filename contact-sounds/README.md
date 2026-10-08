# Contact Notification Sounds

Plays a **unique sound per person, group or app** on your notifications.

Configure a list of contacts — each mapped to a sound file (**or a folder of
sounds**) — from the **panel**. When any notification arrives, the plugin checks
its app name, title and body for your contacts' names (case-insensitive by
default) and plays the assigned sound for the first contact matched.

## Plugin

| Field   | Value                                                                      |
| ------- | -------------------------------------------------------------------------- |
| ID      | `nilsonlinux/contact-sounds`                                               |
| Entries | Service: `monitor`; Panel: `Panel`; Shortcut: `sounds`; Bar widget: `contact-sounds-widget` |

## Features

- **Unique notification sounds per contact** — you always know who messaged
  you before looking.
- **Contacts, groups and apps** — each entry can be typed as **Contato**,
  **Grupo** or **App**. Contact/group entries match the notification title and
  body; **app** entries match the notification *app name* only, so an app
  entry can't be triggered by a mention of its name in some other app's text.
- **Photo / group photo / app icon in the list** — every row in the panel
  starts with the entry's avatar: an optional photo/icon you give it, or the
  app's own icon for app entries (glyph placeholder otherwise).
- **Folders of sounds** — instead of a single `.ogg/.mp3`, an entry can point
  to a **folder**; the panel lists that folder's sounds in a menu-list.
  Pick one sound for the entry, or leave **Random (any sound)** so any sound
  from the folder plays.
- **Panel of entries** — open it from the control-center tile or the bar bell
  icon: play each sound, **add** an entry (type + name + sound file or folder
  + optional photo), **edit**, or **delete** (with an inline confirmation).
- **Drag-and-drop reordering** — grab any row's drag handle and drop it onto
  the thin strips between rows to change the list order; the order persists
  exactly like the entries themselves.
- **Stop button for long sounds** — when you test a sound longer than ~5s, the
  panel also shows a **stop** button that immediately cuts the audio (it
  destroys the active PipeWire stream; see *How it works*).
- **Overlapping playback** — rapid hits for the same contact are never
  swallowed: each play re-uses one of three ring-slot buffers so a fresh copy
  always starts from the beginning, even if the previous one is still playing.
- **App filter** — optionally restrict matching to specific notification apps
  (e.g. Telegram, Discord) so browser spam never matches.
- **OGG/MP3/WAV** — any local `.ogg`, `.mp3` or `.wav` file with an absolute
  path, or a folder containing them.
- **Hide the bar icon** — toggle `show_widget` off to remove the bell from the bar.

## How it works

Entries are edited **only from the panel**, and the contact list is owned by
the plugin itself — it does **not** live in Noctalia's app settings.

- The authoritative list is kept in the plugin's **persistent data file**
  `~/.local/state/noctalia/plugins/data/nilsonlinux/contact-sounds/state.json`
  (via `noctalia.pluginDataDir()`, which survives plugin updates and Noctalia
  restarts). Every add/edit/delete/reorder in the panel is sent as a command to
  the `monitor` service (`noctalia.state` "contacts.cmd"), which applies it,
  writes `state.json` immediately and republishes — no config reload, so the
  panel never closes while you edit.
- On startup, the service loads the list back from `state.json` and republishes
  it as `contacts.data`. The panel reads the current value with
  `noctalia.state.get("contacts.data")` on load and watches it for changes, so
  a freshly opened panel always shows the real saved list — not whatever the
  app config still has.
- `service.luau` runs `scripts/monitor.sh`, a `dbus-monitor` pipeline that
  watches the `org.freedesktop.Notifications` session interface and forwards
  every `Notify()` call as `app \x1e title \x1e body`.
- The service matches contact names in that text and plays the sound through
  Noctalia's audio system (`noctalia.sound`); plugin sounds are not silenced by
  Do Not Disturb. A folder entry resolves to its picked sound, or a random
  member, per hit. Sounds are loaded one per tick to respect the runtime's
  pending-load cap, and a rapid second hit reloads a ring slot so it is never
  suppressed while a previous copy is still playing.
- **Stop**: there is no runtime "stop" API for playback, so the stop button
  runs `scripts/stop_sounds.py`, which finds the active `noctalia-sound`
  PipeWire nodes in `pw-dump` and destroys them with `pw-cli`. Afterwards the
  service invalidates the loaded buffers, so the next play always mints a fresh
  one. `scripts/sound_durations.py` probes how long each sound is (via
  `ffprobe`, `mutagen` or a `.wav` header) so the stop button only appears for
  sounds longer than ~5s.
- **Exclusive sound**: the service keeps
  `~/.config/noctalia/contact-sounds.toml` in sync with
  `[notification.filter.contact-sounds-*]` rules that set `play_sound = false`
  (`scripts/sync_filter.sh`), so Noctalia's system notification sound is
  suppressed exactly when the plugin will play a contact's audio. The rules
  only cover contact sounds that loaded, are disabled while case-sensitive
  matching is on (system filters are always case-insensitive), and become one
  rule per allowed app when `only_apps` is set. The file is removed when the
  plugin is disabled or uninstalled, so the system sound can never be left
  muted. Notifications that match nothing keep their normal system sound.
- `panel.luau` renders the list and all actions. `widget.luau` draws the bar
  bell (hidden when `show_widget` is off) and `shortcut.luau` adds the
  control-center tile; both open the panel.

Open the panel directly with:
```sh
noctalia msg panel-toggle nilsonlinux/contact-sounds:Panel
```

## Requirements

- `dbus-monitor`, `gawk` and `python3` (all usually present on Arch/Debian) —
  declared as plugin dependencies.
- The **stop** button additionally needs `pw-dump` and `pw-cli` (PipeWire).
- Sound-duration probing optionally uses `ffprobe` (ffmpeg) or
  `python3-mutagen`; without them the stop button is simply not shown for
  sounds it can't measure.

## Usage

Entries are managed **only from the panel** — the contact settings are hidden
from **Settings → Plugins** so the list can't be edited outside the UI.

1. Click the bar bell (or the control-center tile) to open the panel.
2. Click **+** to add an entry:
   - **Type** — `Contact`, `Group` or `App`.
   - **Name** — type it exactly as it appears in a notification. The field
     starts empty for every new entry.
   - **Sound** — a `.ogg`/`.mp3`/`.wav` file, or a **sounds folder**. When the
     form opens it suggests folders you have used before; the pencil/​list
     button switches between picking an existing folder and typing a path.
   - **Photo / icon path** — optional avatar for the row.
3. **Save** — the entry is written to the plugin's `state.json` instantly and
   appears in the list. It survives plugin reloads, plugin updates and
   restarting Noctalia.
4. **Play** (`▶`) — hear the entry's sound; **Edit** (`✎`) and **Delete** (`🗑`,
   confirm with `✓`/`✕` in the row) manage entries, and **Drag** any row's
   handle to reorder the list.
5. For **folder** entries, a menu-list shows the folder's sounds — pick one, or
   **Random (any sound)** so any file from the folder plays per notification.
6. For sounds longer than ~5s a **stop** (`■`) button also appears in the row,
   cutting off the playback immediately.

Example of what the list holds underneath (edited via the panel only):

```
"Maria Souza"  = "/home/you/Documents/Sounds/maria.ogg"
"João Carlos"  = "/home/you/Documents/Sounds/joao.ogg"
"Família"      = "/home/you/Documents/Sounds/familia"   # folder of sounds
```

## Settings

| Setting                  | Type         | Default | Description                                                              |
| ------------------------ | ------------ | ------- | ------------------------------------------------------------------------ |
| `contacts`               | `string_map` | `{}`    | `"Name" = "/path/to/sound.{ogg,mp3,wav}"` or a folder of sounds. *(hidden — edited from the panel)* |
| `contact_kinds`          | `string_map` | `{}`    | `"Name" = "contact" \| "group" \| "app"` (default `contact`). *(hidden — edited from the panel)* |
| `contact_images`         | `string_map` | `{}`    | `"Name" = "/path/to/photo-or-icon.png"` shown at the start of the row. *(hidden — edited from the panel)* |
| `folder_sounds`          | `string_map` | `{}`    | `"Name" = "sound.ogg"` picked inside a folder entry; empty = random. *(hidden — edited from the panel)* |
| `sound_folders`          | `string_map` | `{}`    | Registry of known sound-folder paths offered when adding an entry. *(hidden — edited from the panel)* |
| `contact_order`          | `string_list`| `[]`    | Contact names in display order; set by drag-and-drop in the panel. *(hidden — edited from the panel)* |
| `show_widget`            | `bool`       | `true`  | Show the bell icon in the bar.                                           |
| `match_case_sensitive`   | `bool`       | `false` | Match names with exact capitalization. *(advanced)*                      |
| `only_apps`              | `string_list`| `[]`    | App-name allow-list; empty = all apps. *(advanced)*                       |
| `glyph` (widget)         | `glyph`      | `bell-ringing` | Icon shown in the bar for the bell widget.                        |

## Notes

Notification text and panel labels come from `translations/<locale>.json`
(English and `pt-BR` included).

The contact list is stored in the plugin's persistent data file
(`noctalia.pluginDataDir()/state.json`) — it is never kept in the app-managed
`settings.toml`, so panel-created entries survive config reloads and plugin
updates untouched.

`~/.config/noctalia/contact-sounds.toml` is managed by the plugin
(`scripts/sync_filter.sh`) and should not be edited by hand. Matching is always
case-insensitive for the exclusive-sound suppression; with `only_apps` set, a
contact must appear in the notification summary or body (a name that only shows
up in the app name is covered only when no app allow-list is configured).

Sound files are played at the [Noctalia](https://noctalia.dev) audio volume.

## License

MIT