# CodexBar Meter

CodexBar Meter is a native Noctalia v5 bar widget and attached panel for usage
limits reported by the local [CodexBar](https://github.com/steipete/CodexBar)
CLI. It discovers the providers enabled in CodexBar, keeps the bar compact,
and exposes every provider and quota window in a scrollable panel.

## Plugin

| Field | Value |
| --- | --- |
| ID | `salemsayed/codexbar-meter` |
| Entries | Bar widget: `bar`; panel entries: `panel-compact`, `panel`, `panel-tall` |

## Requirements

Install these commands on `PATH`:

- `codexbar` 0.47 or newer, configured with at least one provider.
- `timeout` from GNU coreutils.

CodexBar owns provider authentication, network access, and provider discovery.
The plugin does not read or store provider credentials.

## Usage

Add `salemsayed/codexbar-meter:bar` to a Noctalia bar. The bar shows up to two
provider meters by default, followed by a `+N` count when more providers are
enabled in CodexBar. The tooltip includes all returned providers.

- Left-click opens the attached `CodexBar Meter` panel. The widget chooses a
  compact, standard, or tall panel tier from the current provider payload;
  each tier keeps scrolling as the safety net for unusually large responses.
- Right-click refreshes usage immediately.
- The panel refresh button requests a fresh CodexBar query.
- The panel close button dismisses the panel.

To open the standard panel from a terminal:

```sh
noctalia msg panel-toggle salemsayed/codexbar-meter:panel
```

The adaptive widget also uses these panel entries when opening from the bar:

- `noctalia msg panel-toggle salemsayed/codexbar-meter:panel-compact` — 390 px
- `noctalia msg panel-toggle salemsayed/codexbar-meter:panel` — 560 px
- `noctalia msg panel-toggle salemsayed/codexbar-meter:panel-tall` — 720 px

The panel renders all provider cards and scrolls when the response is taller
than the panel. It understands CodexBar's standard primary, secondary, and
tertiary windows, named `windows` and `extraRateWindows`, credits, pace
summaries, provider status, stale data, and per-provider errors. Unknown
providers receive a readable title, a neutral icon, and a theme-derived color.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `codexbarPath` | `string` | `codexbar` | Command or absolute path used to query CodexBar. |
| `refreshIntervalSec` | `int` | `60` | Background refresh interval in seconds; allowed range is 30–3600. |
| `barProviderLimit` | `int` | `2` | Number of provider meters shown in the bar; allowed range is 1–4. The panel and tooltip always include all providers. |

When no provider flag is supplied, CodexBar's configured enabled-provider list
is used. This lets the plugin work with any current or future CodexBar
provider without changing the Noctalia code.

## IPC

Refresh the widget and panel through the shared plugin state:

```sh
noctalia msg plugin salemsayed/codexbar-meter:bar all refresh
```

## Notes

- The plugin runs `timeout 30s <codexbarPath> usage --format json --json-only`.
- A provider-level error is kept as a card beside healthy providers. If a
  refresh returns no usable JSON, the last successful response remains visible
  with an explicit warning.
- The plugin is compositor-agnostic: it uses Noctalia's attached layer-shell
  panels and theme roles rather than hard-coded light or dark colors, and calls
  no compositor IPC of its own. Developed on Niri.
- The plugin writes no files and opens no network connections of its own. The
  panel displays the account identity CodexBar reports for a provider, such as
  the signed-in email address. CodexBar itself owns provider authentication,
  credential storage, and all network access.
