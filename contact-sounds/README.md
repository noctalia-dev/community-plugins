# Contact Notification Sounds

Plays a **unique sound per person** on your notifications.

Configure a map of contact names to sound files in **Settings → Plugins**.
When any notification arrives, the plugin checks its app name, title and body
for your contacts' names (case-insensitive by default) and plays the assigned
sound for the first contact matched.

## Plugin

| Field   | Value                                                                      |
| ------- | -------------------------------------------------------------------------- |
| ID      | `nilsonlinux/contact-sounds`                                               |
| Entries | Service: `monitor`; Panel: `Panel`; Shortcut: `sounds`; Bar widget: `contact-sounds-widget` |

## Features

- **Unique notification sounds per contact** — you always know who messaged
  you before looking.
- **Panel of contacts** — open it from the control-center tile or the bar bell
  icon: play each sound, **add** a contact by name + sound path, **edit** an
  existing entry, or **delete** a contact (with an inline confirmation).
- **App filter** — optionally restrict matching to specific notification apps
  (e.g. Telegram, Discord) so browser spam never matches.
- **OGG or MP3** — any local `.ogg` or `.mp3` file with an absolute path.
- **Hide the bar icon** — toggle `show_widget` off to remove the bell from the bar.

## How it works

- `service.luau` runs `scripts/monitor.sh`, a `dbus-monitor` pipeline that
  watches the `org.freedesktop.Notifications` session interface and forwards
  every `Notify()` call as `app \x1e title \x1e body`.
- The service matches contact names in that text and plays the sound through
  Noctalia's audio system (`noctalia.sound`), honoring its volume and DND state.
- **Exclusive sound**: the service also keeps `~/.config/noctalia/contact-sounds.toml`
  in sync with a `[notification.filter.contact-sounds]` rule
  (`play_sound = false`) whose regex matches the configured contact names. This
  silences Noctalia's system notification sound for exactly those messages, so
  only the contact's OGG plays. Notifications that mention nobody keep their
  normal system sound.
- `panel.luau` reads the same config to list contacts and test sounds.
- `shortcut.luau` adds a control-center tile that opens the panel.

Open the panel directly with:
```sh
noctalia msg panel-toggle nilsonlinux/contact-sounds:Panel
```

## Requirements

- `dbus-monitor`, `gawk` and `python3` (all usually present on Arch/Debian).

## Usage

1. Open **Settings → Plugins → Contact Notification Sounds**.
2. Add a contact under `contacts`: the **name** exactly as it appears in a
   notification, and the **absolute path** to a local `.ogg` or `.mp3` file.
3. Click the bar bell (or the control-center tile) to open the panel — play,
   add, edit or delete contacts from there.

Example:

```
"Maria Souza"  = "/home/you/Documents/Sounds/maria.ogg"
"João Carlos"  = "/home/you/Documents/Sounds/joao.ogg"
```

## Settings

| Setting                  | Type         | Default | Description                                                              |
| ------------------------ | ------------ | ------- | ------------------------------------------------------------------------ |
| `contacts`               | `string_map` | `{}`    | `"Person Name" = "/path/to/sound.{ogg,mp3}"`                             |
| `show_widget`            | `bool`       | `true`  | Show the bell icon in the bar.                                           |
| `match_case_sensitive`   | `bool`       | `false` | Match names with exact capitalization.                                   |
| `only_apps`              | `string_list`| `[]`    | App-name allow-list; empty = all apps.                                   |
| `glyph` (widget)         | `glyph`      | `bell-ringing` | Icon shown in the bar for the bell widget.                        |

## Notes

Notification text and panel labels come from `translations/<locale>.json`
(English and `pt-BR` included). The panel's **Add/Delete** controls edit the
same `contacts` map (via `scripts/edit_contacts.sh`, which writes Noctalia's
`settings.toml`).

Sound files are played at the [Noctalia](https://noctalia.dev) audio volume.

## License

MIT