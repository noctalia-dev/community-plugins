# Mangowm Keymode

Mangowm Keymode adds a bar widget that displays MangoWC's current keymode and
can notify you whenever the active keymode changes.

## Plugin

| Field | Value |
| --- | --- |
| ID | `gambled23/mangowm-keymode` |
| Entry | Bar widget: `mangowm-keymode` |

## Requirements

This plugin requires MangoWC and its `mmsg` command on `PATH`. It listens to
`mmsg watch keymode` for live keymode changes.

## Usage

Add the `mangowm-keymode` widget from Noctalia's widget picker. It updates as
MangoWC changes keymode; click it to show the current keymode in a notification.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_text` | `bool` | `true` | Shows the current keymode beside the widget glyph. |
| `notify_change` | `bool` | `true` | Sends a notification when the keymode changes. |
| `hide_on_default` | `bool` | `false` | Hides the widget when default keymode is active. |
