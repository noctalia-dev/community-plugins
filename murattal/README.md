# Murattal

Stream murottal Al-Qur'an per surah (mp3quran.net) and per ayah (everyayah.com), played headless via mpv. The bar widget shows the current surah/ayah. The panel has three tabs: **Surah** (simple qari + surah + Play), **Per Ayah** (per-ayah audio with Arabic text and Indonesian translation), and **Favorit** (saved surah/qari). Advanced controls live behind **Opsi**, so the default view stays simple. The launcher searches surahs, juz, and qari.

## Plugin

| Field | Value |
| --- | --- |
| ID | `abuamar142/murattal` |
| Entries | Bar widget: `murottal`; panel: `browser`; service: `player`; launcher: `finder` |
| Launcher Prefix | `/quran` |

## Requirements

Install `mpv` and `socat` on `PATH`. `mpv` does headless playback, `socat` talks to its IPC socket for volume/seek/speed. Without `socat`, volume changes relaunch mpv and progress is parsed from mpv's log; seek is unavailable.

Optional: `mpv-mpris` (AUR, `mpv-mpris-git`) so the bar media widget, keyboard media keys, and `playerctl` can control playback. The package installs `/etc/mpv/scripts/mpris.so`, which mpv auto-loads for every instance — no flag needed. Do **not** also pass `--script=` for it: that loads the script twice and the second D-Bus registration fails.

## Usage

Add the `murottal` widget to the bar. Click toggles play/stop, right-click opens the panel, scroll changes volume.

Open the panel:

```sh
noctalia msg panel-toggle abuamar142/murattal:browser
```

### Panel

The now-playing card stays at the top: title, mode (Surah or Ayah X/N), progress seek, prev/play/next, and favorite toggle.

- **Surah** — the simple flow: pick a qari, pick a surah, press **Putar surah**. Offline download is next to it.
- **Per Ayah** — pick an EveryAyah reciter and surah, then play any ayah from the reading list. The Arabic text and Indonesian translation come from equran.id, cached per surah. The current ayah is highlighted and scrolled into view automatically; each row has play and repeat buttons.
- **Favorit** — saved surah/qari pairs with play and remove.

**Opsi** opens the advanced controls: volume, repeat/shuffle, repeat count (1x–5x), speed, sleep timer, translation/transliteration toggles, juz queue, and the riwayah filter.

Playback position is saved every 15 s and on stop/exit, and restored on the next start, so a restart does not send you back to Al-Fatihah.

### Launcher

```
/quran <surah>          play a surah with the current qari
/quran juz 30           play a juz in order
/quran riwayah warsh    pick a qari from that riwayah
/quran unduh            download the current surah for offline playback
/quran rm               remove a favorite
```

Empty `/quran` lists favorites.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `default_volume` | `int` | `65` | mpv volume 0-100. |
| `mpv_bin` | `string` | `mpv` | mpv executable. |
| `show_name` (widget) | `bool` | `true` | Show surah name next to icon. |
| `max_length` (widget) | `int` | `24` | Max characters of surah name. |
| `show_translation` (panel) | `bool` | `true` | Show the Indonesian translation under each ayah in the Per Ayah tab. |
| `show_latin` (panel) | `bool` | `false` | Show the Latin transliteration under each ayah in the Per Ayah tab. |

## IPC

```sh
noctalia msg plugin abuamar142/murattal:player all play '{"reciterId":"1-1","surahId":1}'
noctalia msg plugin abuamar142/murattal:player all playAyah '{"everyayahId":"Alafasy_128kbps","surahId":1,"ayah":1}'
noctalia msg plugin abuamar142/murattal:player all setMode ayah
noctalia msg plugin abuamar142/murattal:player all setEveryAyah Alafasy_128kbps
noctalia msg plugin abuamar142/murattal:player all setAyah 3
noctalia msg plugin abuamar142/murattal:player all stop
noctalia msg plugin abuamar142/murattal:player all toggle
noctalia msg plugin abuamar142/murattal:player all next
noctalia msg plugin abuamar142/murattal:player all prev
noctalia msg plugin abuamar142/murattal:player all juz 30
noctalia msg plugin abuamar142/murattal:player all volume 60
noctalia msg plugin abuamar142/murattal:player all speed 1.25
noctalia msg plugin abuamar142/murattal:player all repeat
noctalia msg plugin abuamar142/murattal:player all repeatCount 3
noctalia msg plugin abuamar142/murattal:player all shuffle
noctalia msg plugin abuamar142/murattal:player all sleep 30
noctalia msg plugin abuamar142/murattal:player all seek 42
noctalia msg plugin abuamar142/murattal:player all download
noctalia msg plugin abuamar142/murattal:player all removeDownload
noctalia msg plugin abuamar142/murattal:player all refresh
```

## Notes

- Network: mp3quran.net reciter/surah catalog and audio, everyayah.com per-ayah audio, equran.id for surah text.
- Files: favorites at `favorites.json`, last position at `state.json`, downloaded audio at `audio/<moshaf>/NNN.mp3`, cached text at `text/NNN.json`, mpv IPC socket `mpv.sock` — all under the plugin data dir.
- Processes: one headless `mpv --no-video`. Killed on disable/uninstall/exit.
- A juz maps to every surah it touches, because the catalogue serves audio per surah; a surah spanning a juz boundary belongs to both juz. The spans come from api.alquran.cloud and are stored as explicit pairs, so juz 2 is surah 2 alone and juz 30 is 78–114.
