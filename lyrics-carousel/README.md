# Lyrics Carousel

Synced lyrics in a floating kitty window, in the spirit of `cava`, `lavat` or `unimatrix`.

## Install

Add this repository as a plugin source and enable the plugin:

```sh
noctalia msg plugins source add dev path https://github.com/F4M1N3C/noctalia-plugins
noctalia msg plugins enable faminec/lyrics-carousel
```

Then add the **Lyrics Carousel** bar widget from Noctalia's widget picker. Clicking it
opens the panel (attached to the widget) and holds every setting of the plugin; the
lyrics window itself is opened from the panel's **Open the carousel** button.

## Plugin

| Field | Value |
| --- | --- |
| ID | `faminec/lyrics-carousel` |
| Entries | Bar widget: `widget`; panel: `panel` |

## Requirements

The plugin works on **Hyprland 0.57 or newer only**: the lyrics window is opened
with the Hyprland Lua API (`hl.dsp.exec_cmd`) and its geometry is applied with
`hl.dsp.window.*`. There is no Niri or Sway backend, and before Hyprland 0.57 the
window cannot be placed that way — that is why the thumbnail carries the
`Hyprland 0.57+ · Widget` tag.

The following executables must be installed and available on `PATH`:

| Executable | Package | What it is used for |
| --- | --- | --- |
| `kitty` | `kitty` | The terminal the lyrics window runs in, and the graphics protocol the image renderer draws with. |
| `hyprland` | `hyprland` | The compositor. The plugin only runs on Hyprland. |
| `hyprctl` | `hyprland` | Lists, moves, resizes, focuses and closes the lyrics window (panel geometry, self-test). |
| `playerctl` | `playerctl` | Reads the active MPRIS player so the plugin knows what is playing. |
| `python3` | `python` | Runs the carousel script (`bin/lyrics-carousel`) and the settings helper (`bin/set-setting.py`). |
| `fc-match` | `fontconfig` | Resolves the configured font family to a file for Pillow (image mode accepts any installed font). |

`python3` needs Pillow (`python-pillow`) for the image renderer. The plugin never
installs anything: every dependency has to be there before the plugin is enabled.

The lyrics themselves come from the Noctalia Lyrics plugin's source adapter
(`lyric_sources.py`), so the same providers and the same configuration are reused:
LRCLIB, NetEase, SPlayer, QQ Music, Kugou and, with credentials, Spotify, Apple Music
or Musixmatch.

## Usage

Add the `widget` bar icon and click it to open the lyrics window. The panel opens
attached to the widget and holds every setting of the plugin.

The panel can also be opened directly:

```sh
noctalia msg panel-toggle faminec/lyrics-carousel:panel
```

### Image rendering mode

The window is drawn as a transparent PNG the size of the window
(1200×820 px by default) using Pillow and the kitty graphics protocol,
so the desktop wallpaper stays visible through it. The active line is drawn
larger, the scroll is pixel-accurate and any font works. The trade-off
is that the text cannot be selected.

The text-only mode was removed in 2.4.0: it relied on Kitty's OSC 66 text
sizing protocol which cannot color individual characters within a scaled
block, so true per-character karaoke was impossible.

Since 2.7.0 the window is drawn at its native resolution (no upscaling) and
the whole plugin runs at 60 real frames per second: the frame deadline is
measured from the start of the frame, so a frame that takes 8 ms sleeps the
remaining 8.7 ms instead of a full interval on top of it.

The providers are queried in parallel and the first one to answer wins. The search
waits up to 15 seconds, so a slow provider is not thrown away; if nobody has answered
by then, the lookup is retried a minute later. The result is cached in
`~/.cache/lyrics-carousel`.

### Keyboard shortcuts

| Key | Action |
| --- | --- |
| `q` | Quit |
| `space` | Pause / resume |
| `d` | Reverse the scroll direction |
| `k` | Toggle the karaoke effect |
| `r` | Look the lyrics up again |

`d` and `k` write their value to `settings.toml`, so the change survives a restart
and shows up in the settings page. Writing that file makes Noctalia reload the
configuration, so a panel that happened to be open at that moment is closed.

## Settings

Everything is configured from the **panel** (the button on the bar widget), which is
where the user has it at hand. It keeps its own changes in a small overrides file and
pours them into `settings.toml` when it is closed, so the settings page and the panel
always end up showing the same values without the panel closing under the user's
fingers. The script re-reads the settings every 0.5 s, so changes apply live to a
window that is already open.

The plugin manifest (`plugin.toml`) only declares `glyph`, the bar icon: everything
else is panel-only. Noctalia keeps the saved keys in `settings.toml` even when the
manifest does not declare them, and the panel reads them back with
`set-setting.py read` (so it shows the real values, not the defaults), but
`noctalia.getConfig` only answers the keys it knows. That is why the ranges are
declared in `lib/settings.luau` and applied both by the panel (before writing) and
by the script (when reading).

`glyph` is also the only setting left in **Settings → Plugins → Lyrics Carousel**:
it belongs to the bar widget, not to the lyrics window.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `font_family` | `string` | `Departure Mono` | Font used for the lyrics. |
| `font_size` | `int` | `22` | Size of the lyrics, in pixels. |
| `direction` | `select` | `down` | `down`: the lyrics come in from the top. `up`: from the bottom. |
| `marker` | `bool` | `false` | Shows a `>` next to the active line. |
| `karaoke` | `bool` | `true` | Lights the active line as it is sung, letter by letter. |
| `footer` | `bool` | `false` | Elapsed time and a progress bar. |
| `hints` | `bool` | `false` | Keyboard hints at the bottom. |
| `header` | `bool` | `false` | Title, artist and status tags. |
| `spacing` | `int` | `2` | Space between the lines. |
| `ghost` | `bool` | `true` | Smooth ~0.9 s slide between lines. Off: the change is instant. |
| `offset_ms` | `int` | `0` | Offset to fine-tune the synchronisation. |
| `width` | `int` | `1200` | Window width. |
| `height` | `int` | `820` | Window height. |
| `anchor` | `select` | `center` | Window anchor: `center`, `top-left`, `bottom-right`… or `custom` (uses custom_x/custom_y). |
| `custom_x` | `int` | `100` | Custom horizontal position (only with anchor = custom). |
| `custom_y` | `int` | `100` | Custom vertical position (only with anchor = custom). |
| `accent` | `select` | `primary` | Colour of the active line: `primary` (follows the wallpaper), an ANSI colour or `custom`. |
| `custom_color` | `string` | `#e46767` | Hex colour used when `accent = custom`. |
| `active_scale` | `double` | `1.35` | Size multiplier of the line being sung. |
| `visible_above` | `int` | `6` | Lines visible above the active one. |
| `visible_below` | `int` | `6` | Lines visible below the active one. |
| `glyph` | `glyph` | `music` | Bar icon (only in the settings page). |

The position and the size are applied live to the running window, without recreating
it. The font family and the font size also apply live: the font cache is
invalidated on change, so there is no need to reopen the window.

## IPC

The panel is opened with:

```sh
noctalia msg panel-toggle faminec/lyrics-carousel:panel
```

Both entries also accept messages, which is handy for keyboard shortcuts:

```sh
noctalia msg plugin faminec/lyrics-carousel:panel all launch
noctalia msg plugin faminec/lyrics-carousel:panel all toggle karaoke
noctalia msg plugin faminec/lyrics-carousel:panel all set font_size 26 int
noctalia msg plugin faminec/lyrics-carousel:panel all refresh

noctalia msg plugin faminec/lyrics-carousel:widget all launch
noctalia msg plugin faminec/lyrics-carousel:widget all toggle karaoke
noctalia msg plugin faminec/lyrics-carousel:widget all set font_size 26 int
noctalia msg plugin faminec/lyrics-carousel:widget all refresh
```

| Event | `panel` | `widget` |
| --- | --- | --- |
| `launch` | Opens the lyrics window (starts the script). | Toggles the panel. |
| `toggle <key>` | Flips a switch. | Flips a switch. |
| `set <key> <value> [type]` | Sets a setting. | Sets a setting. |
| `refresh` | Re-reads the settings and the track, and redraws the panel. | Redraws the bar icon. |

`toggle` only works with the switches — `marker`, `karaoke`, `footer`, `hints`,
`header` and `ghost` — because flipping a number makes no sense.

The value of `set` can also be written as `key=value`. Its type (`bool`, `int`,
`float` or `string`) is optional: without it, the type is deduced from the setting,
so `set karaoke true` stores a boolean and not the string `"true"`.

```sh
noctalia msg plugin faminec/lyrics-carousel:widget all set font_size 26 int
noctalia msg plugin faminec/lyrics-carousel:widget all set font_family="Departure Mono"
```

`set` and `toggle` write to the same overrides file the panel uses, so the change is
poured into `settings.toml` when the panel is closed and is visible in the settings
page afterwards.

## Changelog

### 2.7.1

- **The right lyrics, not the first with timing**: a NetEase lyrics that comes
  without any accented vowel nor `ñ` (e.g. `algn`, `petrleo`, `pases`, `Quin`)
  no longer wins over a correctly written one (LRCLIB) just because it carries
  per-character timing. Spanish/Portuguese/French lyrics are detected by
  vocabulary (at least 25 words and 8 distinct stop-words) and zero accented
  letters; a no-accent version neither replaces a correct one nor is cut
  early, and a correct one can still replace it even without per-word timing.
  English, which is also accent-free, is never marked.

### 2.7.0

- **The karaoke is the glow of the letter, not a shadow**: the blurred halo
  around the sung text is gone. What is left is the crisp fill of the sung
  part, with its edge fading into the unsung part instead of a hard cut. It
  also saves 3.2 ms per frame (two Gaussian blurs), which is what kept the
  carousel below 60 fps.
- **60 real fps**: the frame deadline is measured from the start of the frame
  (before: the whole interval was slept *after* the work, so the real cycle
  was `work + interval` → 36 fps). The log now reports real fps instead of
  the theoretical ones derived from the draw time alone.
- **Continuous letter size**: the font size is cached in quarter-pixels, so
  the line that grows no longer steps one whole pixel at a time.
- **Smoother scroll**: the slide uses a smootherstep curve (no acceleration
  at the ends), so the start and the brake of the transition are not felt.
- **No darkening jump**: with the karaoke on, the line that is about to
  become the active one arrives at the dim tone of the not-yet-sung letters
  instead of the bright accent, so the hand-off no longer darkens the line
  all at once.
- **The fill edge fades instead of cutting**: the sung part dissolves into
  the unsung part over the last column of the letter being sung, instead of
  ending in a straight wall of light. The outgoing line also keeps the
  opacity of its distance to the centre, so it does not lose it in one
  frame at the hand-off.
- **Native resolution**: the lyrics are drawn at the window's own size
  (1200×820 by default) with no upscaling.

### 2.6.0

- **Visualizer removed**: The audio visualizer (`cava` behind lyrics) has been removed. It never looked as smooth as standalone `cava` and added complexity without benefit. The plugin is now **image-only, 60 fps**.
- **60 fps native render**: The whole plugin runs at 60 fps (MOTION_FPS). Render happens at 1/3 resolution (400×273) with BILINEAR upscale → ~19 ms/draw (≈50 fps) with stable frame pacing. Superseded in 2.7.0: the lyrics are now drawn at the native resolution with a fixed-step frame deadline.
- **Persistent window size**: Manual resize is saved to `settings.toml` and restored on reopen. Moving the window (anchor buttons) preserves the configured size.
- **No lyrics translation**: `translate_lyrics` removed (was always `false` by default).
- **Cleaner panel**: Visualizer toggle, position/coverage controls, and translate option removed. Only relevant settings remain.
- **Dead code removed**: `visualizer.py`, `_draw_visualizer`, `visualizer_module`, `check_visualizer_*`, `_draw_visualizer` all gone. ~700 lines deleted.

### 2.5.0

- **Image only, for real**: the text rendering mode, the render-mode buttons and
  every text-mode helper are gone. The panel no longer offers a choice that the
  window cannot honour.
- **`cava` behind the lyrics**: the visualiser is no longer an option. `cava` runs
  with its own configuration and its bars fill the whole window as a background,
  at 30 fps in the steady state. If it fails, simulated bars keep the window alive.
- **Soft transition, simplified**: `ghost` now means a fixed ~0.9 s eased slide
  (60 fps while moving, capped at 80 % of the gap to the next line). With `ghost`
  off the change is instant. `animation_ms` is gone: `offset_ms` already covers
  timing corrections and the millisecond slider only made the scroll feel laggy.
- **Cleaner panel**: window language (automatic again), the cache button and
  `animation_ms` were removed. Keyboard hints are centred in the window.
- **Less dead weight**: removed the character equalizer, the text layout helpers
  and the unused terminal-width utilities.

### 2.4.0

- **Image-only mode**: text rendering mode removed. It relied on Kitty's OSC 66
  protocol which cannot color individual characters within a scaled block,
  making true per-character karaoke glow impossible. Image mode now provides
  the complete experience: pixel-perfect karaoke fill, true Gaussian blur glow,
  and any font at any scale.
- **Simpler codebase**: removed all OSC 66/kitty text scaling logic,
  `karaoke_cut`, `karaoke_amount` (text variant), `build_frame`,
  `_draw_text_frame`, `use_image`, and fallback logic.

### 2.3.0

- **Karaoke character-by-character fires at exact timestamp again**: the 1.0.0
  behavior is restored — with `active_scale = 1.0` (or no scale) each character
  lights up exactly when its timestamp arrives, no interpolation or rounding.
  With scaling the fill still advances on block boundaries so no gaps open.
- **Glow in image mode is true blur** (2.3.0): the sung text is blurred into a
  halo reaching several pixels beyond the letters, fading at the fill edge
  instead of a hard wall. The boundary between sung and unsung text is a
  gradient.
- **Word-level timing preference**: the first lyrics result appears immediately
  (usually LRCLIB, line-level). If another provider (NetEase, QQ Music) returns
  per-character timings, it upgrades live and the cache stores the word-level
  version. LRC enhanced tags `<mm:ss.xx>` are now parsed into per-character
  times. NetEase duration is omitted from the request to avoid strict filtering.
- **Background upgrade without disrupting playback**: when a cached line-level
  lyrics is shown, a background search for word-level timing runs once per
  song per week (`.noword` marker). The upgrade applies only if it truly
  improves quality; equal or worse results don't reposition the carousel.
- **Cache only stores the best quality**: `save_cache` now only writes when
  the new result has word-level timing or when it's the initial fetch
  (`upgrade=False`). This prevents a line-level result from overwriting
  a cached word-level one.

### 2.2.0

- The karaoke fill is pixel-smooth in both modes and follows the real timings: with
  per-character times (the ones the source adapters provide) a long syllable takes
  longer to light up, and within the character in progress the fill advances
  continuously instead of jumping from word to word. In image mode it no longer
  spreads the whole line duration across the characters, so the line keeps the
  rhythm of the song.
- The sung part really glows: the lit text is blurred into a halo that reaches
  several pixels beyond the letters (it used to be a one-pixel outline, which
  looked like glue), and the halo fades out at the edge of the fill instead of
  ending in a straight wall of light. The boundary between the lit and the unlit
  text is a gradient, so the light seems to travel along the line.
- The active line in text mode is split into blocks whose length is a multiple of
  the exact period of the scale (`s × n/d`): with 1.2 the blocks are 5 characters,
  which occupy whole cells, so the visible gaps every few characters are gone.
  The fill advances on those block boundaries, so no piece of text is ever split
  and no gap opens inside a word. When the active line is not scaled
  (`active_scale = 1.0`) there are no blocks: the fill changes character exactly
  at its timestamp, as in 1.0.0, so it stays glued to the voice.
- The scroll uses `animation_ms` as its real duration (it was half of it), never
  invades the following line (it fits in 80% of the gap), and both modes now ease
  with the same curve: the block dims while it moves and the movement feels the
  same in image and text mode.
- The equaliser is seven bars with a central envelope and a slow wave, and it stays
  symmetric when paused.
- The time bar is centred in the window: the row used to start two columns in and
  the remainder piled up on the right.
- `visible_above` / `visible_below` count screen lines, not list lines: with
  `direction = down` the future used to enter on the wrong side and the neighbours
  overlapped the active block.
- Emptying the lyrics cache from the panel now tells the open window to look the
  song up again (`SIGUSR1` sent to the PID the window leaves in
  `window.pid`, never to a `pkill -f` match: SIGUSR1 kills by default), confirms
  with a notification and explains when it is actually needed. For a single song,
  `r` in the window is enough.
- The bar icon is no longer in the panel: it belongs to the bar widget and is
  changed in Settings → Plugins → Lyrics Carousel, the only setting left in the
  manifest. Everything else is panel-only, and the panel reads the saved values
  with `set-setting.py read` so it shows the real ones instead of the defaults.
- The panel and the script clamp with the same ranges (declared in
  `lib/settings.luau`, since the manifest no longer carries them).

### 2.1.0

- The panel is rebuilt around the settings that change the look of the window: one
  font dropdown (with the fonts kitty accepts and an option to type any other),
  the nine anchor positions of the window as a 3×3 grid with their names, the
  accent colours as a palette of chips, and the colour, the bar icon and the
  visualiser in their own sections. The custom colour only shows up when the
  accent is `custom`, and the visualiser is replaced by a note when the header
  is on.
- The active line is drawn at the right size in text mode: it uses kitty's text
  sizing protocol with the metadata that kitty understands (`s × n/d`), so the
  factor is applied instead of being drawn at 20% of its size, and the text is
  split into the blocks that kitty needs to keep the characters together.
- The window uses the real size of the terminal. It used to assume a minimum of
  30×12 cells, which made every row overflow and the lyrics break apart in
  windows with a large font.
- The panel now exposes every setting of the manifest: `spacing`, `animation_ms`,
  `offset_ms`, `custom_color` and `glyph` are no longer settings-page only.
- Numeric controls use sliders with the manifest ranges (`font_size`, `active_scale`,
  `visible_above`, `visible_below`) and clamp every value, including the ones received
  over IPC: a window can no longer be wider or taller than the screen.
- The panel opens `attached` to the widget, next to the click, instead of floating in
  the centre of the screen.
- The panel no longer redraws itself after it has been closed, reports a failed merge
  instead of losing the changes silently, and applies size changes received over IPC
  to the window that is already open.
- A track with an artist but no title no longer restarts the lyric search on every
  poll.
- Slow source adapters get 22 seconds instead of 3, so NetEase and QQ Music are not
  killed in the middle of an answer.
- Estimated times never overwrite real LRC times, and lines without a time no longer
  break the highlight order: they keep their place in the song instead of starting
  to sing six seconds in, and they never end up outside the song (including the
  lines before the first real timestamp or after the last one).
- Image mode is not re-armed by an unrelated settings reload after the script
  disables it for repeated failures: only an explicit change back to `image`
  turns it on again.
- The settings helper validates formats as well as ranges, so a malformed
  `glyph`, `custom_color` or an empty `font_family` cannot be written through
  any entry point, not just the panel and the widget IPC.
- The karaoke fill ends at the next real timestamp, not at the next line of the list
  (lines without a time are not timestamps and used to cut the fill short).
- A failed image renderer stays disabled instead of re-arming on every settings
  reload, and it can be switched on again on request.
- `[hh:mm:ss]`, three-digit minutes and up to six decimals are accepted in LRC files,
  text between angle brackets (`I <3 you`) is preserved, only the winning provider
  writes the cache, and the lyrics settings and adapter are found under
  `NOCTALIA_STATE_HOME` / `XDG_STATE_HOME`.
- The window is always clipped to the monitor, also when it is resized over IPC.
- The font family can be typed by hand (the manifest declares it as free text), and
  the bar icon and the custom colour are validated before they are saved — on every
  write path, including the IPC of the widget.
- The value ranges are read from the manifest even on Python versions without
  `tomllib`, so the clamping never disappears silently.

### 2.0.0

- The panel's switches really turn on and off: Noctalia hands the value over as the
  string `"true"`, which was never equal to `true`.
- The window position dropdown was one position off and saved the previous anchor;
  it now offers the ten anchors of the manifest.
- The width and height steppers no longer change the value when the mouse merely
  passes over them.
- `offset_ms` is applied to the scroll as well as to the highlight, so the line in
  the middle is the one that is being sung.
- The lyric lookup waits 15 seconds instead of 4 and no longer marks a song as
  "no lyrics" while a provider is still answering; an empty result is retried every
  minute.
- The sound visualiser keeps its own row instead of drawing over the lyrics.
- The texts of the window are in English and Spanish (`--lang`; `auto`, the default,
  follows the system language).
- `d` and `k` are saved in `settings.toml`, so they survive a restart.
- The settings, the overrides and the data directory follow `NOCTALIA_STATE_HOME`
  and `XDG_STATE_HOME`, like Noctalia itself.
- The window position is a dropdown in the settings page as well, and the panel can
  empty the cache of lyrics.

## Tests

```sh
python3 ~/.local/share/noctalia/plugins/lyrics-carousel/bin/selftest.py --verbose
lyrics-carousel --diagnostics
```

The self-test checks the installation assumptions: the helper is next to the
script, the data directory can be created, the overrides round-trip, the
external tools are available and — importantly — that the script finds its
sibling modules and the helper when it is launched through the symbolic link
in `~/.local/bin` (which is how the panel starts it). It also checks that
every `.luau` of the plugin compiles as it is (so a syntax error is never
mistaken for Luau-only syntax) and that the `d` and `k` shortcuts really
toggle the direction and the karaoke and save them in the `settings.toml`. It
also checks that the demo mode does not ask any lyrics provider for anything —
and that the script's debug log is actually being written, so that check is not
vacuous.

The self-test never touches the real state: it runs the script with a temporary
`HOME`, `XDG_STATE_HOME` and `XDG_CACHE_HOME`, so the settings file, the
overrides and the cache of lyrics are all written in a throwaway directory. The
overrides file can also be redirected on its own with the
`LYRICS_CAROUSEL_OVERRIDES` environment variable (the script and the helper both
honour it). That also avoids a race: the script writes asynchronously, so a write
could land after the test had finished and end up applied to the real
settings the next time the panel is closed.

`--diagnostics` prints the same information for the running script as JSON.
Both are used by `tools/verify-plugins.py`.

The verifier itself has a regression battery, which simulates failures
(a broken `.luau`, a self-test that fails without naming the plugin, a
validator that crashes, a missing compiler, a missing log, no shared
validators) and checks that each one is reported and blocks the pass.
It works on temporary copies of the repository, the deployment and the
state, so it never touches the real installation.

The battery reads the verifier's result in JSON (`--json`), so it checks
the behaviour (which failures, of which plugin, blocking or not) and not
the wording of the messages. Each scenario isolates its cause: a PATH with the usual tools minus the one
it wants to be missing, so a scenario about a missing compiler does not
also break the validators. No assertion can pass in the void: if the
verifier does not return JSON, or the self-tests did not run, the battery
says so instead of taking it for a pass. It also checks that the exit code
and the code reported in the JSON always agree:

A `.luau` that only uses Luau syntax is not an error: type annotations are
stripped first (the shared normaliser mangles them) and the rest is
normalised with the shared `noctalia_api` module and compiled again. If it
still does not compile, but the file has type annotations, it is reported
as a warning (not a failure): it may be Luau syntax the normaliser does
not cover yet.

For this plugin that ambiguity does not exist: the self-test checks that
every `.luau` compiles as it is, so a syntax error is always unambiguous
and is caught statically (and by the self-test too, so there are two
independent ways of noticing it).

The verifier always states what it could and could not check: how many
`.luau` compiled, how many only use Luau syntax, how many are inconclusive,
and it fails (instead of passing) when a check could not be run at all
(missing validator, missing compiler, missing log, Noctalia not
responding). A file that cannot be read (invalid UTF-8) is reported, not
skipped, and the verifier never dies with a traceback: if something
escapes, it says so and exits with an error.

The runtime part is checked too: the panel is opened and closed, the
widget is asked to open it, and a setting is written through the widget.
Every step is checked: the answer must be `dispatched 1`, otherwise the
event was lost and the step did not happen — and even a delivered event
is not enough, so the overrides file is checked too: if the helper fails,
the event is delivered and nothing is written. The write goes through the
widget because it is always instantiated, while the panel entry only
exists while the panel is open and takes a few seconds to be ready (sending
the event too early loses it without a trace).

If the panel has pending changes (the overrides file exists), the verifier
does not write anything: it would overwrite them. It says so instead.

Two more cases are reported instead of being passed over: if the log was
rotated while the verification was running (nothing could be reviewed) and
if the deployed copy is out of date (its self-test is missing).

```sh
python3 ~/.local/share/noctalia/plugins/lyrics-carousel/tools/check-verifier.py
```

## Notes

### What it touches

- **Network:** LRCLIB (`https://lrclib.net/api/search`), NetEase
  (`https://music.163.com/api/search/get` and `https://music.163.com/api/song/lyric`)
  and the local SPlayer API (`http://127.0.0.1:25884` by default) are queried
  directly. Every other provider (SPlayer, QQ Music, Kugou, Spotify, Apple Music
  and Musixmatch) is reached through the source adapter of the Noctalia Lyrics
  plugin, `lyric_sources.py`, so the same providers and the same configuration are
  reused. The credentials of the optional providers are read from that plugin's
  configuration and are sent to those providers only. Nothing else leaves the
  machine.
- **Files written:** the lyrics cache and the debug log under
  `~/.cache/lyrics-carousel`, and the plugin data directory (`overrides.json`,
  `window.pid`). The settings are written to Noctalia's `settings.toml`.
- **Commands spawned:** `kitty` (the lyrics window, launched through the Hyprland
  Lua API), `python3` (the carousel script, the settings helper and the source
  adapter), `playerctl` (player metadata and play/pause), `hyprctl` (`clients -j`
  and `dispatch`), `fc-match` (the font family for Pillow), `pkill` (the previous
  lyrics window, matched on `noctalia-lyrics-carousel --title lyrics`) and
  `sleep` (the delay between creating the window and applying its geometry).

### Limitations

- **Hyprland 0.57 or newer only.** The window is opened and placed with the
  Hyprland Lua API (`hl.dsp.exec_cmd`, `hl.dsp.window.*`), which does not exist in
  earlier versions. There is no Niri or Sway backend.
- The image mode has no text fallback: the lyrics cannot be selected with the
  mouse. Outside kitty (or without Pillow) the window reports the reason in
  `~/.cache/lyrics-carousel/debug.log` and exits instead of drawing something the
  user did not ask for.
- The window is opened with `hl.dsp.exec_cmd(...)` and the class
  `noctalia-lyrics-carousel`; the script can also be run by hand as
  `lyrics-carousel`.
- The panel starts the script by its absolute path (`python3 <plugin>/bin/lyrics-carousel`),
  so it does not depend on the `PATH` nor on the executable bit.
- The accent colour is read from the theme Noctalia generates for kitty, so it
  follows the wallpaper.
- Image mode accepts any installed font: the panel lists a few favourites and
  also allows typing a font name.

### Debugging

- The debug log of the running script is `~/.cache/lyrics-carousel/debug.log`.
- `lyrics-carousel --diagnostics` prints the state of the running script as JSON.
- `bin/selftest.py` checks the installation assumptions without touching the real
  state. See `## Tests`.
