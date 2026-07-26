# Battery graph

Plots battery level on a graph.

## Plugin

<!-- Copy ids exactly from plugin.toml. Remove rows that do not apply. -->

| Field | Value |
| --- | --- |
| ID | `FraI3mega/battery-graph` |
| Entries | Bar widget: `battery-graph-widget`; panel: `battery-panel` |

## Requirements

Requires a running upower deamon.
Install `gdbus` on `PATH`.

## Usage

Explain how to add or access every user-facing entry and describe the normal
workflow. Use exact labels and ids. For a panel, include its copy-pasteable IPC
command:

```sh
noctalia msg panel-toggle <author>/<plugin>:<panel-id>
```

For a launcher provider, explain what to type after `/<prefix>` and what
activating a result does. For a shortcut, say where users add it in Settings.

## Settings

<!-- Required when plugin.toml declares settings. Describe behavior and units,
     especially for settings whose effect is not obvious from the label. A
     table like the official plugin READMEs is recommended. -->

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `example_setting` | `bool` | `false` | What changing this setting does. |

```

