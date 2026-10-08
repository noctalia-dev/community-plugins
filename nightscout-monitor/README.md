# Nightscout Monitor

This plugin adds a simple widget displaying blood glucose values fetched from a
configurable Nightscout host.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nuddel69/nightscout-monitor` |
| Entries | Bar widgets: `monitor`; service: `ticker`;|

## Requirements

A nightscout server host and an access token with read capabilities.

## Usage

Add a host URL and access token in the plugin settings. Add the `monitor`
widget from the Add-widget picker. The widget displays the glucose value
fetched from nightscout. This is fetched at configurable intervals. You may
also force a fetch by clicking the widget.

The plugin sends an HTTP request to the `api/v1` endpoint of your nightscout
instance. This is repeated for each fetch.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `api-secret` | `string` | `` | Access token to your nightscout instance. Requires read access. |
| `host` | `string` | `` | Nightscout host URL.  |
| `interval` | `int` | `30` | Update interval in seconds. |
| `unit` | `select` | `mmol/L` | What unit to use when displaying glucose values. |

## IPC

The plugin exposes a single IPC event used to force a widget update:

```sh
noctalia msg plugin nuddel69/nightscout-monitor:ticker all fetch
```

## Roadmap

Additional features are planned. First priority will be a panel displaying
glucose history in a graph. In addition, there may be a control centre shortcut
allowing you to set configurable states in nightscout. Contributions are
welcome!
