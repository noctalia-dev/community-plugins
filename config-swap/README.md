# Config Swap

A [Noctalia](https://github.com/noctalia-dev/noctalia) v5 plugin for switching between saved Noctalia configurations.

## Dependencies

For this plugin, you need:
* internet access to fetch configuration data from GitHub on the store page
* `cp` to apply a configuration

## Plugin

| Field | Value |
| --- | --- |
| ID | `tadomika_ari/config-swap` |
| Entries | Bar widget: `config-swap-widget`; panel: `config-swap-panel`; service: `start` |

## Usage

This plugin is still under development.

The plugin downloads saved configurations from the `Config-Swap-Box` GitHub repository and stores them in `~/Config-Swap`.
Applying a configuration copies its `settings.toml` into `~/.local/state/noctalia/settings.toml` and sets the matching wallpaper.
Keep a backup of your current configuration before using it.

Open the panel from the bar widget, then switch between the two views with `Show Store` and `Show List`.

### Show Store

The store view fetches available configurations from GitHub.
Use `refresh` to reload the list if nothing appears.

Do not spam `refresh`; GitHub rate limits unauthenticated requests.

Each card lets you `install` or `apply` a configuration.

### Show List

The list view shows configurations already installed in `~/Config-Swap`.
From there you can `apply` them again or `install` them again to refresh the files.

Click a preview image to see extra information such as the author, origin, and description.

Use `Show Store` to return to the GitHub store view.

### Extra Info

You can add your own configuration folder to `~/Config-Swap`.
Each configuration should follow the same structure as the downloaded ones, including an `info.json` file and the expected asset files.

If you want to publish a configuration, add it to the `Config-Swap-Box` repository: https://github.com/Tadomika-Ari/Config-Swap-Box
Make sure Config Swap is enabled in your plugin list before you try to use it.



## Settings

There are no configurable settings yet.

## Requirements

- Noctalia ≥ 5.0.0
- `cp`
- internet access for the store view

## Install

Install the plugin and add it to your bar.

## License

MIT.