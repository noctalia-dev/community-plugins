# 9Router Control

Manage your [9Router](https://github.com/decolua/9router) combos right from the
Noctalia bar — no web dashboard needed.

- **List combos** — see every combo with its model chain and routing kind.
- **Reorder models** — open a combo and move models up/down to change fallback
  order.
- **Create / rename / delete combos** — full CRUD from the panel.
- **Change routing kind** — fallback, round-robin, or fusion.
- **Search** — filter combos by name or model chain.

## Plugin

| Field   | Value                       |
| ------- | --------------------------- |
| ID      | `weinguyen/9router-control` |
| Widget  | `widget` (bar)              |
| Panel   | `panel`                     |
| Service | `service`                   |

Toggle the panel from the bar widget, or with:

```sh
noctalia msg panel-toggle weinguyen/9router-control:panel
```

## Requirements

- Noctalia v5.0.0 or higher.
- A running 9Router instance (dashboard) whose REST API the plugin talks to via
  `server_host:server_port`.
- The following external commands, used by the service backend:
  - `curl` — password login posts to `/api/auth/login` and reads the `Set-Cookie`
    header (Noctalia's HTTP binding does not expose response headers).
  - `sha256sum`, `cat`, `cut`, `printf` — compute the CLI authentication token
    from the `machine-id` and `auth/cli-secret` files when the dashboard has
    login enabled.
  - `sleep` — back-off polling while a CLI token computation is in flight.

  Ordinary (login-disabled) usage needs only `curl`; the remaining commands are
  required when dashboard login is enabled.

## Usage

Click the 9Router widget on the bar to open the panel.

- The **combo list** shows every combo; the search box filters by name or model
  chain.
- Select a combo to **reorder** its models (move up/down) and change its routing
  kind.
- Use **create / rename / delete** to manage combos without touching the web
  dashboard.

If the dashboard has login enabled and no CLI token is available, the panel
shows a login screen where you enter the dashboard password; the plugin then
reuses the session cookie for subsequent requests.

## Settings

| Setting        | Default      | Description                                                             |
| -------------- | ------------ | ----------------------------------------------------------------------- |
| Server Host    | `127.0.0.1`  | Hostname of the 9Router dashboard.                                      |
| Server Port    | `20128`      | Port of the 9Router dashboard.                                          |
| Data Directory | `~/.9router` | 9Router data dir, used to compute the CLI token when login is required. |
| Language       | `auto`       | UI language (auto / English / Tiếng Việt).                              |
| Debug Logging  | off          | Print debug messages to the Noctalia log.                               |

## Notes

- The plugin talks to the local 9Router REST API (`/api/combos`). By default the
  dashboard login is disabled, so plain requests work.
- When login is enabled, the plugin first tries the 9Router CLI token (computed
  from the `machine-id` and `auth/cli-secret` files, sent as an `x-9r-cli-token`
  header). If that isn't available, it falls back to a password login and reuses
  the session cookie.
- Reordering writes the new `models` array via `PUT /api/combos/:id`.

## Development

- `widget.luau` — bar widget entry.
- `panel.luau` — chat-style panel surface.
- `service.luau` — headless API / state backend.
- `translations/` — user-facing strings.
