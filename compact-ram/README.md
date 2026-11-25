# Compact RAM

A small DIMM icon and the used memory in GiB, rounded to one decimal (for example `3.2G`). Hover for used and total memory in MiB, at the precision provided by Noctalia's system monitor.

## Plugin

`omid511/compact-ram` provides the `ram` bar widget.

The icon is white. The widget shows `--` when memory data is unavailable.

Requires Noctalia plugin API 12 or later and an enabled system monitor with memory polling. It runs no subprocesses and has no external dependencies.

## Usage

Install and enable `omid511/compact-ram` using Noctalia's plugin manager, then add the widget to a bar. For example, merge the following into your Noctalia TOML configuration; preserve other entries in your bar's `end` list if desired:

```toml
[system.monitor]
enabled = true
memory_poll_seconds = 2.0

[bar.default]
end = ["compact-ram"]

[widget.compact-ram]
type = "omid511/compact-ram:ram"
```

Tooltips must be enabled on the bar or widget. Sampling follows the system monitor's memory polling interval, independently of the widget's update interval.

## Actions

The plugin does not bind clicks or run commands; Noctalia's normal widget action defaults and per-instance overrides remain in control. For example, these optional mappings open the system monitor or control center using built-in actions, with no additional programs:

```toml
[widget.compact-ram.actions]
left = "panel-toggle control-center system"
right = "panel-toggle control-center"
```

You can instead set actions through the widget's settings. No action mappings are required.

## License

MIT.
