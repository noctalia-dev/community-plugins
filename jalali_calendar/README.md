# Jalali Calendar

The Iranian Solar Hijri calendar for Noctalia - on the bar, in a panel, and in
the Control Center. It shows Iranian public holidays and civil occasions, with
the Gregorian and Lunar Hijri dates alongside every day, and works entirely
offline.

![Calendar panel](thumbnail.webp)

![Bar widget](screenshot-bar.webp)

## Plugin

| Field | Value |
| --- | --- |
| ID | `borderliner/jalali_calendar` |
| Entries | Bar widget: `date`; panel: `calendar`; shortcut: `open` |

## Requirements

None. The plugin is self-contained: no external commands, no network access,
and no files written.

## Usage

None of the three surfaces is placed automatically.

**Bar widget** - Settings > Bar, add *Jalali Calendar*. It shows today's date.
Clicking it opens the panel; the tooltip carries the long date, the Gregorian
and Hijri equivalents, and the day's occasions.

**Panel** - a month grid with today highlighted, Fridays and public holidays in
red, and the selected day's occasions listed underneath with its Gregorian and
Hijri dates spelled out. Clicking the month title opens a month picker, and
clicking the year there opens a year picker, so any date is two clicks away.
Open it directly with:

```sh
noctalia msg panel-toggle borderliner/jalali_calendar:calendar
```

**Control Center tile** - Settings > Control Center > Home, add it to the
shortcuts. There are six slots, so one of the defaults has to give way. The
tile is labelled with today's date and opens the panel. In `settings.toml` the
same thing is:

```toml
[[control_center.shortcuts]]
type = "borderliner/jalali_calendar:open"
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `language` | `select` | `persian` | Script for month and weekday names, and the direction of the grid. |
| `digits` | `select` | `persian` | Numerals: Persian or Latin. |
| `week_start` | `select` | `saturday` | Which weekday the grid starts on. Saturday matches the Iranian week. |
| `scale` | `double` | `1.0` | Scales the panel's text and cells, 0.7-2.0. Panel size is fixed by the manifest, so large values scroll rather than grow. |
| `events_national` | `bool` | `true` | Iranian civil, cultural and scientific days (non-holidays). |
| `events_ancient` | `bool` | `true` | Pre-Islamic and Zoroastrian festivals: Mehregan, Sadeh, Yalda and the rest. |
| `events_religious` | `bool` | `false` | Shia and Islamic observances (non-holidays). |
| `events_afghan` | `bool` | `false` | Afghan national days. Their public holidays only count as days off while this is on. |
| `show_hijri` | `bool` | `true` | Lunar Hijri day number in each cell. |
| `show_gregorian` | `bool` | `true` | Gregorian day number in each cell. |
| `show_holidays` | `bool` | `true` | Mark public holidays and list each day's occasions. |
| `format` | `string` | `{weekday} {day} {month}` | Bar widget template. Placeholders: `{day}` `{month}` `{year}` `{weekday}`. |
| `font_size` | `int` | `0` | Bar widget font size in pixels. `0` follows the bar's own size. |
| `show_glyph` | `bool` | `true` | Show an icon beside the date on the bar. |
| `glyph` | `glyph` | `calendar` | Which icon. |

## Notes

### No network, no writes, no processes

`dependencies = []`. The plugin makes no HTTP requests, spawns no commands and
writes no files. Everything it needs is in the plugin directory.

### Where the calendar data comes from

Two public-domain (CC0 1.0) datasets, compiled into `occasions.luau` at build
time by `tools/generate_occasions.py`:

- **Occasions and holidays** - [persian-calendar/events](https://github.com/persian-calendar/events),
  whose Iranian entries transcribe the official University of Tehran calendar.
- **Lunar Hijri month starts** - [roozbehp/qamari](https://github.com/roozbehp/qamari),
  the first Gregorian day of each Hijri month *as actually observed in Iran*.

Occasions are stored by rule rather than resolved per year, so the table stays
small and stays correct for any year you browse to.

### Which occasions are included

Occasions come in four groups, each switchable in the settings: Iranian civil
and cultural days, ancient Iranian festivals, religious observances, and Afghan
national days. Civil days and ancient festivals are on by default.

Iranian public holidays are always shown, by name, whatever is switched on, so
the calendar always tells you which days are days off.

Titles are shown without honorifics such as «حضرت».

The grouping is keyword-based over the Persian titles, because the upstream
data ships no categories. The rules are in `tools/generate_occasions.py`.

### How accurate the Hijri dates are

Iran fixes each lunar month's start by sighting and publishes about a year
ahead, so the observed data stops at a horizon (currently 1447/10 =
2026-03-21). Past that the plugin continues the real sequence using tabular
month lengths anchored to the last observed start, which stays close rather
than drifting. Seven individual months are missing from the upstream source and
are bridged between the surrounding anchors. Solar holidays fall on fixed
Jalali dates and are always exact.

### Fonts

Vazirmatn is bundled (`fonts/`, SIL OFL 1.1) and loaded at startup, because the
bar's configured font often has no Persian glyphs. If it fails to load the
plugin falls back to the host font rather than failing to render.

### Limitations

- Occasion titles are Persian only. The source dataset carries no English
  translations, so Latin mode changes the numerals, month and weekday names and
  grid direction, but occasion names stay Persian.
- Seven weekday-relative occasions from the dataset ("the second Friday of
  Mehr") are not shown. None is a public holiday; the generator lists them when
  it runs.
- Per-day tooltips are not used: they need plugin API 32 and this plugin
  targets 22. Click a day to see its occasions.

## Development

The date logic is pure and runs headlessly, so it is tested without a shell:

```sh
./check.sh          # luau-analyze, tests, manifest lint, store limits
luau tests/run.luau # tests alone
```

Two host details worth knowing before editing:

- **`require` needs the `.luau` extension in Noctalia**, and Noctalia resolves
  paths relative to the plugin root. The standalone `luau` CLI used by the
  tests wants the opposite. Shared modules use a small `req()` helper that
  tries both; entry scripts, which only run inside Noctalia, use the extension
  directly. It is also why every module sits at the plugin root.
- **Neither `ui.button` nor `ui.input` accepts a `fontFamily`** - only
  `ui.label` does. Text buttons are therefore clickable columns wrapping a
  label, and the year picker is a grid rather than a text field.

## License

MIT - see `LICENSE`. The bundled occasion and month-start data is CC0 1.0
(public domain) and is credited above. The bundled Vazirmatn font is SIL Open
Font License 1.1 - see `fonts/LICENSE-Vazirmatn.txt`.
