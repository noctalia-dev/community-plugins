# OpenCodexBar

[OpenCodex](https://github.com/lidge-jun/opencodex) account, quota, usage, and account-routing control for Noctalia.

## Plugin

| Field | Value |
| --- | --- |
| ID | `wy3z/opencodex-bar` |
| Entries | Bar widget: `usage`; panel: `panel`; service: `service` |

Only `service` contacts OpenCodex. Widget and panel use shared state and never see the credential.

## Requirements

- Noctalia v5, plugin API 24
- OpenCodex 2.31.0, with the Management API enabled
- OpenCodex admin token in the Noctalia process's `OPENCODEX_ADMIN_AUTH_TOKEN` or the file at `admin_token_file` (default `~/.opencodex/admin-api-token`). Env wins.
- `xdg-open` on `PATH` (from `xdg-utils`) for the dashboard button

## Usage

Install from the Noctalia plugin store and add the `usage` widget to a bar. Click the widget, or:

```sh
noctalia msg panel-toggle wy3z/opencodex-bar:panel
```

- Accounts: subscription plans, health, reauth, quota windows, active Codex account selection, and confirmed reset-credit use
- Usage: today, 30-day request grid, provider/model totals, estimated cost

Right-click the widget or use Refresh to force a quota refresh. The link button runs `xdg-open` on `base_url`.

## Settings

| Setting | Scope | Type | Default | Description |
| --- | --- | --- | --- | --- |
| `base_url` | Plugin | `string` | `http://127.0.0.1:10100` | API and dashboard URL. HTTP on loopback only; HTTPS otherwise. |
| `admin_token_file` | Plugin | `file` | `~/.opencodex/admin-api-token` | Token file path. Overridden by `OPENCODEX_ADMIN_AUTH_TOKEN` in Noctalia's environment. |
| `poll_seconds` | Plugin | `int` | `30` | Cached poll interval, 10–300 s. |
| `force_refresh_minutes` | Plugin | `int` | `10` | Quota refresh interval, 5–60 min. |
| `hidden_providers` | Plugin | `string` | empty | Comma-separated ids to hide (`openai`/`codex` are aliases). Does not change OpenCodex routing. |
| `theme_colors` | Plugin | `bool` | `false` | Use Noctalia colours instead of the OpenCodex palette. |
| `show_percentage` | Widget | `bool` | `true` | Mean quota used next to the icon. |
| `icon_source` | Widget | `select` | `bars` | `bars`, `active`, or `fixed`. |
| `glyph` | Widget | `glyph` | `brand-openai` | Used when `icon_source` is `fixed`. |

Disabled OpenCodex providers are hidden the same way. Hidden providers are stripped from every figure. Cached-input and reasoning-output totals are omitted when anything is hidden (OpenCodex does not attribute them).

## Notes

- Network: authenticated Management API requests to `base_url` (`X-OpenCodex-API-Key`). Polling uses `GET`; confirmed account actions use `PUT /api/codex-auth/active` and `POST /api/codex-auth/reset-credits/consume`. Non-loopback HTTP is refused.
- Credential: env, then file. If neither provides a valid token, OpenCodex rejects Management API requests. The credential stays in the service; it is not shown, written, or published to plugin state.
- Files: reads the token file. Writes nothing locally. Account selection and reset-credit use mutate OpenCodex state only after an in-panel confirmation.
- Process: `xdg-open` with the dashboard URL. Nothing else is spawned.
- Daily costs are estimates, not invoices. The grid is request volume, not spend.
- Bar % is the mean of each visible account's busiest quota window.
- Accounts are labelled alias / log label / "Main Account" / OpenCodex id — never email. Subscription plans use the values reported by OpenCodex.
