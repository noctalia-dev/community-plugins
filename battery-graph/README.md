# Battery graph

Uses the Upowerd to display the historical charge of the battery on a graph.

## Plugin


| Field | Value |
| --- | --- |
| ID | `frai3mega/battery-graph` |
| Entries | Bar widget: `battery-graph-widget`; panel: `battery-panel`; Desktop widget: `battery-graph-desktop` |

## Requirements

Requires a running `upowerd` deamon.
Install `gdbus` on `PATH`.

## Usage

You can use it as a desktop/locksreen widget or on the bar.

Show the panel using

```sh
noctalia msg panel-toggle frai3mega/battery-graph:battery-panel
```


## Settings


| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `graph_time` | `int` | `6` | Changes the timeframe of the graph |
| `battery_path` | `string` | `/org/freedesktop/UPower/devices/battery_BAT0` | The path to the battery to be graphed |
| `interpol_time` | `int` | `5` | The time beetween points on the graph. |

```

