# AI Usage

Your AI plan quota in the Noctalia bar: how much of the window is spent, when it
resets, and whether you are burning it faster than the clock.

The numbers come from [ai-usagebar](https://github.com/akitaonrails/ai-usagebar),
a Rust CLI that already knows how to read Claude, Codex, Cursor, Antigravity,
Kiro, Z.AI, OpenRouter, DeepSeek, Kimi, Grok and friends. This plugin never
talks to a provider, holds a token, or reads a credential file: it runs
`ai-usagebar usage --json` and draws the answer.

## Requirements

`ai-usagebar` on your `PATH` (`ai-usagebar-bin` on the AUR, or the release
tarballs). Configure your providers once in
`~/.config/ai-usagebar/config.toml` — the CLI owns credentials, this plugin
never sees them.

## What you get

- **A bar capsule** per provider, showing the headline percentage, colored by
  the severity the CLI reports (calm, then amber past 75%, then red past 90%).
  Add the widget twice to watch two plans at once.
- **A tooltip** with every window the provider reports: value, time left, and
  the clock time the reset lands on.
- **A panel** on click, with one card per reported metric: a quota bar over a
  thinner "window elapsed" bar, so a fill that outruns the clock bar is quota
  burning ahead of pace. Credit balances and free-text rows the CLI reports are
  rendered too, not dropped.
- **Right click** refreshes immediately. Middle click opens the widget settings,
  as everywhere else in the shell.

## Settings

Plugin-level:

| Setting | Default | What it does |
| --- | --- | --- |
| `binPath` | `ai-usagebar` | Command or absolute path to the binary. |
| `refreshMinutes` | `5` | How often the CLI is called. Countdowns tick locally in between. |

Per widget instance:

| Setting | Default | What it does |
| --- | --- | --- |
| `vendor` | Automatic | Which plan this capsule tracks. Automatic follows `[ui] primary` from the CLI's own config. |
| `style` | Percentage | Percentage only, or a small gauge next to it. |
| `showName` | off | Adds the product name, so two capsules do not look alike. |
| `colorByUsage` | on | Off keeps the capsule in the bar's own text color. |

## What it runs

One process, `ai-usagebar usage --json`, from a single headless service on the
configured interval (plus on demand from a right click or the panel's refresh
button). Capsules and the panel are subscribers, so a second monitor or a second
capsule costs no extra process. No network calls, no filesystem writes.
