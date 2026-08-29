# AI Usage

Your AI plan quota in the Noctalia bar: how much of the window is spent, when it
resets, and whether you are burning it faster than the clock.

The numbers come from [ai-usagebar](https://github.com/akitaonrails/ai-usagebar),
a Rust CLI that reads Claude, Codex, Cursor, Antigravity, Kiro, Z.AI,
OpenRouter, DeepSeek, Kimi and Grok, among others. This plugin never talks to a
provider, holds a token, or reads a credential file. It runs
`ai-usagebar usage --json` and draws the answer.

## Plugin

| Field | Value |
| --- | --- |
| ID | `felipeartur/ai-usagebar` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `poller` |

## Requirements

Install `ai-usagebar` on `PATH`. The plugin runs it by name, so there is no path
setting to fill in. It ships as `ai-usagebar-bin` on the AUR, and as release
tarballs on the project's GitHub Releases page. Configure your providers once in
`~/.config/ai-usagebar/config.toml`; the CLI owns the credentials and the
endpoints, and this plugin never sees them.

`xdg-open` is optional. The panel spawns it for one button, the link to the
CLI's project page it offers when `ai-usagebar` is not on `PATH`. Without
xdg-utils the panel leaves that button out and nothing else changes.

The plugin asks for **plugin API 22**, which is where Noctalia gained
`require()`. On a shell older than that it will not install. Version 1.1.0 asked
for API 9 and still runs there.

## Usage

Add `felipeartur/ai-usagebar:bar` to a bar in Settings, Bar. The capsule shows
one provider's headline percentage next to that provider's mark. The reading
sits in the bar's own colour while there is room, picks up the theme's
`secondary` when the CLI calls the window high, and `error` when it calls it
critical. The mark itself never changes colour: it says which provider, not how
full the plan is.

Left on `Automatic`, the capsule follows the busiest provider, so what sits in
the bar is the plan closest to running out. Raise `provider_limit` and it
carries the next busiest ones too, with a `+N` for whatever did not fit. Pin a
provider instead, or add the widget twice, when you want two fixed plans side by
side.

The capsule is put together the way the core `sysmon` widget is, with the same
key names, so the CPU reading beside it is configured with the same vocabulary.
`visualization` draws a `gauge`, a quota bar over a thinner bar for how much of
the window has gone, so a longer fill than clock is spend running ahead, or
`none`. `show_value`, `show_glyph` and `glyph_position` decide whether the
percentage and the icon are there and which side the icon sits on.

`extras` puts the time left in the window (`3h 51m`), the pace against the
clock (`↑3` is three points ahead of where the window says you should be, `↓3`
is three under), both, or neither.

If you add the widget by hand in `config.toml`, give it a name. A bar list entry
that is a raw widget id becomes an anonymous instance, and an anonymous instance
has no settings of its own, so the gear opens empty:

```toml
[widget.ai_usage]
type = "felipeartur/ai-usagebar:bar"
visualization = "gauge"
provider_limit = 2

[bar.default]
start = [ "clock", "ai_usage" ]
```

- **Hover** lists every window that provider reports: value, time left, and the
  clock time the reset lands on.
- **Left click** opens the `AI Usage` panel for the provider that capsule
  tracks.
- **Right click** asks the poller for a read. One process serves every capsule,
  and it coalesces repeated clicks into at most one pending read, so holding the
  button down does not spawn a queue of processes.
- **Middle click** opens the widget's settings, as everywhere else in the shell.

Left and middle are the script's; right is a gesture binding, so it is listed in
the widget's settings and can be pointed at any other action, or at `none`.

The panel is a two-pane view. On the left is every provider you have set up,
with its headline percentage. On the right is the selected one in detail: one
card per reported metric, with a quota bar over a thinner "window elapsed" bar,
so a fill that outruns the clock bar means quota is burning ahead of pace.
Credit balances and free text rows the CLI reports get rendered as well.
Opening the panel asks the CLI for fresh numbers, and the detail pane says how
old the reading is. The refresh button in the header asks again; it turns into
a spinner while the CLI is answering. The gear beside it opens this plugin's
settings. There is no close button: the panel closes when you click away from
it or press the same widget again.

The list follows the CLI. A provider the CLI reports no API key for never
appears, because it was never set up. One that is set up and unreachable keeps
its row and shows the CLI's own words, so Antigravity with its local server
down says to open Antigravity rather than vanishing.

The detail pane spells out what the CLI reports for that provider instead of
implying it: the plan and account name, when it was fetched, a stale flag when
the reading is old, and the status when it is anything other than a healthy
read. Each window gets its label, the percentage, the raw value string when
that says more than the percentage, how much of the window has elapsed, the
time left with the clock time (or date) its reset lands on, the pace line, and
the severity as a word whenever the CLI calls the window high or critical.
Credit blocks and free text rows appear as the CLI writes them.

To open the panel from a terminal:

```sh
noctalia msg panel-toggle felipeartur/ai-usagebar:panel
```

## Settings

Plugin-level, shared by the poller, every capsule and the panel:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_minutes` | `int` | `5` | Minutes between CLI calls, from 1 to 120. Countdowns tick locally in between. |

Per widget instance, so two capsules can follow two providers:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `vendor` | `select` | `auto` | Which plan this capsule tracks. `auto` follows the busiest provider, with the CLI's own `[ui] primary` breaking ties. |
| `visualization` | `select` | `none` | `gauge` or `none`, as described above. |
| `show_value` | `bool` | `true` | Show the percentage as text. |
| `show_glyph` | `bool` | `true` | Show the provider's icon. |
| `glyph_position` | `select` | `before` | `before` or `after` the reading. |
| `provider_limit` | `int` | `1` | How many providers one capsule carries, busiest first, from 1 to 4. Only applies on `auto`. |
| `extras` | `select` | `countdown` | What rides beside the percentage: `countdown`, `pace`, `both` or `none`. |
| `show_name` | `bool` | `false` | Adds the product name, so two capsules do not look alike. |
| `color_by_usage` | `bool` | `true` | Off drops the high and critical tint, so the capsule never changes colour. |

## IPC

Force a refresh without waiting for the interval:

```sh
noctalia msg plugin felipeartur/ai-usagebar:poller all refresh
```

Point the panel at a provider, by the id `ai-usagebar` uses for it:

```sh
noctalia msg plugin felipeartur/ai-usagebar:poller all select anthropic
```

## Notes

- One process, `ai-usagebar usage --json`, spawned by a single headless service
  on the configured interval, plus on demand from a right click, from opening
  the panel, or from the IPC event above. Capsules and the panel are subscribers
  of plugin state, so a second monitor or a second capsule costs no extra
  process.
- The plugin makes no network calls and writes no files of its own. Everything
  it knows arrives on that command's stdout.
- A provider that fails still comes back as an entry with `status = "error"`, so
  one broken provider does not blank the others. A reading the CLI marks stale
  keeps showing, flagged by an icon in the list, the capsule, and the panel's
  detail pane.

## Tests

Everything the CLI prints is redacted on its way to the screen, and that is the
part worth a test. From the `ai-usagebar` directory:

```sh
lua tests/scrub_test.lua
lua tests/refresh_test.lua
```

The first test reads `safeText` and `scrub` out of `service.luau` rather than
copying them, then checks that real credential shapes never survive, that ordinary
readings pass through unchanged, and that scrubbing a four-vendor report stays
inside the CPU budget the poller's async callback is given. The second exercises
the coalesced refresh state and checks that every provider it knows about has a
glyph of its own rather than the fallback. An overrun in the first test loses the whole reading, not just time.
