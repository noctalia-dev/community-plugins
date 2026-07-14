# Nix Monitor

Nix Monitor compares the local Nixpkgs revision with a remote branch and shows
NixOS generations, store size, closure size, and update status from the bar.

## Plugin

| Field | Value |
| --- | --- |
| ID | `avivbintangaringga/nix-monitor` |
| Entries | Bar widget: `nix-monitor`; panel: `panel`; service: `service` |

## Requirements

This plugin is intended for NixOS. It uses `nix`, `nixos-version`,
`nixos-rebuild`, `nix-store`, and `git`, plus the standard commands `du`, `cat`, `read`, `echo`, `awk`,
`grep`, `tail`, `wc`, `kill`, and `pkill`. Home Manager generation information
is shown when `home-manager` is available.

## Usage

Add the `nix-monitor` widget to a bar. Click it to open a panel showing local
and remote Nixpkgs revisions, NixOS and Home Manager generations, store usage,
and update controls.

Open the panel directly with:

```sh
noctalia msg panel-toggle avivbintangaringga/nix-monitor:panel
```

Set `update_command` before using **Update**. **Optimize** runs the configured command `nix-store --optimise -vv`. **Clean** runs the configured
cleanup command, which defaults to `nix-collect-garbage -d`. All commands open
in a terminal so you can review their output.

## Settings

Update behavior:

| Setting | Default | Description |
| --- | --- | --- |
| `update_check_interval` | `60` | Minutes between remote revision checks. |
| `update_check_duration_threshold` | `5` | Minutes before an update check is cancelled. |
| `system_stats_check_interval` | `10` | Minutes between store-statistics checks. |
| `system_stats_check_duration_threshold` | `5` | Minutes before a statistics check is cancelled. |
| `show_update_check_notification` | `false` | Notifies when an update check starts and finishes. |
| `show_update_available_notification` | `true` | Notifies when a newer revision is available. |
| `branch` | `nixos-unstable` | Nixpkgs branch compared by the service. |
| `update_command` | *(empty)* | Command launched by the panel's **Update** button. |
| `optimize_command` | `nix-store --optimize -vv` | Command launched by the panel's **Optimize** button. |
| `clean_command` | `nix-collect-garbage -d` | Command launched by the panel's **Clean** button. |
| `close_on_enter` | `true` | Keeps the command terminal open until Enter is pressed. |

Widget appearance:

| Setting | Default | Description |
| --- | --- | --- |
| `show_text` | `true` | Shows status text beside the glyph. |
| `colorize_text` | `false` | Colors status text using the current state color. |
| `show_glyph` | `true` | Shows the status glyph. |
| `colorize_glyph` | `true` | Colors the glyph using the current state color. |
| `up_to_date_glyph` / `up_to_date_color` | `rosette-discount-check` / `#57ff57` | Up-to-date appearance. |
| `checking_glyph` / `checking_color` | `loader-3` / `#ffeb57` | Checking appearance. |
| `update_available_glyph` / `update_available_color` | `cloud-download` / `#ff5757` | Update-available appearance. |
| `unknown_glyph` / `unknown_color` | `cloud-question` / `on_surface` | Unknown-state appearance. |

## Notes

Remote checks contact the configured Nixpkgs Git source. The service writes
temporary revision, size, and PID files under Noctalia's state directory and
terminates overdue helper processes using the declared process tools.
