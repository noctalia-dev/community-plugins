# Battery Threshold Control

Control the battery charge threshold on laptop batteries to help extend overall
battery lifespan. Someone would use this plugin to limit maximum charge levels
while plugged in, reducing battery wear and heat. Supports laptops with single or
multiple batteries (e.g. ThinkPads with internal and removable batteries).

## Plugin

| Field   | Value                                                               |
| ------- | ------------------------------------------------------------------- |
| ID      | `damian-ds7/battery-threshold`                                      |
| Entries | Bar widget: `battery-threshold`; panel: `panel`; service: `service` |

## Requirements

- Laptop hardware supporting battery charge threshold control in sysfs
  (`/sys/class/power_supply/*/charge_control_end_threshold`).
- The following external programs must be available on `PATH`: `test`, `sudo`,
  `bash`, `readlink`, `cat`, `getent`, `groupadd`, `usermod`, `udevadm`, `chgrp`, and `chmod`.

## Usage

- **Bar Widget (`battery-threshold`)**: Displays the current battery threshold
  limit in the bar. For multiple batteries, displays the limits or combined status, with
  a rich hover tooltip showing each battery's health and threshold. Click to toggle the panel.
- **Panel (`panel`)**: Adjust the battery threshold using dedicated sliders (40–100%)
  for each detected battery. Includes quick sync buttons and a **Configure Permissions**
  button if write access is missing. Toggle the panel using:

```sh
noctalia msg panel-toggle damian-ds7/battery-threshold:panel
```

## Settings

| Setting            | Type     | Default | Description                                                                                    |
| ------------------ | -------- | ------- | ---------------------------------------------------------------------------------------------- |
| `battery_device`   | `folder` | `""`    | Path to a specific battery sysfs directory (leave empty to auto-detect all batteries).         |
| `charge_threshold` | `int`    | `80`    | Default charge threshold percentage (40–100%).                                                 |

## IPC

```sh
# Set charge threshold percentage on all batteries (between 40 and 100)
noctalia msg plugin damian-ds7/battery-threshold:service all set 80

# Set charge threshold percentage on a specific battery (e.g. BAT0 or BAT1)
noctalia msg plugin damian-ds7/battery-threshold:service all set BAT1 80

# Trigger setup script for udev permissions
noctalia msg plugin damian-ds7/battery-threshold:service all setup
```

## Notes

- **Supported Devices**: Works on laptops with battery charge threshold
  support (ThinkPad, ASUS, etc.), including dual-battery laptops (e.g., ThinkPad T480/T470/T460 with BAT0 & BAT1).
- **Permissions & Setup**: Requires write access to
  `/sys/class/power_supply/BAT*/charge_control_end_threshold`. Automated setup
  creates the `battery_ctl` group, adds the active user to it, and installs
  `99-battery-threshold.rules` to `/etc/udev/rules.d/`.
- **Relogin / Reboot**: A logout or system reboot is recommended after running
  setup for new `battery_ctl` group membership changes to take effect in desktop sessions.
- **Manual Setup Fallback**: Run `sudo ./setup_rules.sh` manually from the plugin directory.
- **Persistence**: Threshold settings are stored in `thresholds.json` (and `threshold.txt`)
  in the plugin data directory and restored across reboots.
