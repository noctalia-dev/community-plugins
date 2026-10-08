# Herdr

Monitor Herdr sessions and coding agents from Noctalia, with attention state in the bar and an attached popup panel.

## Plugin

| Field   | Value                                                 |
| ------- | ----------------------------------------------------- |
| ID      | `hy4ri/herdr`                                         |
| Entries | Bar widget: `bar`; panel: `panel`; service: `service` |

The `service` entry owns every Herdr command and publishes one normalized `herdr.state` snapshot. The `bar` and `panel` entries only render that shared state and send action requests back to the service.

## Requirements

Install this on `PATH` (declared in `plugin.toml` `dependencies`):

- `herdr` — session discovery, snapshots, agent focus, and session lifecycle actions.

Optional, used only when both are present:

- `hyprctl` — focuses an already-open Herdr terminal window on Hyprland.
- `ps` — maps a Herdr client process to its Hyprland window.

Without the optional tools, the plugin still works on generic Linux and opens or attaches to a session through Noctalia's configured terminal.

## Usage

Add the `hy4ri/herdr:bar` widget to a Noctalia bar. The number beside the robot icon is the count of agents that are done or need action (`blocked` + `done`). Its attention color follows this order: **Needs you**, **Done**, **Working**, then **Ready**.

Click the widget to open the `panel` anchored next to the bar. A running session is listed as its workspaces. A workspace holding more than one pane is named once, with its panes underneath it, so a workspace running two agents no longer reads as two unrelated rows. A workspace holding a single pane stays a single row named by the workspace, with that pane's title underneath and nothing nested below it. Workspaces are ordered by attention state, and the panes inside one are ordered the same way. Use the panel to:

- open or start a session;
- focus an agent pane;
- stop a running session;
- delete a stopped named session after confirmation;
- refresh immediately.

The default session can be stopped and started, but cannot be deleted.

```sh
noctalia msg panel-toggle hy4ri/herdr:panel
```

## Settings

Bar widget settings — Settings → Bar → the Herdr widget:

| Setting                | Type     | Default          | Description                                                                         |
| ---------------------- | -------- | ---------------- | ----------------------------------------------------------------------------------- |
| `display_mode`         | `select` | `icon_and_count` | Choose what to display on the bar widget (`icon` or `icon_and_count`).              |
| `hide_count_when_zero` | `bool`   | `true`           | Hide the badge count when no agents need action or are done, showing only the icon. |
| `color_blocked`        | `color`  | `error`          | Color used for agents needing action, in the bar badge and the panel.               |
| `color_done`           | `color`  | `tertiary`       | Color used for agents that completed their tasks, in the bar badge and the panel.   |
| `color_working`        | `color`  | `primary`        | Color used for active running agents, in the bar badge and the panel.               |
| `hide_agentless_panes` | `bool`   | `true`           | Hide panes that are running no agent, so the panel lists agents only.               |

Plugin settings — Settings → Plugins → Herdr:

| Setting               | Type   | Default | Description                                                                                                  |
| --------------------- | ------ | ------- | ------------------------------------------------------------------------------------------------------------ |
| `show_other_machines` | `bool` | `false` | Also list the other machines saved in Herdr (`herdr machine list`) at the end of the panel while it is open. |

### Why the colors and the pane filter live on the widget

Noctalia seeds an entry runtime with the settings that entry declares plus the plugin-level ones — never another entry's. A `[[widget.setting]]` is therefore readable by that widget alone: the panel and the service would get `nil` and Noctalia would log an undeclared-setting miss on every read.

So the widget owns those four values, and republishes them into shared plugin state (`herdr.settings`) when it loads and whenever they change. The panel reads its colors from there and the service reads the pane filter from there, which keeps one settings surface for display options while the panel and the service still see the same values. Two consequences worth knowing:

- The values are stored per widget instance. With a single Herdr widget this is invisible; with several, the last one to publish wins.
- With no Herdr widget on a bar, nothing publishes them and the panel and the service use the built-in defaults.

## Other machines

With `show_other_machines` enabled, every enabled machine from `herdr machine list` is read through `herdr --machine <id> api snapshot` and shown after the local sessions. Only the socket API is available on a remote machine, so those rows are read-only: they list panes and agent states, and they cannot be stopped, deleted, or focused from this panel.

Remote rows are polled only while the panel is open and at most once every 15 seconds, because each read crosses SSH.

Once a machine has been read, its agents count toward the bar badge, the tooltip, and the panel summary alongside your local ones — so an agent waiting on another machine still turns the widget red. Each machine counts as one running session in that rollup. A machine that cannot be reached keeps its last known counts, is marked stale, and stays marked until it answers again.

## Agent states

The plugin uses Herdr's semantic agent status directly:

| Herdr state | Display   |
| ----------- | --------- |
| `blocked`   | Needs you |
| `done`      | Done      |
| `working`   | Working   |
| `idle`      | Ready     |
| `unknown`   | Unknown   |
| no agent    | No agent  |

Within the same state, agents that changed state more recently are shown first using Herdr's `state_change_seq`.

Panes with no agent (a plain shell, an editor, a TUI) report `No agent` and are hidden by default. Turn `hide_agentless_panes` off to list them under their workspace next to the agent panes. Either way they are excluded from the session counts, the bar badge, and its attention color, so the rollup stays agent-based, and a workspace with nothing to show is left out entirely.

Whether a workspace nests its panes follows the workspace's real pane count, not how many panes survive that filter: a workspace with two panes keeps its shape while `hide_agentless_panes` is on and simply lists the panes it shows.

A pane's row title is taken from its agent name, terminal title, or working directory. A pane whose working directory has no basename (a pane sitting at `/`) shows the path itself rather than a raw HerdR pane id. A workspace row is named by the workspace's label, falling back to its first pane's tab or title when the workspace has no label.

## Refresh cadence

Herdr exposes no event stream over its socket API, so the widget cannot be pushed to: the service polls, and the widget is only as fresh as that poll. The ladder is:

| State                       | Interval |
| --------------------------- | -------- |
| The panel is open           | 1000 ms  |
| An agent is blocked or done | 1500 ms  |
| An agent is working         | 1500 ms  |
| Everything idle             | 5000 ms  |

A refresh is `herdr session list --json` plus one `herdr api snapshot` per running session, both local socket calls, so a fast cadence stays cheap. Refreshes never stack: a tick that lands while one is in flight is collapsed into a single follow-up read. The cadence slows on its own as soon as nothing needs attention.

## Hyprland integration

When `hyprctl` and `ps` are available, the service maps Herdr client processes to `hyprctl clients -j` results. Opening a mapped session focuses its existing window. Focusing an agent first runs Herdr's `agent focus` command, then brings that session window forward.

If the session has no mapped window, or compositor focusing is unavailable, the service uses `noctalia.runInTerminal` with `herdr` for the default session or `herdr --session NAME` for a named session.

## Notes

- Running state comes from `herdr session list --json`.
- Each running session is read through `herdr api snapshot`.
- Stopped-session project names come from that session's saved `session.json`.
- One failed session snapshot is kept as a stale/degraded row while other sessions continue updating.
- Polling follows the ladder in [Refresh cadence](#refresh-cadence).
