# Zakker

Periodic desktop notifications reminding you of salawat upon the Prophet ﷺ,
morning/evening azkar, and random Quran verses, so remembrance stays part of your day.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mohammednaser28/zakker` |
| Entries | Bar widget: `zakker`; service: `remind`; shortcut: `toggle`; launcher: `find` |
| Launcher Prefix | `/zakker` |

## Usage

The service `remind` starts automatically when the plugin is enabled and posts
a notification every `interval` minutes. Non-Quran turns alternate salawat and
azkar; every Nth reminder is a random Quran verse.

- **Bar widget** (`zakker`): add it from Settings → Bar → Add widget, shows `ذِكر`.
  Click it for an instant reminder. The tooltip shows the latest reminder and the
  countdown to the next one.
- **Shortcut** (`toggle`): add it from Settings → Control Center shortcuts.
  The `Zakker` tile pauses or resumes periodic reminders.
- **Launcher** (`find`): open the launcher and type `/zakker <query>`, for example
  `/zakker استغفار`. Selecting a result copies it to the clipboard and shows it
  as a notification. An empty query lists the bundled reminders (up to 20 results).

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `interval` | `int` (1–180) | `30` | Minutes between notifications. |
| `salawat_enabled` | `bool` | `true` | Include salawat upon the Prophet ﷺ in the rotation. |
| `azkar_enabled` | `bool` | `true` | Include morning/evening azkar in the rotation. |
| `notify_on_start` | `bool` | `true` | Show azkar when the shell starts (morning 04:00–18:00, evening otherwise; bundled fallback is used offline). |
| `quran_enabled` | `bool` | `true` | Every Nth reminder is a random Quran verse. |
| `quran_every` | `int` (1–20) | `3` | How often a Quran verse appears in the rotation. |
| `edition` | `string` | `ar.abdulbasitmurattal` | Quran edition id for verse text. |
| `translation_edition` | `string` | `""` | Extra edition appended to the verse, e.g. `en.asad`. Empty disables it. |
| `morning_count` | `int` (1–10) | `3` | How many morning azkar each notification shows. |
| `evening_count` | `int` (1–10) | `3` | How many evening azkar each notification shows. |

Open with `noctalia msg settings-open-plugin mohammednaser28/zakker`
(or Settings → Plugins → gear on the zakker row).

## IPC

```sh
# fire a reminder now (advances the rotation)
noctalia msg plugin mohammednaser28/zakker:remind all now

# refetch azkar.json immediately
noctalia msg plugin mohammednaser28/zakker:remind all refresh

# reset rotation + timer
noctalia msg plugin mohammednaser28/zakker:remind all reset

# widget: instant reminder on the focused bar
noctalia msg plugin mohammednaser28/zakker:zakker focused now

# reload after plugin.toml changes (.luau edits hot-reload on their own)
noctalia msg config-reload

# logs (service logs fetch/decode results as zakker ...)
tail -f ~/.cache/noctalia/noctalia.log | grep zakker
```

## Notes

- Network: fetches `azkar.json` from `raw.githubusercontent.com` (nawafalqari/azkar-api)
  every 6 hours, and random verses from `api.alquran.cloud` on Quran turns.
  All bundled salawat/azkar in `lib/reminders.luau` work fully offline as fallback.
- No external commands are spawned and no files are written; the online pools are
  cached in memory only. No accounts, keys, or personal data are involved.
- Sources: [azkar-api](https://github.com/nawafalqari/azkar-api) (azkar),
  [api.alquran.cloud](https://api.alquran.cloud) (Quran).
