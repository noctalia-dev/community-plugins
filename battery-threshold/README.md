# Battery Threshold Control

Control the battery charge threshold on laptop batteries to help extend overall
battery lifespan. Someone would use this plugin to limit maximum charge levels
while plugged in, reducing battery wear and heat.

## Plugin

| Field   | Value                                                               |
| ------- | ------------------------------------------------------------------- |
| ID      | `damian-ds7/battery-threshold`                                      |
| Entries | Bar widget: `battery-threshold`; panel: `panel`; service: `service` |

## Requirements

- `polkit` - required for interactive setup
- Laptop hardware supporting battery charge threshold control in sysfs
  (`/sys/class/power_supply/*/charge_control_end_threshold`).
- The following external programs must be available on `PATH`: `test`, `pkexec`,
  `bash`, `cat`, `getent`, `groupadd`, `usermod`, `udevadm`, `chgrp`, and
  `chmod`.

## Usage

- **Bar Widget (`battery-threshold`)**: Displays the current battery threshold
  in the bar. Click to toggle the panel.
- **Panel (`panel`)**: Adjust the battery threshold using a slider (40–100%).
  Includes a **Configure Permissions** button if write access is missing. Toggle
  the panel using:

```sh
noctalia msg panel-toggle damian-ds7/battery-threshold:panel
```

## Settings

| Setting            | Type     | Default                        | Description                                    |
| ------------------ | -------- | ------------------------------ | ---------------------------------------------- |
| `battery_device`   | `folder` | `/sys/class/power_supply/BAT0` | Path to the battery sysfs directory.           |
| `charge_threshold` | `int`    | `80`                           | Default charge threshold percentage (40–100%). |

## IPC

```sh
# Set charge threshold percentage (between 40 and 100)
noctalia msg plugin damian-ds7/battery-threshold:service all set 80

# Trigger setup script for udev permissions
noctalia msg plugin damian-ds7/battery-threshold:service all setup
```

## Notes

- **Permissions & Setup**: Requires write access to
  `/sys/class/power_supply/BAT0/charge_control_end_threshold`. Automated setup
  creates the `battery_ctl` group, adds the active user to it, and installs
  `99-battery-threshold.rules` to `/etc/udev/rules.d/`.
- **Relogin / Reboot**: A logout or system reboot is required after running
  setup for `battery_ctl` group membership changes to take effect.
- **Manual Setup Fallback**: If Polkit is not available, run
  `sudo ./setup_rules.sh` manually from the plugin directory.
- **Persistence**: Threshold settings are stored in `threshold.txt` in plugin
  directory and restored across reboots.
