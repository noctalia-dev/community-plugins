# PrismLauncher Instances

PrismLauncher Instances adds your local Minecraft instances to the Noctalia
launcher so they can be searched and started directly.

## Plugin

| Field | Value |
| --- | --- |
| ID | `radimous/prismlauncher-instances` |
| Entry | Launcher provider: `prismlauncher-instances` |
| Launcher Prefix | `/pl` |

## Requirements

Install [PrismLauncher](https://github.com/PrismLauncher/PrismLauncher) and make
sure the `prismlauncher` command is available on `PATH`.

## Usage

Open the Noctalia launcher and type `/pl` to list all detected PrismLauncher
instances. Continue typing to filter by instance name, then activate a result
to launch that instance with `prismlauncher --launch`.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `prism_path` | `string` | `~/.local/share/PrismLauncher` | PrismLauncher data directory containing its configuration and instances. |

## Notes

The provider reads `prismlauncher.cfg`, instance metadata, and local instance
icons from the configured PrismLauncher directory. It does not modify them.
