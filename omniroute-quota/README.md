# OmniRoute Quota

Monitor every Codex account configured in a local OmniRoute installation from
the Noctalia bar. The panel shows the live 5-hour and weekly quota windows,
their reset countdowns, account status, and local seven-day usage.

## Plugin

| Field | Value |
| --- | --- |
| ID | `teagar/omniroute-quota` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service` |

## Requirements

- Install `node` 22.5 or newer on `PATH`, with the built-in `node:sqlite`
  module available.
- Install and configure OmniRoute locally with at least one Codex account. The
  collector reads `~/.omniroute/storage.sqlite` and OmniRoute's local `.env`.

## Usage

Add `teagar/omniroute-quota:widget` to a bar in Settings, Bar. The capsule shows
the lowest remaining quota across active Codex accounts. Its colour changes to
`secondary` at 30% remaining and `error` at 10% remaining.

- Left click opens the account panel.
- Right click immediately refreshes the quotas.
- Middle click opens the widget settings.
- Hover lists both quota windows for every account.

The panel displays each account's plan, active state, 5-hour and weekly quota
bars, exact reset countdowns, and successful request/token totals recorded by
OmniRoute during the last seven days. Opening the panel requests fresh values;
the refresh button in its header does the same.

To open the panel from a terminal:

```sh
noctalia msg panel-toggle teagar/omniroute-quota:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_seconds` | `int` | `120` | Seconds between live quota checks, from 30 to 1800. |
| `show_inactive` | `bool` | `false` | Also query Codex connections disabled in OmniRoute. |
| `show_value` | `bool` | `true` | Show the lowest remaining percentage in the bar. |

## IPC

Force a refresh without waiting for the configured interval:

```sh
noctalia msg plugin teagar/omniroute-quota:service all refresh
```

## Notes

- The service spawns one `node scripts/get-omniroute-quota.mjs` process per
  refresh. Widgets and panels subscribe to its shared state and do not spawn
  additional collectors.
- The collector opens OmniRoute's SQLite database in read-only mode and reads
  `STORAGE_ENCRYPTION_KEY` from OmniRoute's local `.env` only when needed.
- Access tokens are decrypted only in the collector process memory. They are
  never published to Luau state, printed, written, or exposed in the UI.
- Each active account causes one HTTPS request to OpenAI's official Codex usage
  endpoint at `https://chatgpt.com/backend-api/wham/usage`.
- The plugin writes no files.

## Tests

From the `omniroute-quota` directory:

```sh
node --test tests/collector.test.mjs
noctalia plugins lint .
```
