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

Optional, for focusing existing terminal windows:

- `hyprctl` — focuses an already-open Herdr terminal window on Hyprland.
- `niri` — lists and focuses windows on Niri, and provides the window picker when needed.
- `ps` — maps attached Herdr client processes to terminal windows through `/proc/PID/stat`.

Hyprland integration uses `hyprctl` and `ps`. Niri integration uses `niri` and `ps`,
and requires Noctalia to inherit `NIRI_SOCKET` from the compositor session. These
compositor-specific tools are optional rather than mandatory manifest dependencies.
On other desktops the plugin opens or attaches to a session through Noctalia's
configured terminal. On Niri, discovery or focus errors are reported without opening
a duplicate terminal.

## Usage

Add the `hy4ri/herdr:bar` widget to a Noctalia bar. The number beside the robot icon is the count of agents that are done or need action (`blocked` + `done`). Its attention color follows this order: **Needs you**, **Done**, **Working**, then **Ready**.

Click the widget to open the `panel` anchored next to the bar. A running session is listed as its workspaces. A workspace holding more than one pane is named once, with its panes underneath it, so a workspace running two agents no longer reads as two unrelated rows. A workspace holding a single pane stays a single row named by the workspace, with that pane's title underneath and nothing nested below it. Workspaces are ordered by attention state, and the panes inside one are ordered the same way. Use the panel to:

- open or start a session;
- focus an agent pane;
- stop a running session;
- delete a stopped named session after confirmation;
- refresh immediately.

The default session can be stopped and started, but cannot be deleted.

Opening a session or focusing an agent closes the popup before switching windows
on both Niri and Hyprland.

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

Client-process discovery on both Hyprland and Niri accepts bare `herdr` and
`herdr attach`, including `--session NAME`, `--session=NAME`, and `--handoff`,
plus `herdr session attach NAME`. Short-lived commands such as `herdr api`,
`herdr agent focus`, `herdr status` and `herdr server` do not count as attached
clients; neither do `--remote` clients. This also narrows the Hyprland process
matching compared with earlier plugin versions.

## Niri integration

When Noctalia runs inside Niri, the service matches `niri msg --json windows`
results to attached Herdr clients by their parent processes. Clicking an agent
first focuses its Herdr pane, then brings the existing terminal forward with
`niri msg action focus-window --id ID`. The window list is checked again on every
click. A terminal is opened only when no window is mapped to that session.

Within those process-matched candidates, a unique title match skips the picker.
The service recognizes Herdr 0.9.5's default `{hostname}: {workspace}` title using
the local hostname (`/proc/sys/kernel/hostname`) and workspace labels it already
polls. It also recognizes titles beginning with `herdr` (case-insensitive), such
as `Herdr: project`. If several sessions share a terminal process, a title must
distinguish the requested session by its workspace or an explicit session name;
session names use exact case and whole-name boundaries. A generic `herdr` title
alone cannot distinguish those sessions. Editor titles and unrelated process
windows are not treated as matches.

Title matching does not change Herdr's configuration or terminal titles and makes
no extra Herdr calls. The default title needs no configuration change. A custom
title can retain a recognizable prefix, for example
`window_title = "herdr: {hostname}: {workspace}"` under `[ui]` in Herdr's config.
See [Herdr's title configuration](https://herdr.dev/docs/configuration/#outer-terminal-window-title)
for supported tokens; Herdr 0.9.5 has no `{session}` token.

Some terminals, including Ghostty, can have several windows sharing one process.
If multiple candidates remain and no title uniquely identifies the window, Niri's
window picker opens: click the existing Herdr terminal once, or press Escape to
cancel. A Noctalia notification names the session and asks you to select its
existing terminal window, with an Esc cancellation hint. An existing remembered
choice takes precedence over title matching while
it remains valid. Automatic title matches are checked afresh on every click.
The manual choice is kept
in memory for that session and checked against all attached clients on subsequent
clicks. Background polls never clear it; a successful click-time discovery discards
it when it no longer matches. Restarting Noctalia or disabling the plugin clears
the choice, so an ambiguous session needs the picker again afterward. Window IDs
and selections are not written to disk.

The popup closes before selection so it does not cover the target window. Cancelling
the picker is silent, and repeated clicks do not start competing pickers. Selecting
an unrelated window shows a hint; command failures are reported and logged with the
`HerdR Niri picker:` prefix. Neither case creates an extra terminal.

While a focus or picker request is pending, only further open/focus requests are
blocked. Refresh, stop and delete requests remain available, and their completion
does not release the pending focus request's lock. A cancelled picker leaves no
error banner in the panel.

## Development tests

Run from the repository root with Lua 5.4 or newer and Python 3:

```sh
lua herdr/tests/test_focus.lua
noctalia plugins lint herdr
```

The tests load the real service and panel scripts against mocked process and
compositor APIs. They cover default and named sessions, shared terminal processes,
multiple clients, selection cancellation/revalidation, overlapping requests,
command failures, and the existing Hyprland focus path. Regression cases exercise
the actual command watcher during a pending picker, stop/delete completion and
failure, incomplete background polls, click-time invalidation, and cancelled
status rendering. Title cases cover default and prefixed titles, named sessions
sharing a process, duplicate workspace labels, exact session-name boundaries,
unrelated titles/windows, remembered choices and title changes between clicks.
Notification cases check the session name, cancellation hint, prompt-before-picker
ordering, and that direct focus, remembered choices and rapid clicks do not emit
unnecessary or duplicate prompts.

Representative Niri JSON fixtures also pass through Python's standard JSON parser
at the mocked `noctalia.json.decode` boundary, covering window arrays, picked-window
objects, nullable fields, malformed JSON and cancellation. Python is only a test
dependency; the plugin continues to use Noctalia's built-in JSON decoder, which
this offline harness does not execute. These tests do not replace a live desktop
test.

## Notes

- Running state comes from `herdr session list --json`.
- Each running session is read through `herdr api snapshot`.
- Stopped-session project names come from that session's saved `session.json`.
- One failed session snapshot is kept as a stale/degraded row while other sessions continue updating.
- Polling follows the ladder in [Refresh cadence](#refresh-cadence).
