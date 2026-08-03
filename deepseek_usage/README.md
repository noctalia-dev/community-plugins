# DeepSeek Usage Plugin for Noctalia

A balance and API credit monitor for [Noctalia shell](https://noctalia.dev).

## Plugin

Plugin ID: `coder/deepseek_usage`

Widget(s):
- `bar` — bar widget entry.

Panel(s):
- `panel` — panel entry.

## Requirements

- `xdg-open` — used by the top-up button to open platform.deepseek.com/top_up in the default browser.

## External dependencies

- `xdg-open`

## Usage

Widget
- Add the `bar` widget to your bar to display usage.

Panel
- Toggle the plugin panel with the following IPC command:
  `noctalia msg panel-toggle coder/deepseek_usage:panel`

## Features
- **Bar Widget**: Shows live balance directly on your Noctalia bar.
- **Low Balance Warning**: Visual indicator and desktop notifications when credits drop below your set threshold.
- **Interactive Panel**: Displays account wallet summary, local trend graph, and quick top-up action.
- **One-Click Top-Up**: "Add Credits" button opens `platform.deepseek.com/top_up` directly in your browser.

## Settings
Configure the update interval and API key in Noctalia plugin settings.

- **DeepSeek API Key**: Create an API key at [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys) and enter it in plugin settings.
- **Refresh Interval**: Default is 15 minutes.
- **Low Balance Warning**: Default threshold is 2.00.
