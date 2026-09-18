# Contact Notification Sounds

Plays a **unique sound per person, group or app** on your notifications.

Configure a map of contact names to sound files (or **folders of sounds**) in
**Settings → Plugins**. When any notification arrives, the plugin checks its
app name, title and body for your contacts' names (case-insensitive by
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
  Pick one sound for the entry, or leave **Random** so any sound from the
  folder plays.
- **Panel of entries** — open it from the control-center tile or the bar bell
  icon: play each sound, **add** an entry (type + name + sound file or folder
  + optional photo), **edit**, or **delete** (with an inline confirmation).
- **App filter** — optionally restrict matching to specific notification apps
  (e.g. Telegram, Discord) so browser spam never matches.
- **OGG/MP3/WAV** — any local `.ogg`, `.mp3` or `.wav` file with an absolute
  path, or a folder containing them.
- **Hide the bar icon** — toggle `show_widget` off to remove the bell from the bar.

## How it works

- `service.luau` runs `scripts/monitor.sh`, a `dbus-monitor` pipeline that
  watches the `org.freedesktop.Notifications` session interface and forwards
  every `Notify()` call as `app \x1e title \x1e body`.
- The service matches contact names in that text and plays the sound through
  Noctalia's audio system (`noctalia.sound`) at the configured volume; plugin
  sounds are not silenced by Do Not Disturb.
- **Exclusive sound**: the service keeps `~/.config/noctalia/contact-sounds.toml`
  in sync with `[notification.filter.contact-sounds-*]` rules that set
  `play_sound = false`, so Noctalia's system notification sound is suppressed
  exactly when the plugin will play a contact's OGG. The rules only cover
  contact sounds that loaded, are disabled while case-sensitive matching is on
  (system filters are always case-insensitive), and become one rule per allowed
  app when `only_apps` is set. The file is removed when the plugin is disabled
  or uninstalled, so the system sound can never be left muted. Notifications
  that match nothing keep their normal system sound.
- `panel.luau` reads the same config to list entries and test sounds. Each row
  shows the entry's photo/icon and, for folder entries, a **menu-list** of the
  folder's sounds to pick from.
- `shortcut.luau` adds a control-center tile that opens the panel.

Open the panel directly with:
```sh
noctalia msg panel-toggle nilsonlinux/contact-sounds:Panel
```

## Requirements

- `dbus-monitor`, `gawk` and `python3` (all usually present on Arch/Debian).

## Usage

Entries are managed **only from the panel** — the contact settings are hidden
from **Settings → Plugins** so the list can't be edited outside the UI.

1. Click the bar bell (or the control-center tile) to open the panel.
2. Click **+** to add an entry: choose its **type** (Contact / Group / App),
   type the **name** exactly as it appears in a notification, pick a **sound
   file** or a **sounds folder**, and optionally a photo/icon path.
3. Use the pencil/trash buttons to edit or delete entries, and the **play**
   button to hear each entry's sound. For **folder** entries, choose a specific
   sound from the menu-list (or leave **Random**).

Example of what `contacts` holds underneath (edited via the panel only):

```
"Maria Souza"  = "/home/you/Documents/Sounds/maria.ogg"
"João Carlos"  = "/home/you/Documents/Sounds/joao.ogg"
"Família"      = "/home/you/Documents/Sounds/familia"   # folder of sounds
```

## Settings

| Setting                  | Type         | Default | Description                                                              |
| ------------------------ | ------------ | ------- | ------------------------------------------------------------------------ |
| `contacts`               | `string_map` | `{}`    | `"Name" = "/path/to/sound.{ogg,mp3,wav}"` or a folder of sounds. *(advanced, edited from the panel)* |
| `contact_kinds`          | `string_map` | `{}`    | `"Name" = "contact" \| "group" \| "app"` (default `contact`). *(advanced, edited from the panel)* |
| `contact_images`         | `string_map` | `{}`    | `"Name" = "/path/to/photo-or-icon.png"` shown at the start of the row. *(advanced, edited from the panel)* |
| `folder_sounds`          | `string_map` | `{}`    | `"Name" = "sound.ogg"` picked inside a folder entry; empty = random. *(advanced, edited from the panel)* |
| `show_widget`            | `bool`       | `true`  | Show the bell icon in the bar.                                           |
| `match_case_sensitive`   | `bool`       | `false` | Match names with exact capitalization.                                   |
| `only_apps`              | `string_list`| `[]`    | App-name allow-list; empty = all apps.                                   |
| `glyph` (widget)         | `glyph`      | `bell-ringing` | Icon shown in the bar for the bell widget.                        |

## Notes

Notification text and panel labels come from `translations/<locale>.json`
(English and `pt-BR` included). The panel's **Add/Delete** controls edit the
same maps (via `scripts/edit_contacts.sh`, which writes Noctalia's
`settings.toml`).

`~/.config/noctalia/contact-sounds.toml` is managed by the plugin and should not
be edited by hand. Matching is always case-insensitive for the exclusive-sound
suppression; with `only_apps` set, a contact must appear in the notification
summary or body (a name that only shows up in the app name is covered only when
no app allow-list is configured).

Sound files are played at the [Noctalia](https://noctalia.dev) audio volume.

## License

MIT