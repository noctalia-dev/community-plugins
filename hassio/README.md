# Home Assistant

Monitor and control your Home Assistant entities from the Noctalia bar and control center. Useful for quickly toggling lights, checking sensor states, and opening a full entity manager panel for richer controls.

## Plugin

| Field | Value |
| --- | --- |
| ID | `pozzoo/hassio` |
| Entries | Widget: `status`; Service: `connection`; Shortcuts: `ha_toggle_1`, `ha_toggle_2`, `ha_toggle_3`, `ha_toggle_4`, `ha_panel`; Panel: `entity_manager` |
| Launcher Prefix | — |

## Requirements

- A running Home Assistant instance with API access enabled
- A Long-lived Access Token (Profile → Security → Long-lived access tokens)
- `curl` available on `PATH` (used by the plugin to call HA HTTP endpoints)

## Usage

1. Configure the plugin: open **Settings → Plugins → Home Assistant** and set:

   | Setting | Description |
   | --- | --- |
   | Home Assistant URL | The URL to your HA instance, for example `http://homeassistant.local:8123` |
   | Long-Lived Access Token | Token created in HA under Profile → Security |
   | Quick Toggle 1–4 — Entity ID | (Optional) Entity IDs to assign to each quick-toggle tile (e.g. `light.living_room`) |

2. Add the bar widget: add the **status** widget from the widget picker to show connection state and (optionally) the number of monitored entities.

3. Add control-center tiles: go to **Settings → Control Center** and add any combination of:
   - **Home Assistant** (×4) — Quick-toggle tiles. Each corresponds to one of the four entity slots configured in plugin settings.
   - **Home Assistant** (panel opener) — Opens the entity manager panel.

4. Open the entity manager panel: use the panel opener tile or the panel IPC command to open the full browser and pin entities for monitoring.

```sh
noctalia msg panel-toggle pozzoo/hassio:entity_manager
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `ha_url` | `string` | `""` | Home Assistant base URL used for API requests (include protocol and port if needed). |
| `ha_token` | `string` | `""` | Long-lived access token for Home Assistant. Keep this secret. |
| `shortcut_entity_1` | `string` | `""` | Entity ID used by Quick Toggle 1 (e.g. `light.kitchen`). |
| `shortcut_entity_2` | `string` | `""` | Entity ID used by Quick Toggle 2. |
| `shortcut_entity_3` | `string` | `""` | Entity ID used by Quick Toggle 3. |
| `shortcut_entity_4` | `string` | `""` | Entity ID used by Quick Toggle 4. 

## IPC

- Open the panel:

```sh
noctalia msg panel-toggle pozzoo/hassio:entity_manager
```

Notes: the plugin forwards Home Assistant state updates internally and uses Noctalia's state routing to update widgets and shortcuts; there are no documented user-facing plugin IPC commands beyond the panel opener.

## Notes

- The plugin maintains a live SSE connection to Home Assistant to receive real-time state changes and saves the pinned entity list to `managed_entities.json` inside the plugin directory.
- The plugin issues HTTP requests to your HA instance and spawns `curl` for service calls; do not install untrusted plugins if you do not want them to access your network or tokens.
- If authentication fails, generate a new long-lived access token in Home Assistant and paste it into plugin settings.
