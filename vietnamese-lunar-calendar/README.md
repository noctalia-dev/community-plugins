# Vietnamese Lunar Calendar for Noctalia

A small Noctalia v5 plugin for the **Vietnamese lunar calendar**.

It provides:

- a Control Center shortcut named **Âm lịch**
- an attached monthly calendar panel that opens near its trigger
- lunar day/month shown below each Gregorian date
- leap-month marker (`N`)
- Can Chi year name
- common Vietnamese traditional festivals
- selectable dates with solar and lunar details in the footer
- an optional bar widget showing the Gregorian date as `17 Sep`

## Plugin

| Field | Value |
| --- | --- |
| ID | `notoxus/vietnamese-lunar-calendar` |
| Entries | Bar widget: `lunar`; panel: `calendar`; shortcut: `calendar-shortcut` |
| Time zone used for lunar calculation | UTC+7 |

## Usage

Enable **Vietnamese Lunar Calendar** under:

```text
Settings → Plugins
```

Or enable it from the command line:

```sh
noctalia msg plugins enable notoxus/vietnamese-lunar-calendar
```

Add the **Âm lịch** shortcut from:

```text
Settings → Control Center → Shortcuts
```

Optionally add the `lunar` widget to the bar. It displays a compact Gregorian
date such as `17 Sep` and opens the lunar calendar when clicked.

Open the calendar panel directly with:

```sh
noctalia msg panel-toggle notoxus/vietnamese-lunar-calendar:calendar
```

Click any date in the calendar to inspect its lunar date. Use the arrow buttons
to change month and **Hôm nay** to return to the current date.

## Settings

Configure the plugin under:

```text
Settings → Plugins → Vietnamese Lunar Calendar
```

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_festivals` | `bool` | `true` | Show common Vietnamese traditional festivals. |
| `show_can_chi` | `bool` | `true` | Show the Can Chi year name. Available under Advanced settings. |
| `accent_weekends` | `bool` | `true` | Accent weekend dates in the calendar. Available under Advanced settings. |
| `show_timezone` | `bool` | `true` | Show the UTC+7 lunar-calculation label. Available under Advanced settings. |

## Nix / Home Manager

You can deploy the plugin directory declaratively:

```nix
xdg.dataFile."noctalia/plugins/vietnamese-lunar-calendar".source =
  ./vietnamese-lunar-calendar;
```

## Notes

The lunar conversion is calculated locally using UTC+7.

The plugin does not use the network, does not spawn external processes, and has
no external dependencies.

Traditional festival labels are intentionally lightweight; regional or
religious observances can be added later without changing the calendar
conversion logic.
