# Token Monitor user guide

## Provider icons

All 29 quota providers in Token Monitor 0.68.0 have matching brand marks or,
for generic third-party APIs, a plug icon. New API and Sub2API also get their
own marks when the Hub reports their `adapterId`. The icons use one monochrome
style, follow Noctalia's theme/status colors, and retain aligned 15px bar and
20px account-card slots. No extra font package or network access is needed.
The complete catalog, original SVGs, pinned sources, MIT attribution and
reproducible font builder are documented in [assets/README.md](../assets/README.md).

## Activity heatmap and compact details

Activity starts with a calendar heatmap, with Monday–Sunday rows and month
labels. Switch between 13/26 weeks and tokens, cost or messages directly in the
panel; the corresponding settings choose defaults. Click a recorded day for
its totals and expandable model/client breakdown. Daily selection stays daily
even when the list below is grouped by month.

Empty outlines mean no record; a neutral filled cell is an explicit zero.
An outlined secondary-color cell has a record but no value for the chosen
metric. Future calendar padding contains no inferred usage. Four intensity
bands are relative to the visible nonnegative maximum; the legend tooltip
reports the scale. Dates retain the producer's calendar labels, ending at the
local current date. Different devices can use different calendar boundaries.

The heatmap uses the already supported read-only `/api/history` daily buckets;
it adds no endpoint, scraping, inferred sessions or event-log compatibility.
Models and sessions use compact summary rows with optional details, and trend
bars preserve every plotted recorded value, including zero. Theme colors,
restrained selected states and the shared content grid keep all views aligned.

## First connection

For the usual same-computer setup:

1. In **Token Monitor**, open **Settings → Sync method → Host hub on this
   device**. Keep the application running. Its default **Local only** mode does
   not expose the HTTP Hub this plugin reads. Configure provider accounts in
   Token Monitor as usual; the plugin does not repeat those logins.
2. Enable **Token Monitor** in Noctalia and add its bar widget. Leave the Hub
   address at `http://127.0.0.1:17321` and automatic credential lookup enabled.
3. Open the panel and select **Test connection** to reread credentials and request both data endpoints
   afresh. **Stats** covers quota/usage data; **History** covers activity/trends.
   A cached snapshot cannot make a failed check appear successful. A partial
   failure leaves the available views usable.

The plug icon in the panel header reopens the guide at any time. Plugin options
appear in Noctalia's native flat settings list. The Hub URL and automatic
credential lookup are regular options, so basic setup can leave Noctalia's
**Advanced** switch off. To set **Credentials file override**, close the editor
if it is open, turn on **Advanced** at the top of Noctalia's settings, then
reopen the editor and set the option in the list. Configure options with the
panel gear or **Settings → Plugins → Token Monitor** and its gear. No hand-written
plugin JSON or TOML is needed; Noctalia saves these settings. Token Monitor
creates `credentials.json` for its own Hub secret storage when Host mode needs
it; this is not plugin configuration. No extra runtime packages or shell
commands are needed.

**Host** is a Token Monitor mode; **Hub** is the HTTP service it hosts. They are
not two separate switches. **Connect to a hub** is Token Monitor's client mode,
which sends this device's usage to another host. For a remote host, enter that
host's URL in the plugin, then set **Credentials file override** to a file
containing that remote Hub's secret. Local automatically discovered credentials
are never sent to a remote URL. Automatic port or remote-host discovery is not
attempted: set a custom port in the address.

For a Token Monitor installation in Distrobox, automatic lookup also checks up
to 32 immediate homes under `~/distrobox/`. For another container layout or a
custom credentials location, close the Token Monitor editor if it is open, turn
on **Advanced** at the top of Noctalia's settings, then reopen the editor. Set
**Credentials file override** to the credentials JSON or a plain single-line
secret file.

Automatic lookup checks, in order:

- `$XDG_CONFIG_HOME/Token Monitor/credentials.json`, when XDG_CONFIG_HOME is absolute;
- `~/.config/Token Monitor/credentials.json`;
- up to 32 immediate home folders under `~/distrobox/`, each at
  `<folder>/.config/Token Monitor/credentials.json`, in lexical order.

Duplicates are skipped. The first valid native JSON file with
`credentials.hub.hostSecret` wins. Token Monitor normally creates this secret
when Host mode first starts. Automatic lookup uses only `127.0.0.1`, `localhost`
and `[::1]` Hub URLs; redirects are disabled. It does not scan the whole home
folder, start containers, inspect CLI OAuth files, or change Token Monitor.
If multiple installations have different secrets, select the correct file in
**Credentials file override**. Unusual container homes require that same override.

A selected file always wins, even when invalid; it never silently falls back to
another file or anonymous access. Blank overrides with no discovered credential
try anonymous access, which works only when the Hub allows it. Files are reread
on every refresh, so rotating the Hub secret does not require copying it into
Noctalia settings. Automatic discovery can be disabled.

## Settings

Noctalia presents plugin options in its native flat settings list; custom native
settings sections are not supported. The **Connection**, **Display** and
**Refresh** headings below are documentation indexes only; they are not UI tabs
or a selector. Most users can keep Noctalia's
**Advanced** switch off. Advanced options are hidden by default; to show them,
close the editor if it is open, enable **Advanced** at the top of Noctalia's
settings, then reopen the editor.

### Connection

| Setting | Default | Access | Meaning |
| --- | --- | --- | --- |
| `hub_url` | `http://127.0.0.1:17321` | Regular | HTTP(S) origin of the Hub, without a path, query or embedded credentials |
| `auto_discover_credentials` | true | Regular | Find native/local Distrobox credentials for a loopback Hub when no file override is selected |
| `credentials_file` | empty | Advanced | Explicit file override; required for authenticated remote Hubs or unusual local paths |

### Display

| Setting | Default | Access | Meaning |
| --- | --- | --- | --- |
| `initial_view` | `quotas` | Regular | Initial tab: quotas, models, sessions, activity or trends |
| `bar_provider` | `codex` | Regular | Provider shown in the bar; other accounts remain available in the panel |
| `bar_window` | `first` | Regular | First, session, weekly, or lowest known remaining percentage; a missing requested kind shows unavailable |
| `bar_style` | `full` | Regular | Provider and value, value only, or icon only |
| `percentage_mode` | `remaining` | Regular | Display remaining or used quota, with matching labels and meters |
| `show_account_names` | true | Regular | Show account/session/project names; disabling also hides session IDs in the UI |
| `panel_density` | `compact` | Regular | Compact or comfortable card spacing and window preview length |
| `heatmap_weeks` | `half` | Regular | 26 calendar weeks; `quarter` shows 13 weeks with larger cells |
| `usage_period` | `today` | Advanced | Producer today, this month or all-time; Sessions shows an unsupported-data notice for all-time and retains the selection |
| `history_granularity` | `daily` | Advanced | Group activity and trends by day or month |
| `heatmap_metric` | `tokens` | Advanced | Initial heatmap measure: tokens, cost or messages |
| `panel_provider` | `all` | Advanced | Initial provider filter; the panel also offers filter buttons |
| `accounts_per_page` | 4 | Advanced | Number of account cards per page, 1–8 |
| `details_per_page` | 6 | Advanced | Detail rows per page, 2–10 |
| `show_progress` | true | Advanced | Show meters for known percentage quotas |
| `show_reset_time` | true | Advanced | Show reset countdowns, with local absolute timestamps on hover |
| `show_collection_time` | false | Advanced | Show collection age; stale accounts always show it |
| `warning_threshold` | 20 | Advanced | Warn when remaining percentage is at or below this value, 0–100 |
| `bar_show_icon` | true | Advanced | Show the provider icon beside text; shown only when bar style is full or value |
| `bar_account_index` | 1 | Advanced | Fallback only when no account is pinned; pin a named account from Quotas for a stable selection |

### Refresh

| Setting | Default | Access | Meaning |
| --- | --- | --- | --- |
| `auto_refresh` | true | Regular | Periodic polling; disabling it keeps the initial read and manual refresh available |
| `refresh_interval_seconds` | 60 | Regular | Polling interval, 30–3600 seconds; shown only when automatic refresh is enabled |
| `refresh_on_open` | false | Advanced | Request a fresh snapshot when the panel opens |

Open the panel's gear button or **Settings → Plugins → Token Monitor** and its
gear to edit these options. Most users can leave Noctalia's **Advanced** switch off; the
instructions above explain how to access options marked **Advanced**.
`refresh_interval_seconds` is hidden when `auto_refresh` is off. `bar_show_icon`
is an Advanced option shown only when `bar_style` is `full` or `value`; it is
hidden in icon-only mode. Noctalia supplies the standard panel placement
settings.
The manifest's 580 × 720 panel uses a consistent 480px content grid, including
reserved scrollbar space, so short pages and scrolling pages keep the same
edges. Quota rows share a value column and a separate aligned metadata row.
The privacy toggle changes display only: the local display cache still
contains account labels, session titles, project labels and opaque session keys.
Compact cards preview two quota windows and comfortable
cards preview three; expand a card to see its remaining windows. Only one card
is expanded at a time to keep native UI work bounded.

The credentials file may be either a plain single-line Hub secret or Token
Monitor's existing `credentials.json` containing `credentials.hub.hostSecret`.
The file is read on each refresh, so credential rotation does not require copying
the secret into Noctalia settings. An unreadable or invalid configured file fails
explicitly. The connection guide shows the selected or detected file path,
but never its secret. Use the existing private file or a separate plain-secret
file with mode `0600`; never paste secrets into a URL or public configuration.
Only point the plugin at a Hub you trust. Use HTTPS for remote network paths.

### Troubleshooting

- **Connection failed:** confirm Token Monitor is still running and **Host hub
  on this device** is selected. Check the address and port; the default is
  `http://127.0.0.1:17321`. Use **Test connection** to see whether Stats,
  History, or both failed. Automatic credentials apply only to loopback URLs.
- **Unauthorized:** the Hub rejected the selected secret. For a local Hub,
  restart Token Monitor in Host mode and let automatic discovery reread its
  credentials. If using **Credentials file override**, verify that it is the matching
  Token Monitor `credentials.json` or a plain one-line Hub secret. A selected
  file always overrides automatic discovery. Never paste a secret into the
  Hub URL.
- **History missing:** use the endpoint results in **Test connection** to tell
  a History request failure from missing historical data. If Stats works but
  History does not, verify the Token Monitor version and History endpoint on
  the configured Hub. If History succeeds but the chart has no records, the
  Hub may not have recorded data for that period; changing the heatmap metric
  or time range cannot create missing history.

Once enabled, open the panel or refresh through Noctalia IPC:

```sh
noctalia msg panel-toggle shangshui0302/token-monitor:panel
noctalia msg plugin shangshui0302/token-monitor:service all refresh
```

## Data coverage and time semantics

The [installed-version API assessment](hub-api-assessment.md) records the
exact Token Monitor 0.68.0 HTTP contract. The plugin does not scrape Electron
internals or invent endpoints.

- **Quotas:** current provider-defined windows, raw usage/limits when reported,
  account balance details and reset credits. Historical usage filters never
  relabel these snapshots as historical quotas.
- **Models:** token/cost and available components for producer today, calendar
  month and all-time. Missing components remain absent; unpriced tokens are
  distinguishable from known zero cost.
- **Sessions:** today and month summaries, last-used/start times, available
  title/project labels, tokens, cost, context and per-model details. All-time
  session records and transcripts are not exposed by the Hub. If **All time**
  is selected, the panel retains that choice and displays an unsupported-data
  notice; choose **Today** or **This month** to see available summaries. Source
  omissions and the local 200-session cap are explicit.
- **Activity:** daily/monthly recorded activity totals, with expandable model
  and client attribution. This is not a message-by-message event log.
- **Trends:** recorded daily/monthly token or USD-cost buckets, a graph of the
  latest 30 recorded points and paged values with attribution. Missing dates
  are not silently filled with zero; the graph is labelled as recorded buckets.

The Hub does not expose historical quota snapshots, transcripts, all-time
session records or arbitrary hourly usage breakdowns. The plugin requests only
the documented `/api/stats` and `/api/history` endpoints; it does not invent API
routes or infer unavailable records from current snapshots.

Producer calendar periods can differ by device timezone. Absolute timestamps
are formatted in the desktop's local timezone. Hub receipt time is separate
from provider/device collection time. Reset countdown reaching zero does not
prove the provider has refilled quota. Refresh only rereads Hub snapshots.

Use an account's pin button to keep that exact provider identity in the bar and
at the top of its filtered list. The key survives sorting/restarts and is scoped
to the configured Hub. Missing or ambiguous identity cannot be pinned. Removing
a pinned account does not silently select another; choose one or clear the pin.

## Network, files and processes

- Network: native `noctalia.http` sends `GET <hub_url>/api/stats` and
  `GET <hub_url>/api/history`, with an
  optional Bearer header. Redirects are disabled. No provider API is called by
  the plugin, and credentials never appear in a subprocess command line.
- Reads: the explicitly configured credentials file, or the bounded automatic
  credential locations above, plus this plugin's own cache and selection.
  Credentials are kept out of shared state, UI, logs and cache.
- Writes: `snapshot.json` under `noctalia.pluginDataDir()`. It contains bounded
  normalized quotas, usage, session summaries and history, the source scope
  (Hub URL and credential-file path), and receipt times. It excludes raw
  envelopes, project paths, prompts/transcripts and credentials.
- Writes: `selection.json` contains the source-scoped stable pinned account key;
  a vanished pinned account remains unavailable instead of switching identities.
- `snapshot.json` and `selection.json` are internal plugin data, not user-edited
  Noctalia settings or plugin configuration files.
- Reads: the bundled `assets/provider-icons-<fingerprint>.ttf` through native `loadFont`; no runtime font generation or installation.
- Processes: none. The plugin does not launch a browser, shell, collector or Hub.
- Account or endpoint changes clear the displayed previous source immediately;
  late callbacks cannot republish its data. Cache restores require a matching
  source scope. Cache write failures do not discard otherwise valid live data.

Responses are bounded to 4 MiB each, 128 accounts, 32 windows per account and 512 windows in total.
JSON responses larger than 32 KiB are decoded across native update callbacks;
they are additionally limited to 64 nesting levels, 262144 structural units and
32 KiB per scalar/key. Unsupported oversized structures fail explicitly.
Local processing failures are distinguished from malformed Hub responses.
Diagnostic logs contain only the endpoint kind, processing phase and error
category, never response content or credentials.
Each usage period retains at most 128 models and the 200 most recent sessions.
History retains at most 370 daily and 1200 monthly records, with a shared 4096
attribution-entry budget. Source and local omissions remain visible. Cache is
bounded to 2 MiB; if details exceed it, quota recovery remains available. Larger
HTTP responses fail explicitly and preserve the previous snapshot. The panel renders
only while open. The bar and panel share one service, so opening either does not
create another polling loop.
