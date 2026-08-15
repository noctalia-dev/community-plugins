# AI Usage

Your AI plan quota in the Noctalia bar: how much of the window is spent, when it
resets, and whether you are burning it faster than the clock.

The numbers come from [ai-usagebar](https://github.com/akitaonrails/ai-usagebar),
a Rust CLI that already knows how to read Claude, Codex, Cursor, Antigravity,
Kiro, Z.AI, OpenRouter, DeepSeek, Kimi, Grok and friends. This plugin never
talks to a provider, holds a token, or reads a credential file: it runs
`ai-usagebar usage --json` and draws the answer.

## Plugin

| Field | Value |
| --- | --- |
| ID | `felipeartur/ai-usagebar` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `poller` |

## Requirements

Install `ai-usagebar` on `PATH` — the plugin runs it by name, with no path
setting to fill in (`ai-usagebar-bin` on the AUR, or the release tarballs from
the project's GitHub Releases). Configure your providers once in
`~/.config/ai-usagebar/config.toml` — the CLI owns credentials and endpoints,
this plugin never sees them.

## Usage

Add `felipeartur/ai-usagebar:bar` to a bar in Settings → Bar. The capsule shows
the headline percentage of one provider, colored by the severity the CLI
reports: calm while there is room, amber past 75%, red past 90%. Add the widget
a second time and point it at another provider to watch two plans at once.

- **Hover** lists every window that provider reports: value, time left, and the
  clock time the reset lands on.
- **Left click** opens the `AI Usage` panel for the provider that capsule
  tracks.
- **Right click** refreshes immediately.
- **Middle click** opens the widget's settings, as everywhere else in the shell.

The panel shows one card per reported metric: a quota bar over a thinner
"window elapsed" bar, so a fill that outruns the clock bar is quota burning
ahead of pace. Credit balances and free-text rows the CLI reports are rendered
too, not dropped. Its refresh button asks the CLI for fresh numbers, and the
footer says how old the current reading is.

To open the panel from a terminal:

```sh
noctalia msg panel-toggle felipeartur/ai-usagebar:panel
```

## Settings

Plugin-level, shared by the poller, every capsule and the panel:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refreshMinutes` | `int` | `5` | Minutes between CLI calls, 1–120. Countdowns tick locally in between. |

Per widget instance, so two capsules can follow two providers:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `vendor` | `select` | `auto` | Which plan this capsule tracks. `auto` follows `[ui] primary` from the CLI's own config, then the first provider that reported. |
| `style` | `select` | `pill` | `pill` is the percentage alone; `gauge` adds a small bar next to it. |
| `showName` | `bool` | `false` | Adds the product name, so two capsules do not look alike. |
| `colorByUsage` | `bool` | `true` | Off keeps the capsule in the bar's own text color instead of tinting by severity. |

## IPC

Force a refresh without waiting for the interval:

```sh
noctalia msg plugin felipeartur/ai-usagebar:poller all refresh
```

## Notes

- One process, `ai-usagebar usage --json`, spawned by a single headless service
  on the configured interval, plus on demand from a right click, the panel's
  refresh button, or the IPC event above. Capsules and the panel are
  subscribers of plugin state, so a second monitor or a second capsule costs no
  extra process.
- No network calls and no filesystem writes of its own. Everything the plugin
  knows arrives on that command's stdout.
- A provider that fails still comes back as an entry with `status = "error"`,
  so one broken provider does not blank the others. A reading the CLI marks
  stale keeps showing, flagged in the capsule and in the panel footer.
