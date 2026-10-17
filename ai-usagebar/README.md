# AI Usage

Track AI plan usage, quota resets, and consumption pace in the Noctalia bar.

The numbers come from [ai-usagebar](https://github.com/akitaonrails/ai-usagebar),
a Rust CLI that reads Claude, Codex, GitHub Copilot, Cursor, Antigravity, Kiro,
Z.AI, Nous Research, OpenCode Go, Command Code, OpenRouter, DeepSeek, Kimi and Grok, among
others. The selector also includes DeepInfra, Grok Bot, Ollama Cloud, OrcaRouter,
Model Studio, Lyceum, Devin, Cline, Muse Code and Synthetic. The plugin runs
`ai-usagebar usage --json` and displays the report.
The provider catalog is read separately with `ai-usagebar vendors --json` when requested.
It does not call provider APIs or read credential files.

## Plugin

| Field | Value |
| --- | --- |
| ID | `felipeartur/ai-usagebar` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `poller` |

## Requirements

Install `ai-usagebar` on `PATH`. The plugin runs it by name and has no separate
path setting. It ships as `ai-usagebar-bin` on the AUR, and as release
tarballs on the project's GitHub Releases page. Configure your providers once in
`~/.config/ai-usagebar/config.toml`; the CLI manages credentials and provider
connections.

The plugin accepts the optional fields in ai-usagebar 1.40.1, including
Antigravity model pools and Synthetic. Older CLI reports remain supported; a
provider appears only when the installed CLI can report it. Since 1.40.1, the CLI
may run `agy -p "/quota" --output-format json` when `agy` is installed to read
Antigravity quotas. The plugin does not start or configure `agy` itself.

The CLI can send its own quota notifications when this plugin polls it. To
disable them, add this to `~/.config/ai-usagebar/config.toml`:

```toml
[notifications]
enabled = false
```

When the CLI is missing, the panel displays its project address and can open it
with `xdg-open`. The same command opens provider dashboards from the panel.
Install `xdg-open` alongside `ai-usagebar`.

The plugin requires plugin API 32 for container tooltips and shared modules.
It will not install on an older shell. Plugin version 1.1.0 remains available for API 9.

The main readings and provider icons follow the shell's typography and bar scale.
Text also follows the configured font family, weight and font scale. Countdown and
pace remain smaller secondary readings.

## Usage

Add `felipeartur/ai-usagebar:bar` to a bar in Settings, Bar. The capsule shows
one provider's headline reading beside its icon. Readings use the bar's text
color, the theme's `secondary` color for high usage, and `error` for critical
usage. Icons keep their normal color unless a read fails.

A provider that reports a balance instead of a quota (DeepSeek, Kilo, Novita,
Moonshot, and Nous top-up credits) has no percentage to draw: the capsule prints
that balance where a quota vendor prints its percentage. When the CLI selects a
monetary value as the headline, the capsule keeps that amount even if a supporting
percentage is available. Used/remaining changes quota readings, not money.

`Automatic` selects by headline severity, then usage. Raise `provider_limit` to
show more providers; limits above one also show `+N` for providers that do not
fit. Pin a provider or add another widget instance to keep particular plans
visible.

Named accounts use the label from the CLI config. Pick the provider and put the
label in `account`: `vendor = "openai"` with `account = "work"` follows the
`openai@work` report entry. Leave it empty for the provider's default account.

Settings use the same names as the core `sysmon` widget. Set `visualization` to
`gauge` for short-window usage above a thinner long-window usage bar, or
`none` to hide the bars. A provider with one available window shows one bar. `show_value`,
`show_glyph` and `glyph_position` control the percentage and icon placement,
including Antigravity's individual model readings. Provider groups use a subtle
divider; models within one provider use dots. Enable `show_name` to distinguish
the shared model groups. Names remain bounded so they do not take over the bar.

`extras` adds the reset countdown (`3h 51m`), consumption pace (`↑3` means three
percentage points ahead of elapsed time; `↓3` means three behind), both, or
neither. Countdowns show days and hours from 24 hours onward, and hours and
minutes below that.

When editing `config.toml` by hand, create a named instance. A raw widget id in
the bar list creates an anonymous instance with no settings of its own:

```toml
[widget.ai_usage]
type = "felipeartur/ai-usagebar:bar"
visualization = "gauge"
provider_limit = 2
quota_window = "weekly"
auto_providers = [ "openai", "antigravity" ]

[bar.default]
start = [ "clock", "ai_usage" ]
```

- Hover shows a compact summary of at most ten rows, with each quota window and
  its reset countdown on its own line. Open the panel for all windows, models and diagnostics.
- When a long window is exhausted, the capsule replaces the short-window value
  with `100%` and counts down to the blocking window's reset. If several windows
  are exhausted, it uses the latest reset. A critical warning below 100% does
  not count as exhaustion.
- Left click opens the `AI Usage` panel for the provider that capsule
  tracks.
- Right click requests a refresh. One poller serves every capsule and keeps at
  most one pending refresh when requests arrive during a read.
- Middle click opens the widget's settings, as everywhere else in the shell.

The script handles left and middle clicks. Right click is a gesture binding in
the widget settings, where you can assign another action or choose `none`.

The panel shows provider tabs at the top and the selected provider's limits
below. With more than three providers, tabs show icons only and reveal names on
hover. Session and weekly limits share a card; Antigravity has a separate card
for each model. Each window shows its quota bar, a short reset countdown and reported consumption pace.
Hover the countdown for the local reset time. A thinner bar compares quota with
reported window time: elapsed in used mode, time left in remaining mode.
Hover the window label for its time percentage. The thin bar stays hidden when
the CLI supplies no window time.
The shared `Claude & GPT OSS` quota keeps the name supplied by the CLI.

The footer shows the update time and quota warnings above 50% usage, with one
compact pill per model showing its most restrictive window. Hover a pill for
its full status. Exhausted quotas also show their reset countdown.
Read failures show the last known state. The panel displays quota readings,
not agent process health.

The header stays fixed while longer reports scroll. Every provider reserves the
same space beside its cards, so the scrollbar does not change their width.

Opening the panel requests fresh data. The header keeps refresh and close within
reach. Open the **⋯** actions for diagnostics, copying a summary, the selected
quota service and plugin settings. Both Antigravity model groups share the same
service link. Click outside or click the widget again to close the panel.

The list contains only providers with a usable reading. A provider the CLI
reports no API key for never appears, because it was never set up. A configured
provider with its own refresh failure also leaves the bar and panel, then
returns automatically after a healthy read. Model-specific Gemini pools, such as
Gemini 4 Argon, appear inside the Gemini card with their own name, reset and usage. They do not add a separate bar reading.
A full Gemini 4 Argon pool does not mark Antigravity as
exhausted while its shared windows remain available. The panel sorts providers by headline
severity, then usage; equal readings keep the CLI's order. Automatic bar selection
uses the same priorities, then the configured primary provider and account id.

Antigravity is the exception when its local server briefly disappears: the last
reading stays visible with a stale indicator and its original update time until
the server returns. Without an earlier reading, it stays unavailable.

Parser errors are an exception: the provider remains visible with missing usage
and the CLI error, because a response-format failure does not establish that the
account is unavailable.

Details include the plan and account name, reading age, stale status, window
labels, percentages, elapsed time, reset countdowns and local reset times, pace,
and high or critical severity labels. Raw values appear when they add information
to the percentage. Credit blocks and free text are also shown; zero credit
balances are hidden. Codex reset credits show the reset type and expiry on
separate lines, with wrapping for longer descriptions.

Cursor On-Demand spending has its own meter when the CLI reports a positive cap
and percentage. Its currency amount stays visible; used/remaining does not invert
spending. An uncapped amount stays text. Synthetic shows the subscription quota
and request count supplied by the CLI, without assuming a reset window.

A whole-report failure is different: it cannot identify one broken provider,
so it keeps the last list and marks those readings as old instead of blanking
the panel during a network interruption.

To open the panel from a terminal:

```sh
noctalia msg panel-toggle felipeartur/ai-usagebar:panel
```

## Settings

Plugin-level, shared by the poller, every capsule and the panel:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_minutes` | `int` | `5` | Minutes between quota calls, from 1 to 120. Countdowns tick locally in between. |
| `usage_display` | `select` | `used` | Show `used` or `remaining` quota in every capsule and the panel. Numbers and gauges change together; colors and priority still follow consumption. Balances are unchanged. |

Per widget instance, so two capsules can follow two providers:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `vendor` | `select` | `auto` | Which plan this capsule tracks. `auto` follows the busiest provider, with the CLI's own `[ui] primary` breaking ties. |
| `account` | `string` | empty | Optional named account label from the CLI config. Ignored on `auto`. |
| `quota_window` | `select` | `auto` | Keep the default windows, or choose `session`, `weekly` or `monthly`. An exhausted window takes priority. A window the provider does not report shows no percentage. |
| `auto_providers` | `string_list` | `[]` | Limit automatic selection, scroll and `+N` to these provider or account IDs. A provider ID includes all its accounts; `provider@account` selects that account. Empty includes all. Ignored for a pinned provider. |
| `visualization` | `select` | `gauge` | `gauge` or `none`, as described above. |
| `show_value` | `bool` | `true` | Show the reported percentage or amount as text. |
| `show_glyph` | `bool` | `true` | Show the provider's icon. |
| `glyph_position` | `select` | `before` | `before` or `after` the reading. |
| `provider_limit` | `int` | `1` | How many providers one capsule carries, busiest first, from 1 to 4. Only applies on `auto`. |
| `extras` | `select` | `countdown` | Information beside the percentage: `countdown`, `pace`, `both` or `none`. |
| `show_name` | `bool` | `false` | Show the provider name, or each model name for Antigravity. Long names are shortened; tooltips keep the full label. |
| `color_by_usage` | `bool` | `true` | Color readings by quota severity. Turning it off does not hide error indicators. |

## Diagnostics

Open **⋯ → Diagnostics** to find out why a configured provider is missing or
showing an old reading. Problems appear first, with the reported problem, its
impact on the widget and a suggested next step. Named account failures retain
the account label. Technical causes expand with **Details** inside the scrolling
view, one problem at a time. They do not open a popup over the card. Other enabled
providers and disabled providers stay collapsed
until requested. Finding credentials does not establish that an account can
authenticate; Antigravity needs no separate API key.

Opening this view reads the local provider catalog. Its refresh control updates
that catalog; **Refresh usage** explicitly requests a quota read through the
shared poller. The view never signs in, changes configuration or executes commands
from the response. If the CLI does not support `vendors --json` (available since
1.13.0), the catalog remains unavailable; known failures from the usage report
can still appear.

The existing IPC context opens Diagnostics directly:

```sh
noctalia msg panel-open felipeartur/ai-usagebar:panel setup
```

The CLI also owns quota alerts. Configure them in its `config.toml`; setting
`[notifications] enabled = false` disables them. The plugin adds no notification
system or second set of alert thresholds.

## IPC

Force a refresh without waiting for the interval:

```sh
noctalia msg plugin felipeartur/ai-usagebar:poller all refresh
```

Point the panel at a provider, by the id `ai-usagebar` uses for it:

```sh
noctalia msg plugin felipeartur/ai-usagebar:poller all select anthropic
```

Request a provider catalog read without polling quotas:

```sh
noctalia msg plugin felipeartur/ai-usagebar:poller all catalog
```

## Notes

Tooltips use the shell's native appearance, timing and position. They do not
capture pointer clicks or keyboard focus. Panel tips stay on small controls and
labels; long technical details require an explicit click inside Diagnostics.

- One process, `ai-usagebar usage --json`, spawned by a single headless service
  on the configured interval, plus on demand from a right click, from opening
  the panel, or from the IPC event above. Capsules and the panel are subscribers
  of plugin state, so a second monitor or a second capsule costs no extra
  process.
- Diagnostics adds a separate `ai-usagebar vendors --json` process on demand,
  with a five-second timeout and one query in flight. It contacts no provider
  endpoint. The CLI may enforce restrictive permissions on its own configuration
  file when loading it, as it does for quota reads.
- Custom providers can use a known brand icon supplied by the CLI. Unknown brands
  use the provider fallback. Brand metadata never chooses a dashboard URL.
- The plugin makes no network calls and writes no files of its own. Everything
  it knows arrives on those commands' stdout. Catalog state retains only provider
  names, IDs and configuration flags, without login commands or environment fields.
- A provider whose service is down leaves the bar and panel on the first report
  that says so, except for Antigravity's temporary local-server loss described
  above. It is not counted behind the `+n`, and returns when a report carries a
  healthy reading for it again.
- A failed whole-report read keeps the previous report and marks it as stale.
  Without a previous report, the panel shows the failure and its scrubbed
  diagnostic. Raw HTTP details stay out of the reading cards.
- Report text is scrubbed for common credential patterns before publication to
  plugin state. This is a precaution, not a guarantee that arbitrary CLI output
  contains no sensitive data. Review account labels and diagnostics before
  sharing screenshots.

## Tests

Run the tests from the `ai-usagebar` directory:

```sh
lua tests/scrub_test.lua
lua tests/refresh_test.lua
lua tests/bar_test.lua
lua tests/panel_test.lua
TZ=America/New_York lua tests/shared_test.lua
lua tests/catalog_test.lua
```

The first test reads `safeText` and `scrub` out of `service.luau` rather than
copying them, then checks that real credential shapes never survive, that ordinary
readings pass through unchanged, and that scrubbing a four-vendor report stays
inside the CPU budget the poller's async callback is given. The second exercises
the coalesced refresh state, rejects output from a timed-out process, checks
quiet quota changes, and checks that every provider has a glyph of its own.
The third drives the real bar script through default, named, missing and automatic
account selection, plus malformed metrics. The fourth checks that malformed panel
sections degrade safely, temporal bars follow used/remaining mode, and secondary
actions stay collapsed until requested. The fifth verifies UTC parsing through a daylight-saving
transition. An overrun in the first test loses the whole reading, not just time.

The catalog test checks on-demand collection, a whitelist of public fields,
older CLI failures, timeout handling and isolation from quota polling.
