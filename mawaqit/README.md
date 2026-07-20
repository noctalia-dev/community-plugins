# Mawaqit

Prayer times for Noctalia, with a bar widget and panel: live countdown to the next
prayer, notifications, optional azan playback, Hijri date, and per-prayer time
offsets.

## Plugin

| Field   | Value                                                        |
| ------- | ------------------------------------------------------------ |
| ID      | `ycf/mawaqit`                                                 |
| Entries | Bar widget: `bar`; panel: `panel`; service: `fetcher`         |

## Requirements

Install `paplay` (PipeWire/PulseAudio) **or** `pw-cat` on `PATH` — only one is
required, used for azan playback. If neither is installed, azan is skipped (a
line is logged) and everything else — countdown, panel, notifications — works
normally.

Also requires `pkill` (part of `procps`, present on virtually every distro by
default) — used to stop azan playback, since neither player exposes its own
stop control.

Azan audio is **not bundled**. To enable it:

1. Get your own azan `.mp3` file(s) from wherever you like.
2. Copy them into this plugin's `assets/` folder, named exactly `azan1.mp3`,
   `azan2.mp3`, and/or `azan3.mp3` (only the ones you want to use — you don't
   need all three).
3. In Settings → Plugins → Mawaqit, turn on **Play Azan** and pick which of
   the three slots to play from **Azan audio**.

If the selected file isn't present, azan is silently skipped and a line is
logged — nothing else is affected.

## Usage

- **Left click** the bar widget → open the prayer times panel.
- **Right click** the bar widget → cycle its display mode: live countdown →
  static time → prayer name only.

Toggle the panel directly:

```sh
noctalia msg panel-toggle ycf/mawaqit:panel
```

The panel shows all five daily prayers plus Sunrise and, during Ramadan, Imsak,
with a live countdown banner to whichever is next, the Gregorian and Hijri
date, and a refresh button. If azan is playing, a stop button appears next to
it.

## Settings

Plugin-level (Settings → Plugins → Mawaqit):

| Setting             | Type     | Default | Description                                                              |
| -------------------- | -------- | ------- | -------------------------------------------------------------------------- |
| `city`               | `string` | `London` | Your city name in English.                                                |
| `country`            | `string` | `UK`     | Country name or 2-letter code.                                            |
| `method`             | `select` | `3` (MWL) | Calculation authority followed in your region.                          |
| `school`             | `select` | `0` (Shafi/Maliki/Hanbali) | Asr convention — Hanafi uses a later shadow factor.               |
| `hijriDayOffset`     | `select` | `0`     | Shift the displayed Hijri day by −1/0/+1 if it doesn't match local moon sighting. |
| `twelveHourFormat`   | `bool`   | `false` | Show prayer times as 12-hour (e.g. `5:23 AM`) instead of 24-hour.         |
| `showNotifications`  | `bool`   | `true`  | Show a system notification when each prayer time begins.                 |
| `playAzan`           | `bool`   | `false` | Play an azan audio file when each prayer time begins.                    |
| `azanFile`           | `select` | `azan1.mp3` | Which bundled azan track to play (see Requirements for setup).      |
| `tune`               | `bool`   | `false` | Enable the per-prayer minute offsets below.                              |
| `tuneFajr`           | `int`    | `0`     | Fajr offset, in minutes (−60 to 60).                                     |
| `tuneDhuhr`          | `int`    | `0`     | Dhuhr offset, in minutes.                                                |
| `tuneAsr`            | `int`    | `0`     | Asr offset, in minutes.                                                  |
| `tuneMaghrib`        | `int`    | `0`     | Maghrib offset, in minutes.                                              |
| `tuneIsha`           | `int`    | `0`     | Isha offset, in minutes.                                                 |

Bar widget settings (from the widget's own settings menu):

| Setting            | Type     | Default            | Description                                                    |
| ------------------- | -------- | ------------------- | ------------------------------------------------------------------ |
| `showCountdown`     | `bool`   | `true`              | Show a live countdown to the next prayer instead of the static time. |
| `showElapsed`       | `bool`   | `false`             | After a prayer begins, count up (`+`) for up to 1 hour.            |
| `hidePrayerName`    | `bool`   | `false`             | Show only the time or countdown, without the prayer name.          |
| `widgetIcon`        | `glyph`  | `building-mosque`   | Bar icon.                                                           |
| `dynamicIcon`       | `bool`   | `false`             | Show a sun/moon icon matching the current prayer instead of the fixed icon. |
| `textColor`         | `color`  | `on_surface`        | Bar text color.                                                     |
| `iconColor`         | `color`  | `on_surface`        | Bar icon color.                                                     |
| `activeColor`       | `color`  | `primary`           | Color used when a prayer is happening now or during elapsed mode.   |

## IPC

Force an immediate refetch (both the service and the bar widget respond):

```sh
noctalia msg plugin ycf/mawaqit:fetcher all refresh
```

Set the bar widget's display mode directly:

```sh
noctalia msg plugin ycf/mawaqit:bar all mode countdown|static|name
```

## Notes

- The background service fetches prayer times once daily from
  `api.aladhan.com`, sending the configured city/country/method/school as
  query parameters, plus a second request for the next day's Fajr time (used
  for the countdown after Isha).
- Azan playback runs `paplay` or `pw-cat` against a file **you supply** (see
  Requirements) — no audio is bundled with this plugin. Playback is stopped
  by matching the exact file path being played (via `pkill -f`), not a
  generic pattern — this is the only termination method available since the
  plugin API doesn't currently expose a PID or stop handle for spawned
  processes. Stopping happens when the plugin exits or is disabled, or
  manually from the panel while azan is playing.
- The Arabic Hijri date and prayer-time banner are rendered with the bundled
  Reem Kufi font (`ReemKufi.ttf`), licensed under the SIL Open Font License —
  see `OFL.txt`.
- No compositor-specific behavior — works anywhere Noctalia's bar and panels do.
