# Lyrics Carousel

Synced lyrics for the bar, a panel and the desktop, with a per-character
karaoke fill — drawn with the declarative UI, no terminal window involved.

```
♪  and the carousel keeps turning        ← bar widget
   while the whole world is asleep
 ▸ I keep singing out of tune            ← panel / desktop widget
   and the carousel keeps turning
```

## Plugin

| Field | Value |
| --- | --- |
| ID | `faminec/lyrics-carousel` |
| Entries | Bar widget: `widget`; panel: `panel`; desktop widget: `desktop`; service: `service`; control-center tile: `shortcut` |

## Requirements

- `playerctl` on `PATH` — reads the active MPRIS player
- `python3` on `PATH` — runs the lyrics adapter (standard library only)
- Noctalia 5.3.0 or newer (`plugin_api = 34`)

No authentication and no compositor features are needed.

## Usage

Add the **Lyrics Carousel** widget to a bar. It shows the line being sung and
follows it as the song plays; clicking it opens the panel. It can also be
placed as a desktop widget from the desktop-widget editor, where the host owns
the position and the size.

The panel opens from the bar widget, from that shortcut, or from a keybinding:

```sh
noctalia msg panel-toggle faminec/lyrics-carousel:panel
```

The `service` entry does the work: it polls the active player twice a second
and publishes the track and the lyrics on plugin state, so the same search
serves every surface at once.

## Settings

Settings → Plugins → Lyrics Carousel. Noctalia draws the form from the
manifest, so each option is described where you change it.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `font_size` | `int` | `22` | Size of the lyric text, 6–96. |
| `direction` | `select` | `down` | Whether the lyrics scroll down or up. |
| `marker` | `bool` | `false` | Draws a marker next to the active line. |
| `marker_style` | `int` | `0` | Marker shape, 0–5: `›` `•` `\|` `♪` `»` `—`. Shown only with `marker` on. |
| `karaoke` | `bool` | `true` | Fills the active line as it is sung. |
| `ghost` | `bool` | `true` | Fades the lines around the active one. |
| `header` | `bool` | `false` | Title and artist above the lyrics. |
| `footer` | `bool` | `false` | Time played and progress bar below them. |
| `spacing` | `int` | `2` | Gap between lines, 1–6. |
| `active_scale` | `double` | `1.35` | How much bigger the active line is, 1.0–2.5. |
| `visible_above` | `int` | `2` | Lines shown above the active one, 0–20. |
| `visible_below` | `int` | `2` | Lines shown below the active one, 0–20. |
| `accent` | `select` | `primary` | Palette role of the active line (`primary`, `secondary`, `tertiary`, `error`) or `custom`. The palette follows the wallpaper. |
| `custom_color` | `color` | `#e46767` | Colour used when `accent = custom`. |
| `offset_ms` | `int` | `0` | Shifts the lyrics against the audio, −3000 to 3000. Negative values make them earlier. |
| `instrumental` | `bool` | `true` | Shows a placeholder while nobody sings instead of keeping the last line. |
| `instrumental_icon` | `int` | `0` | Placeholder glyph, 0–3: `♪` `♫` `♬` `♩`. |
| `instrumental_text` | `string` | (empty) | Text used instead of the glyph. Empty means the glyph. |
| `silence_threshold` | `int` | `4` | Seconds of silence before the placeholder appears, 1–15. |

A gap counts as instrumental when the intro is longer than the threshold, when
the LRC carries an empty timed line, or when the stretch between two lines is
longer than the threshold and the current line is already sung.

## IPC

| Command | Effect |
| --- | --- |
| `noctalia msg panel-toggle faminec/lyrics-carousel:panel` | Opens or closes the panel. |
| `noctalia msg plugin faminec/lyrics-carousel:service all refresh` | Searches again for the current track, ignoring the cache. |
| `noctalia msg plugin faminec/lyrics-carousel:service all brain` | Turns the karaoke fill off (or back on) for the current track only. |
| `noctalia msg plugin faminec/lyrics-carousel:widget all refresh` | Redraws the bar widget from the state it already has. |
| `noctalia msg plugin faminec/lyrics-carousel:desktop all refresh` | Redraws the desktop widget. |

## Shortcuts

Everything is a plugin setting, so Noctalia's settings page is the whole UI:
ranged options are sliders there, and the wheel belongs to that page instead
of fighting a custom panel.

The control-center tile **Karaoke glow** (entry `shortcut`) turns the fill off
for the song that is playing and gives it back on the next one: the same
per-track break the old panel drew as a brain button.

For desktop-wide keys, bind the IPC events above, for example:

```sh
noctalia msg plugin faminec/lyrics-carousel:service all brain      # this song, no fill
noctalia msg panel-toggle faminec/lyrics-carousel:panel            # the carousel
```

## Notes

- Network: the adapter asks `lrclib.net` for the title, artist and duration of
  what is playing, and nothing else. No lyrics are uploaded.
- Files: answers are cached for 24 hours under
  `$XDG_CACHE_HOME/lyrics-carousel`. Delete that directory to forget them.
- Commands spawned: `playerctl metadata` twice a second, and `python3` plus the
  adapter once per track.
- The karaoke is a row of `ui.label`s with `gap = 0`, one per character, each
  coloured by its own timestamp. It needs no plugin API above the floor, and
  falls back to a whole-line fill when the source has no word timings.
- LRCLIB rarely has word timings, so most songs fill line by line. Instrumental
  detection needs a timed LRC: a source without timestamps cannot tell where the
  voice is.
- Anything that does not expose MPRIS metadata (`title`, `artist`, `status`) is
  invisible to the service.

## Tests

```bash
lua5.4 bin/test-render.lua lib/render.luau lib/lyrics.luau   # renderer
lua5.4 bin/test-state.lua lib/state.luau                     # shared state
lua5.4 bin/test-service.lua service.luau lib/lyrics.luau     # MPRIS + fetch
lua5.4 bin/test-entries.lua                                  # widget/panel/desktop
python3 bin/selftest.py                                      # adapter + manifest
```

The Lua tests need only `lua5.4`. The Python one loads the adapter with a fake
network, so it never touches LRCLIB.

## License

MIT.
