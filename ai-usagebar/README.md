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

`xdg-open` is optional. It is spawned by one row in the panel, the link to the
CLI's project page offered when `ai-usagebar` is not on `PATH`. Without
xdg-utils that row does nothing and the rest of the plugin is unaffected.

## Usage

Add `felipeartur/ai-usagebar:bar` to a bar in Settings, Bar. The capsule shows
the headline percentage of a provider, behind that provider's icon. It reads in
the bar's own colour while there is room, picks up the theme's `tertiary` when
the CLI calls the window high, and `error` when it calls it critical. The accent
stays on the gauge fill, so a calm capsule looks like the widgets beside it.

Left on `Automatic`, the capsule follows the busiest provider, so what sits in
the bar is the plan closest to running out. Raise `provider_limit` and it
carries the next busiest ones too, with a `+N` for whatever did not fit. Pin a
provider instead, or add the widget twice, when you want two fixed plans side by
side.

Four styles, all with the same reading:

| Style | Shape |
| --- | --- |
| `pill` | Icon and percentage. The compact one. |
| `gauge` | Icon, a small quota bar over a thinner "window elapsed" bar, percentage. |
| `meter` | Icon and five segments, filled in twenties, with no percentage. |
| `label` | Icon, provider name and percentage stacked over the bars. |

Next to that, `extras` puts the time left in the window (`3h 51m`), the pace
against the clock (`↑3` is three points ahead of where the window says you
should be, `↓3` is three under), both, or neither.

If you add the widget by hand in `config.toml`, give it a name. A bar list entry
that is a raw widget id becomes an anonymous instance, and an anonymous instance
has no settings of its own, so the gear opens empty:

```toml
[widget.ai_usage]
type = "felipeartur/ai-usagebar:bar"
style = "gauge"
provider_limit = 2

[bar.default]
start = [ "clock", "ai_usage" ]
```

- **Hover** lists every window that provider reports: value, time left, and the
  clock time the reset lands on.
- **Left click** opens the `AI Usage` panel for the provider that capsule
  tracks.
- **Right click** refreshes immediately.
- **Middle click** opens the widget's settings, as everywhere else in the shell.

The panel is a two pane view. On the left is every provider you have set up,
with its headline percentage. On the right is the selected one in detail: one
card per reported metric, with a quota bar over a thinner "window elapsed" bar,
so a fill that outruns the clock bar means quota is burning ahead of pace.
Credit balances and free text rows the CLI reports get rendered as well.
Opening the panel asks the CLI for fresh numbers, and the header says how old
the reading is. There is no refresh button and no close button: the read
happens on open, and the panel closes when you click away from it or press the
same widget again.

The list follows the CLI. A provider that `ai-usagebar` has no credential for
never appears, while one that is set up and failing keeps its row and shows the
error.

The detail pane spells out everything the CLI reports for that provider instead
of implying it: the plan and account name, the provider id, its status, a stale
flag when the reading is old, and when it was fetched. Each window gets its
label, the severity the CLI assigned it, the percentage, the raw value string
when that says more than the percentage, how much of the window has elapsed, the
time left with the clock time (or date) its reset lands on, and the pace line.
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
| `style` | `select` | `pill` | `pill`, `gauge`, `meter` or `label`, as described in the table above. |
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
  keeps showing, flagged in the capsule and in the panel header.
- The file watcher follows the `.luau` entries only, so the files in
  `translations/` are read once, when the plugin loads. Editing a string takes
  a reload before the new text shows up:

  ```sh
  noctalia msg plugins disable felipeartur/ai-usagebar
  noctalia msg plugins enable felipeartur/ai-usagebar
  ```
