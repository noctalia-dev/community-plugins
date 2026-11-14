# NaN Usage

Your [NaN](https://nan.builders) credits in the Noctalia bar: how much of the
period's allowance is gone, how long until it renews, whether the pace is heading
for a lockout, how much of your input the cache served, and where the credits went.
The plugin talks to NaN's API itself.

## Plugin

| Field | Value |
| --- | --- |
| ID | `cmoro-deusto/nan-usage` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `poller` |

## Requirements

**A NaN API key**, at `~/.config/nan/api-key` by default. That is the file NaN's own
`nan` command line tool reads, so if you already use that, there is nothing to do;
another path can be set under Settings. Without a key the widget shows a dash and the
tooltip says which file is missing.

For the panel's link buttons, either `gio` (glib2) or `xdg-open` (xdg-utils) opens
NaN's dashboard in your browser. Neither is required: with neither installed the
buttons copy the address to your clipboard instead, and that behaviour can also be
chosen outright under Settings.

## Usage

The bar widget shows the share of the period's allowance you have used and the time
to the renewal. It is coloured by the pace rather than by the percentage alone:

- your theme's own colour while the pace is fine,
- amber once 75% is used, once the pace would end the period at 75% or more, or once
  the allowance would run out and your credit packs would cover the rest,
- red once 90% is used with no packs, once the pace would leave you without any
  credits for a tenth of the period or more, or when the subscription is paused.

When the allowance is spent and requests draw on packs, the bar shows the packs left
instead. When the subscription is paused it says `paused`. The gauge beside the
figure is set by `panel_gauge`: a bar, a battery that drains as credits go, a line of
credits per day, or none.

- **Left click** opens the panel. Pressing again closes it.
- **Right click** opens these settings.
- **Hover** lists the values: credits used and the allowance, what is left, the
  renewal, the pace, today's credits, the cache share and token split, what the
  cache saved, and one line per model used.

The panel has two columns. On the left: the period overall, then every model on
NaN's price list, the ones you used first, by credits. On the right, for the period:
the credits used, left and in packs with the pace drawn ahead of them, the tokens
split into new input, cached input and output with the cache share, credits per day,
and each model's share. For a model: its credits and requests, its token split, an
estimate of its credits split by token type, its credits per day, and its prices per
1M tokens of each type. When the subscription is paused, or the credits and packs are
spent, a banner says so first, with a button to NaN's dashboard or to buy a credit
pack.

Open the panel from anywhere, including a compositor key binding:

```sh
noctalia msg panel-toggle cmoro-deusto/nan-usage:panel
```

## Settings

Set in **Settings → Plugins** (the gear on the plugin's row), or from the panel's
own cog.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `api_key` | `file` | `~/.config/nan/api-key` | The file holding your NaN API key. |
| `interval` | `int` | `300` | Seconds between requests to the NaN API. |
| `bar_value` | `select` | `percent` | The figure in the bar: `percent` of the allowance used, credits `used`, or credits `remaining`. |
| `panel_gauge` | `select` | `bar` | The indicator beside the text: `bar`, `battery` (draining as credits go), `sparkline` (credits per day), or `none` for text only. |
| `show_reset` | `bool` | `true` | The countdown to the renewal, in the bar. |
| `show_cache` | `bool` | `false` | The period's cache share, after the countdown. |
| `site_action` | `select` | `open` | What the link buttons do: open NaN's dashboard, or copy its address. |
| `show_icon` | `bool` | `true` | Draw the NaN mark in the bar. |
| `icon_style` | `select` | `ghost` | `ghost` draws the mark in the theme's own ink (white on a dark theme, black on a light one); `color` draws it as NaN does. |
| `show_glyph` | `bool` | `false` | Draw a glyph instead of the mark, when `show_icon` is off. |
| `glyph` | `glyph` | `chart-pie` | Which glyph, when `show_glyph` is on. |
| `show_tooltip` | `bool` | `true` | Show the details on hover. |
| `left_click` | `select` | `panel` | What a left click does: open the panel, or nothing. |

## Notes

- **Network.** One request per `interval`: a `GET` to
  `https://api.nan.builders/v1/usage`, NaN's documented usage report, with your key
  as a bearer token. It returns the billing period's credits and, per day and per
  model, the tokens and credits used. Nothing else is contacted.
- **Sensitive data.** Your API key is read from the file above, sent to that host as
  a bearer token over TLS, and held in memory. It is never logged, never shown in
  the tooltip or the panel, and never written anywhere. The responses are held in
  memory only, so a reload starts from nothing and shows a dash until the first
  request lands.
- **Files written.** None.
- **Processes spawned.** Only when you press one of the panel's link buttons (NaN's
  dashboard, and "Buy a credit pack" when you are out of credits): `gio open` or
  `xdg-open`, whichever exists, to hand the page to your browser. With neither
  installed the address is copied instead. Nothing else in the plugin starts
  a process, and no command has to be on `PATH` for the widget or the panel to work.
- **The credit split by token type is an estimate.** NaN reports one credit figure
  per model per day. The split applies NaN's per-model prices for new input, cached
  input and output to the token counts, and scales the result to what NaN billed.
  The prices ship with the plugin in `prices.luau`, and the panel says the date they
  were read. "What the cache saved" uses the same prices.
- **Where the figures start.** NaN began billing in credits on 10 November 2026 and
  counting cached input on 11 November, so the first period's pace is measured from
  10 November and its cache figures start on 11 November.
- **Levels come from the pace, not the percentage.** 80% of the allowance on the
  third day is a warning, and so is a pace that lands past 75%; running out is
  critical only when it would leave you without credits for a tenth of the period
  or more, because running out just before the renewal is merely a bad day.
- **One poller serves every monitor.** The widget can be on several bars; the service
  is one entry per plugin, so the API traffic does not multiply.
- **Compositors.** Nothing here is compositor-specific: the plugin uses the bar,
  panel and service APIs and no IPC to any window manager, so it behaves the same
  under any compositor Noctalia supports.
- **When something is wrong** the last good numbers stay on the bar and the tooltip
  says so, together with the reason: a missing key, a rejected key, an unreachable
  API, a request to slow down, or an answer that could not be read.
- **Debugging.** The panel logs one line when it loads and the service logs the
  reason for every failure, both prefixed `NaN Usage`. Grep Noctalia's log for that
  (where it writes one depends on how the shell was started on your setup). Noctalia
  also logs every prop or control it skips. If the bar shows a dash, the tooltip
  names the reason first. If the NaN mark never appears, this Qt build has no image
  support: turn `show_icon` off and `show_glyph` on instead.
- **Community project, not official**: not affiliated with or endorsed by
  nan.builders. "NaN" and its logo belong to their owners, and the logo shipped here,
  the SVG the rasters are drawn from, derives from their public favicon.
  MIT-licensed.

## Tests

Run from this directory:

```sh
lua tests/shared_test.lua          # the model, under a fixed clock, with no host
lua tests/plugin_test.lua          # the three entries against stubs of the API
python3 tests/plugin_check.py      # reads the manifest, the translations and the scripts
```

The first is the model on its own: levels, the pace, the token and credit splits and
every text, asserted exactly, against a copy of a real answer. That is only possible
because the model takes the current time as an argument instead of reading a clock.

The second drives the real `service.luau`, `bar.luau` and `panel.luau` under a fixed
clock: that the poller reads the key, asks `/v1/usage` and nothing else, follows a
second page, publishes what came back and keeps the last good numbers when a poll
fails; that the widget and the panel paint that data, with every gauge; that the
only thing ever spawned is the browser opener, and only when a link button is
pressed; and that a refresh is asked for over the shared state channel rather than
by running a program.

The third is static, and needs Python 3.11 or newer for its TOML reader: the
manifest against its own translation keys, the plugin directory against its id, and
every API member, `ui` control, `ui` prop, callback and translation key the scripts
use against Noctalia's own definitions, which it downloads. The check is skipped
without network. It also refuses a `local` function called above its own definition,
which is a nil global at runtime.
