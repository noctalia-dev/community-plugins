# AI Triage

AI Triage is an intelligent AI quota monitoring, smart routing, and rolling session triage plugin for the Noctalia Wayland shell.

Built on top of the telemetry engine provided by [ai-usagebar](https://github.com/akitaonrails/ai-usagebar), AI Triage elevates basic quota numbers into actionable routing decisions, real-time pace analysis, and automated session priming.

**Version 1.8.0 adapts to Noctalia 5.4 with calibrated panel geometry and Material 3 palettes.**
The triage panel adopts `height = "content"` with a calibrated 560px maximum height,
eliminating vertical empty space for typical 1–4 provider configurations while preserving
independent per-column scrolling for extended lists, alongside updated `surface_container`
and `outline_variant` token roles.

**Version 1.7.4 suppresses false early-renewal notices on idle rolling windows.**
Rolling 7-day quotas (such as OpenAI Codex) that wake up at 0% usage with an unanchored
deadline (`now + 7d`) are correctly identified as floating idle windows rather than
unexpected early renewals, preventing daily false-positive alert banners and tooltip
notices when starting fresh sessions without spent reset credits.

**Version 1.7.3 uses real credit deadlines and configurable daily availability.**
Reset-credit priority follows the actual expiry, remaining work to reach 95% and
estimated refill value, with a one-hour availability margin. The weekly reset
keeps its own horizon. Fast-track tooltips show needed and available time.
Sleep boundaries accept half-hour steps such as `8.5` for 08:30. Additional daily
unavailable time is spread across waking hours without inventing meal or break
times. Weekly forecasts and sustainable pacing use the configured availability;
exceptional use during off-hours still receives a limited two-hour awake burst.
See the [availability and credit-deadline audit](docs/ai_usagebar_compatibility.md#availability-and-reset-credit-deadlines-in-173)
for behavior, limits and regression coverage.

**Version 1.7.2 adds visible reset-change notices and permanent event logs.**
Unexpected weekly changes show their previous and current announced dates at the
bottom of Resets & Credits for 24 hours after detection. Each event is archived for later analysis, including
the existing saved history. Old countdowns show `~`; expired or missing dates show
`Check` / `Pending confirmation` until the provider confirms a new schedule.
The poller checks at the announced deadline. No extra settings are added.
See the [renewal behavior, limits and regression coverage](docs/ai_usagebar_compatibility.md#weekly-renewal-observations-and-change-notices-in-172).

Version 1.7.0 added actionable failure diagnostics. Provider cards and bar
tooltips explain failed reads and recommend the next action, including a copyable
Claude sign-in command. See the [diagnostic behavior and validation](docs/ai_usagebar_compatibility.md#failure-diagnostics-in-170).

## Plugin

| Field | Value |
| --- | --- |
| ID | `miguelfm/ai-triage` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `poller` |

## Requirements

Install `ai-usagebar` on `PATH`. The plugin runs it by name and has no separate
path setting. It ships as `ai-usagebar-bin` on the AUR, and as release
tarballs on the project's GitHub Releases page. Configure your providers once in
`~/.config/ai-usagebar/config.toml`; the CLI manages credentials and provider
connections.

Compatibility checked against **ai-usagebar 1.43.0**, using its version 1 JSON
contract. All 30 built-in providers are available in the capsule selector.
The poller also requires coreutils `timeout`: quota reads may take up to three
minutes by default, allowing Antigravity's 90-second cold startup. Increase the
advanced query timeout for many accounts. See the [compatibility audit](docs/ai_usagebar_compatibility.md)
for coverage, limitations and repeatable checks.

When the CLI is missing or provider dashboards are clicked, the panel opens URLs
with `xdg-open`. Install `xdg-open` alongside `ai-usagebar`.

> [!NOTE]
> **Antigravity & Gemini Quota Endpoint & Telemetry Reconciliation**: For Google Antigravity to report Gemini quotas (both 5-hour session and 7-day weekly limits), `ai-usagebar` must query the production Cloud Code endpoint (`https://cloudcode-pa.googleapis.com`). Because Google's individual Cloud Code API fallback often returns synthetic 0% utilization for Gemini CLI sessions, AI Triage transparently reconciles Antigravity readings with the active local session telemetry (`agy-statusline` observation / `agy -p /quota`), accurately reflecting real 5-hour rolling session progress, true reset deadlines, and weekly utilization.

The plugin requires Noctalia 5.4 or newer (plugin API 43) for the current color
roles and content-sized panel. The panel fits shorter reports and empty/error
states, up to 560 logical pixels; longer columns scroll independently.

For the interactive rolling session kickstart feature (`[⚡ Start 5h]`), ensure `bin/ai-kickstart` is
accessible or placed on your PATH (e.g. `~/.local/bin/ai-kickstart`). The helper triggers rolling sessions via provider-specific CLI tools:
- `claude` (Anthropic Claude Code CLI) for Claude
- `codex` (OpenAI Codex CLI) for Codex
- `agy` (Antigravity CLI) for Gemini and Claude & GPT OSS
Install the respective CLI for any backend provider you wish to prime.

## Features

- **Schedule-Aware Human Activity Model**: Optimizes quota pacing against real working hours ($H_{\text{active}}$) rather than calendar time. Automatically discounts sleep hours, weekend rest patterns, and meal pauses. Dynamically adapts when coding late-night or out-of-schedule with an active awake burst window ($T_{\text{burst}} = 2.0\text{h}$). Quotas expiring in off-hours or before morning wake-up receive critical urgency bonuses to prevent perishable token loss.
- **Model Quota Gearing Ratios ($K_m$)**: Couples weekly quotas with 5h session limits based on how many full sessions fit in a weekly quota ($K_m = L_{\text{weekly}} / L_{\text{session}}$). Differentiates low-gearing models (e.g. Claude & GPT OSS, $K \approx 2.5$, where 1 session burns ~40% of the week) which require strict weekly conservation early in the cycle, from moderate-gearing models (e.g. Codex, $K \approx 6.3$, where 1 full session burns ~15.9%) that need pacing across both session and weekly quotas.
- **Rounded Session Estimates**: The panel displays estimated sessions as whole numbers for every provider. Calculations and automatic calibration retain the underlying decimal precision.
- **Multi-Provider & Antigravity Model Separation**: Full independent tracking for all supported providers, including dedicated cards and individual triage scoring for Antigravity's **Gemini** (Gemini 2.5 Pro / Flash) and **Claude & GPT OSS** (Claude 3.7 Sonnet, GPT-OSS) tiers.
- **Antigravity Local Session Telemetry Reconciliation**: Seamlessly bridges the gap between remote Cloud Code API defaults and active CLI sessions. When remote endpoints emit synthetic idle readings (0% utilization with floating 5h timers awaiting kickstart), the poller automatically enriches Antigravity metrics using local `agy` session status (from `agy-statusline` observation or `agy -p /quota`). This ensures active 5h rolling sessions are immediately detected, countdown timers reflect authentic reset moments, and triage burn urgency is calculated with precision.
- **Mathematical Triage & Prioritization Engine**: Dynamically ranks providers using a continuous optimization model that balances 5-hour rolling session exhaustion against 7-day weekly pace. Prioritizes under-utilized quotas, boosts providers with upcoming weekly resets ($\le 48\text{h}$) to avoid wasting expiring allocations, and enforces hard lockouts for exhausted quotas.
- **Interactive Session Priming (`ai-kickstart`)**: Providers with rolling windows (Claude, Codex, Antigravity) start their countdown when the first prompt is sent. The panel displays a `[⚡ Start 5h]` button to prime sessions at the start of your workday with a single click. Priming automatically persists in Noctalia state, immediately unlocks the active expiration clock (rather than an unstarted `--:--` placeholder), and is automatically suppressed for providers whose weekly quotas are already depleted.
- **Robust Rolling Window Detection**: Real-time detection of active rolling session clocks across all supported providers, ensuring countdowns and needle markers begin immediately upon usage.
- **Temporal Distribution & Anti-Burst Smoothing**: Prevents rapid quota concentration followed by availability droughts ("baleiros") by monitoring deviation from nominal weekly burn pace ($\Delta_{\text{pace}}$). Smoothly modulates priority early and mid-cycle to maintain continuous multi-service availability throughout the working week, while releasing all damping for the final sprint in the last 24 active hours.
- **Parallel Coordinated Session & Weekly Ranking**: Keeps Column 1 (5h Session) and Column 2 (7d Weekly) strictly synchronized row-by-row for unified per-service routing decisions based on comprehensive 5h, 7d, gearing, and reset credit factors.
- **Weekly Cycles Schedule & Imminent Renewal Alerts (Column 3)**: Disambiguates automatic 7-day natural renewal cycles from promotional on-demand reset credits. Column 3 features a dedicated schedule card with strictly aligned tabular layout: countdowns display days and hours (`Xd Yh`) with matching vertical alignment for both `d` and `h` units, followed by the exact reset day and clock time (`HH:MM`) with vertically aligned `:` separators across all rows. High-visibility alert cards appear whenever a weekly quota is expiring within $\le 48\text{h}$ with unused headroom.
- **Dynamic Upstream Weekly Horizon Alignment**: Accurately tracks rolling and anchor-based 7-day rate limit schedules across manual quota resets and promotional reset credits (e.g. Codex/OpenAI Banked Resets and Instant Resets). When an extra reset pulls the weekly allocation forward, the engine immediately synchronizes to the authentic upstream 7-day horizon, eliminating false sprint panics and ensuring mathematically optimal triage pacing and reliable countdowns.
- **Weekly Reset Change Notices & Logs**: Unexpected changes show a compact before/after notice for 24 hours at the bottom of Resets & Credits, below urgent alerts, the schedule and reset credits. Date-only changes explicitly leave renewal unconfirmed; scheduled renewals and drifting idle timers do not trigger notices. The last 32 events and per-account/window baselines remain in `weekly-resets.json`; permanent `weekly-reset-event-*.json` files preserve both readings, source, usage and reset-credit counts when available. Archive writes are atomic and failures are queued for retry. Existing saved events are archived on upgrade. Dates always come from the provider; unscheduled renewals cannot be predicted.
- **Reset Credit Collision & Staggering Engine**: Detects concurrent on-demand reset credit expirations across providers and keeps last-chance credits active. A separate, value-weighted incentive uses the real expiry and work remaining to reach 95%, reserving one available hour for claiming and at least one session to use the refill before natural renewal. Current session capacity is respected; exhausted providers stay blocked. Tooltips show needed/available time and identify potentially unreachable targets. Recommends claiming a reset (`⭐ Claim Reset`) once the week is spent ($\ge 95\%$) or when nearing expiration peril, with one-click dashboard access.
- **Streamlined Triage Panel**: An aligned, three-column ranking view displaying provider identity, dynamic urgency score, real-time status badges, weekly renewal timeline, and credit staggering strategy. The top row is always your optimal routing choice.
- **Service & Model Visibility Filtering**: Allows hiding specific sub-models or third-party tiers (such as Antigravity's "Claude & GPT OSS") via `hide_claude_oss` or `hidden_services` while retaining full visibility, pacing, and telemetry for other tiers like Gemini, Codex, or Claude Pro across both the status bar capsule and the triage panel. Hidden exhausted tiers are excluded from blocking warnings. When a pinned bar capsule targets a hidden tier or service, the capsule dynamically collapses (`barWidget.setVisible(false)`), reclaiming taskbar space without leaving empty gaps or fallback glyphs.
- **Provider Identity & Outage Resilience**: Transient outages (such as upstream HTTP 429 Rate Limits or connectivity interruptions) preserve the provider's recognizable icon and identity in error tint rather than falling back to an ambiguous scale icon, presenting actionable diagnostic tooltips on the bar and maintaining dedicated diagnostic cards within the triage panel.
- **Actionable Failure Diagnostics**: Failed providers stay visible in the panel with the cause, recommended action and original CLI detail. Missing or rejected Claude credentials show `claude auth login` and a copy button; rate limits, server outages, permissions, network failures and response format errors have separate guidance. Automatic bar tooltips retain these diagnostics alongside working providers, and successful refreshes clear them.
- **Adaptive Geometry & Native Scrolling**: Content-sized panel with a 560px maximum and per-column native scrolling (`ui.scroll`) for model cards, renewal timelines, and reset credits across typography presets (including Huge / 130%).

## Usage

Add `miguelfm/ai-triage:bar` to a bar in Settings, Bar. The capsule shows
one provider's headline reading beside its icon. Readings use the bar's text
color, the theme's `secondary` color for high usage, and `error` for critical
usage. Icons keep their normal color unless a read fails.

- **Left click**: Opens the AI Triage panel for the provider that capsule tracks.
- **Right click**: Requests an immediate quota refresh via background poller.
- **Middle click**: Opens widget settings.

To toggle or open the panel from a terminal or keybinding:

```sh
noctalia msg panel-toggle miguelfm/ai-triage:panel
```

Keyboard shortcuts inside the panel:
- `Escape`: Close panel.
- `r`: Force quota refresh.
- `Left` / `Right`: Navigate provider tabs.

## Settings

Plugin-level settings (shared across poller, capsules, and panel):

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_minutes` | `int` | `5` | Minutes between CLI calls (1 to 120). Countdowns tick locally in between. |
| `query_timeout_seconds` | `int` | `180` | *(Advanced)* Maximum wait for a quota report (30 to 600 seconds). Includes all providers and accounts. |
| `font_scale` | `select` | `"normal"` | Typographic scale preset across panel and bar (`compact` 85%, `normal` 100%, `large` 115%, `huge` 130%). |
| `schedule_aware_triage` | `bool` | `true` | Pace quota consumption against active working hours (discounting sleep and meals). |
| `sleep_start_hour` | `double` | `0` | Weekday off-hours start (0 to 23.5, half-hour steps). Visible when schedule-aware triage is enabled. |
| `sleep_end_hour` | `double` | `8` | Weekday active hours resume (0 to 23.5; `8.5` = 08:30). Visible when schedule-aware triage is enabled. |
| `weekend_sleep_start_hour` | `double` | `1` | Weekend off-hours start (0 to 23.5, half-hour steps). Visible when schedule-aware triage is enabled. |
| `weekend_sleep_end_hour` | `double` | `9` | Weekend active hours resume (0 to 23.5; `8.5` = 08:30). Visible when schedule-aware triage is enabled. |
| `meal_pause_hours` | `double` | `1` | Other daily unavailable hours for meals, breaks or tasks (0 to 24, half-hour steps), spread proportionally across waking hours without fixed break times. Visible when schedule-aware triage is enabled. |
| `hide_claude_oss` | `bool` | `false` | Hides the Claude & GPT OSS tier from Antigravity in both the bar and panel, keeping Gemini active. |
| `hidden_services` | `string` | `""` | *(Advanced)* Comma-separated list of provider or model IDs to hide from both bar and panel (e.g. `claude-oss, moonshot`). |
| `gearing_claude_oss` | `double` | `2.5` | *(Advanced)* Sessions per week for Claude & GPT OSS (1 session burns ~40% weekly quota). Calibrated dynamically by telemetry. |
| `gearing_gemini` | `double` | `8.0` | *(Advanced)* Sessions per week for Gemini (1 session burns ~12.5% weekly quota). Calibrated dynamically by telemetry. |
| `gearing_anthropic` | `double` | `7.0` | *(Advanced)* Sessions per week for Claude Pro (1 session burns ~14.3% weekly quota). Calibrated dynamically by telemetry. |
| `gearing_openai` | `double` | `6.3` | *(Advanced)* Sessions per week for Codex / OpenAI (1 session burns ~15.9%; estimated from usage telemetry). |
| `gearing_default` | `double` | `10.0` | *(Advanced)* Default sessions per week for unlisted models. |

Per-widget settings (configurable for each bar capsule):

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `vendor` | `select` | `auto` | Tracked provider (`auto`, `anthropic`, `openai`, `gemini`, `claude-oss`, `antigravity`, etc.). `auto` tracks the busiest plan. |
| `provider_limit` | `int` | `1` | Providers carried in one capsule (1 to 4). Visible only when provider is `auto`. |
| `account` | `string` | empty | *(Advanced)* Optional named account label from CLI config (`<provider>@<label>`). |
| `visualization` | `select` | `gauge` | Visual indicator style: `gauge` or `none`. |
| `color_by_usage` | `bool` | `true` | Color readings according to quota severity. |
| `show_value` | `bool` | `true` | Show percentage text. |
| `show_name` | `bool` | `false` | Show provider name beside reading. |
| `show_glyph` | `bool` | `true` | Show provider icon. |
| `glyph_position` | `select` | `before` | Icon position: `before` or `after`. Visible only when icon is enabled. |
| `extras` | `select` | `countdown` | Auxiliary info beside percentage: `countdown`, `pace`, `both`, or `none`. |
| `bar_font_scale` | `select` | `inherit` | Typographic preset for this capsule (`inherit`, `compact`, `normal`, `large`, `huge`). |

## IPC

Force an immediate quota check without waiting for the polling interval:

```sh
noctalia msg plugin miguelfm/ai-triage:poller all refresh
```

Point the panel at a specific provider:

```sh
noctalia msg plugin miguelfm/ai-triage:poller all select anthropic
```

## Documentation

For a comprehensive deep dive into the mathematical triage model, circadian active-hours pacing, model quota gearing ($K_m$), and reset credit collision desynchronization, see the [Internal Technical & Mathematical Specification](docs/mathematical_model.md).

## Development checks

Run the regression suites and the installed CLI's catalog/contract checks from
the repository root (Lua and Python 3.11+ required):

```sh
for test in tests/*_test.lua; do
  TZ=America/New_York lua "$test" || exit
done
python tests/check_ai_usagebar.py
noctalia plugins lint .
```

Add `--live` to the Python command to query configured providers and exercise
their real reports through the poller and bar/panel test hosts. The
[compatibility audit](docs/ai_usagebar_compatibility.md) records the tested
versions, corrections and coverage limits.

## License

MIT © [miguelfm](https://github.com/miguelfm)
