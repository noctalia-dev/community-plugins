# Battery Threshold

A plugin for Noctalia Shell to control the battery threshold on laptops, helping
extend battery lifespan. This plugin only works if your laptop supports charge
threshold control (as exported by the kernel in sysfs). The plugin looks like
this in action:

## Features

- **Bar Widget**: Shows current battery threshold in the bar
- **Panel**: Adjust battery threshold with a slider (40-100%)
- **Persistent Settings**: Saves and restores threshold across reboots

## Usage

Add the bar widget to your bar. Click to open the panel and adjust the battery
threshold using the slider.

### Panel Controls

- Drag the slider to set battery threshold (40-100%)
- Changes are applied immediately
- Settings persist across reboots

## Setup (Required)

This plugin requires write access to the battery threshold sysfs file. You can
configure permissions in one of three ways:

### 1. Via UI (Recommended)

If the plugin is loaded and read-only, open the panel and click the **Configure
Permissions** button. This will trigger a `pkexec` dialog prompting for
authentication to install the udev rules automatically.

### 2. Via IPC Command

You can trigger the automated setup from the terminal:

```bash
noctalia msg plugin damian-ds7/battery-threshold setup
```

### 3. Manual Fallback

If you do not have a Polkit agent running, you can manually run the included
script:

```bash
sudo ./setup_rules.sh
```

**Note:** A logout/reboot is required for the new group membership
(`battery_ctl`) to take effect.

## IPC Commands

```bash
# Toggle panel
noctalia msg panel-toggle damian-ds7/battery-threshold:panel

# Set threshold
noctalia msg plugin damian-ds7/battery-threshold:service all set <value>
```

## Troubleshooting

- **Read-only mode**: Ensure udev rule is installed, and you're in the correct
  group
- **Not available**: Your laptop may not support charge threshold control, or
  select the correct battery in the settings menu
- **Changes not saving**: Check write permissions on the sysfs file

## Requirements

- Laptop with battery charge threshold support (ThinkPad, ASUS, etc.)
- Tested on Asus Zenbook 14 UX3405
- Tested on Asus TUF Gaming F15 FX506L
