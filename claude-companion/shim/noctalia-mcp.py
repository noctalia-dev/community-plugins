#!/usr/bin/env python3
"""noctalia-mcp — stdio MCP shim bridging Claude Code <-> the Noctalia shell.

SENSES (shell -> Claude): query the env directly — the running compositor
                          (niri / Hyprland / Sway), playerctl, /sys, and
                          `noctalia msg status` for shell-internal state.
HANDS  (Claude -> shell): `noctalia msg <action>` (request/response; reply on
                          stdout, "error:" prefix on failure). Desktop notifications
                          go through notify-send: noctalia exposes no generic notify
                          IPC (notifications are shell-internal / luau-only).

MCP transport: newline-delimited JSON-RPC 2.0 over stdio (one message per line,
no embedded newlines) — the stdio transport Claude Code speaks. Spawned by Claude
via --mcp-config; no daemon to babysit.

Tool set is the low/medium perception tier only — high-tier senses
(clipboard/screen/files) stay gated until a local backend lands.
"""
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "noctalia-mcp", "version": "0.1.0"}


def sh(args, timeout=5):
    """Run argv (no shell), return stdout or an 'error: ...' string."""
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return (out.stdout or out.stderr).strip()
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"


# ── compositor abstraction ────────────────────────────────────────────────────
# The window/workspace ops are the ONLY compositor-coupled surface. Everything
# else (`noctalia msg`, playerctl, nmcli, /sys, notify-send) is compositor-neutral.
# Noctalia runs on niri, Hyprland, and Sway but exposes no generic window/workspace
# IPC (`noctalia msg` has no such verbs), so we speak each compositor's own protocol.
# Detection prefers the compositor's own socket env var, then XDG_CURRENT_DESKTOP.
#
# Command shapes: niri verified live; Hyprland against HyprCtl.cpp + the dispatcher
# wiki; Sway against sway-ipc(7)/sway(5). The pure helpers below (compositor_argv,
# pick_focused_monitor, find_focused_view, sway_focused_output) do no I/O, so they
# are unit-tested without a live session — see tests/shim_spec.py.
SUPPORTED_COMPOSITORS = ("niri", "hyprland", "sway")


def detect_compositor(env=None):
    """Identify the running compositor, or None if unsupported/undetectable."""
    env = os.environ if env is None else env
    if env.get("NIRI_SOCKET"):
        return "niri"
    if env.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return "hyprland"
    if env.get("SWAYSOCK"):
        return "sway"
    xdg = (env.get("XDG_CURRENT_DESKTOP") or "").lower()
    return next((c for c in SUPPORTED_COMPOSITORS if c in xdg), None)


def _ws_numeric(ref):
    """A workspace ref is 'numeric' if it is a plain (optionally signed) integer."""
    return str(ref).lstrip("-").isdigit()


def compositor_argv(comp, op, ref=None, wid=None):
    """Pure map (compositor, op) -> argv; no I/O, so it is directly unit-testable.

    For query ops that need client-side filtering (sway focused_*, hyprland
    focused_output) this returns the *query* argv and the caller does the filtering.
    Workspace refs: Hyprland needs a `name:` prefix for named workspaces; Sway needs
    the `number` keyword for numeric ones (else the int is matched as a literal name).
    Move semantics differ slightly and are documented, not normalized: niri and
    Hyprland follow focus to the target workspace, Sway does not."""
    if comp == "niri":
        return {
            "focused_output": ["niri", "msg", "-j", "focused-output"],
            "focused_window": ["niri", "msg", "-j", "focused-window"],
            "focus_window": ["niri", "msg", "action", "focus-window", "--id", str(wid)],
            "focus_workspace": ["niri", "msg", "action", "focus-workspace", str(ref)],
            "move_to_workspace": ["niri", "msg", "action", "move-column-to-workspace", str(ref)],
        }[op]
    if comp == "hyprland":
        hws = str(ref) if _ws_numeric(ref) else "name:" + str(ref)
        return {
            "focused_output": ["hyprctl", "-j", "monitors"],
            "focused_window": ["hyprctl", "-j", "activewindow"],
            "focus_window": ["hyprctl", "dispatch", "focuswindow", "address:" + str(wid)],
            "focus_workspace": ["hyprctl", "dispatch", "workspace", hws],
            "move_to_workspace": ["hyprctl", "dispatch", "movetoworkspace", hws],
        }[op]
    if comp == "sway":
        sws = ["number", str(ref)] if _ws_numeric(ref) else [str(ref)]
        return {
            "focused_output": ["swaymsg", "-t", "get_outputs"],
            "focused_window": ["swaymsg", "-t", "get_tree"],
            "focus_window": ["swaymsg", "[con_id=%s]" % wid, "focus"],
            "focus_workspace": ["swaymsg", "workspace"] + sws,
            "move_to_workspace": ["swaymsg", "move", "container", "to", "workspace"] + sws,
        }[op]
    raise KeyError((comp, op))


def pick_focused_monitor(mons):
    """Hyprland `monitors` array -> the focused monitor object (or None)."""
    return next((m for m in mons if m.get("focused")), None)


def find_focused_view(node):
    """Sway `get_tree` -> the focused leaf view (con/floating_con), recursively.

    Constrained to view node types so an ancestor workspace/output that also
    reports focused does not shadow the actual window."""
    if node.get("focused") and node.get("type") in ("con", "floating_con"):
        return node
    for child in node.get("nodes", []) + node.get("floating_nodes", []):
        hit = find_focused_view(child)
        if hit:
            return hit
    return None


def sway_focused_output(outputs, workspaces):
    """Sway output objects carry no `focused` flag [SUPPORTED, sway-ipc(7)]; derive
    the focused output from the focused workspace's `output` name."""
    ws = next((w for w in workspaces if w.get("focused")), None)
    if not ws:
        return None
    return next((o for o in outputs if o.get("name") == ws.get("output")), None)


def _no_comp():
    return "error: no supported compositor detected (niri/hyprland/sway)"


def _run_json(argv):
    """Run argv and parse stdout as JSON: (obj, None) on success, (None, err) else."""
    out = sh(argv)
    if out.startswith("error:"):
        return None, out
    try:
        return json.loads(out), None
    except Exception as e:  # noqa: BLE001
        return None, f"error: bad JSON from {argv[0]}: {e}"


def _get_workspace(a):
    """Focused output/monitor (connector, mode, current workspace), compositor-native JSON."""
    comp = detect_compositor()
    if comp is None:
        return _no_comp()
    if comp == "niri":
        return sh(compositor_argv(comp, "focused_output"))
    if comp == "hyprland":
        mons, err = _run_json(compositor_argv(comp, "focused_output"))
        if err:
            return err
        foc = pick_focused_monitor(mons)
        return json.dumps(foc) if foc else "error: no focused monitor"
    outs, err = _run_json(["swaymsg", "-t", "get_outputs"])
    if err:
        return err
    wss, err = _run_json(["swaymsg", "-t", "get_workspaces"])
    if err:
        return err
    foc = sway_focused_output(outs, wss)
    return json.dumps(foc) if foc else "error: no focused output"


def _get_window(a):
    """Focused window (app id/class + title), compositor-native JSON."""
    comp = detect_compositor()
    if comp is None:
        return _no_comp()
    if comp in ("niri", "hyprland"):
        return sh(compositor_argv(comp, "focused_window"))
    tree, err = _run_json(compositor_argv(comp, "focused_window"))
    if err:
        return err
    view = find_focused_view(tree)
    return json.dumps(view) if view else "error: no focused window"


def _remember(a):
    """Persist a durable fact to GLOBAL memory's inbox; memd distills ~/.memory.

    The membrane (decision #25): ephemeral senses -> noctalia.state; durable
    learnings -> global memd. This is the durable side. Notes are routed:global
    so memd's curator files them into the system-wide store, not a project."""
    # Coerce: a model may send a non-string (number/list) — str() keeps the
    # handler (and the server) from raising on .strip()/.lower().
    text = str(a.get("text") or "").strip()
    if not text:
        return "error: 'text' is required"
    slug = re.sub(r"[^a-z0-9]+", "-", str(a.get("topic") or "note").lower()).strip("-") or "note"
    mem = os.path.expanduser("~/.memory")
    inbox = os.path.join(mem, "inbox")
    body = (
        f"---\nrouted: global\ntopic: {slug}\n"
        f"date: {datetime.date.today()}\nsource: noctalia-mcp/remember\n---\n\n"
        f"{text}\n"
    )
    try:
        os.makedirs(inbox, exist_ok=True)
        # Concurrency: every Claude session runs its own shim, and the curator
        # (memd) reads/clears this inbox in parallel. Two guards:
        #  1) Unique name — microsecond timestamp + PID, so simultaneous notes
        #     from different sessions never collide (second-resolution did).
        #  2) Atomic publish — write a temp file OUTSIDE the inbox, then
        #     os.replace() it in. A sweep either sees the whole note or not at
        #     all; it can never read a half-written file mid-write.
        #  3) Crash durability — fsync the file before publish, then fsync the
        #     inbox dir after the rename. Without both, a power loss/panic can
        #     leave a flushed file whose directory entry never landed (lost
        #     note) or a renamed entry pointing at unflushed data. Cheap
        #     insurance; matters for an alpha shell on a crash-prone desktop.
        ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        final = os.path.join(inbox, f"{ts}-{slug}-{os.getpid()}.md")
        fd, tmp = tempfile.mkstemp(dir=mem, prefix=".remember-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(body)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, final)
            dfd = os.open(inbox, os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return f"remembered -> {final}"
    except OSError as e:
        return f"error: {e}"


# ── additional senses (read-only) ────────────────────────────────────────────
def _get_power(a):
    """Battery level/status + AC state, as JSON. battery=null if none present."""
    base = "/sys/class/power_supply"
    try:
        names = os.listdir(base)
    except OSError as e:
        return f"error: {e}"

    def rd(node, field):
        try:
            with open(os.path.join(base, node, field)) as fh:
                return fh.read().strip()
        except OSError:
            return None

    out = {}
    bats = sorted(n for n in names if n.startswith("BAT"))
    out["battery"] = (
        {b: {"capacity": rd(b, "capacity"), "status": rd(b, "status")} for b in bats}
        if bats else None
    )
    for ac in ("AC", "ACAD", "ADP1", "AC0"):
        online = rd(ac, "online")
        if online is not None:
            out["ac_online"] = online == "1"
            break
    return json.dumps(out)


def _get_network(a):
    """Connectivity + the active Wi-Fi connection (SSID/signal), as JSON."""
    state = sh(["nmcli", "-t", "-f", "STATE,CONNECTIVITY", "general"])
    if state.startswith("error:"):
        return state
    wifi = sh(["nmcli", "-t", "-f", "ACTIVE,SSID,SIGNAL", "dev", "wifi"])
    active = next((l for l in wifi.splitlines() if l.startswith("yes:")), "")
    return json.dumps({"general": state, "wifi_active": active})


def _get_processes(a):
    """Top processes by CPU (header + top 10), as text."""
    out = sh(["ps", "-eo", "pid,pcpu,pmem,comm", "--sort=-pcpu"])
    if out.startswith("error:"):
        return out
    return "\n".join(out.splitlines()[:11])


# ── additional hands (mutate shared desktop state) ────────────────────────────
# These race on the single real desktop across concurrent sessions (last write
# wins) — inherent to a shared environment, not a shim bug. Each is a stateless
# subprocess, so the shim itself stays concurrency-safe.
def _focus_window(a):
    wid = str(a.get("id") or "").strip()
    if not wid:
        return "error: 'id' is required"
    comp = detect_compositor()
    if comp is None:
        return _no_comp()
    return sh(compositor_argv(comp, "focus_window", wid=wid))


def _switch_workspace(a):
    ref = str(a.get("reference") or "").strip()
    if not ref:
        return "error: 'reference' is required"
    comp = detect_compositor()
    if comp is None:
        return _no_comp()
    return sh(compositor_argv(comp, "focus_workspace", ref=ref))


def _move_to_workspace(a):
    ref = str(a.get("reference") or "").strip()
    if not ref:
        return "error: 'reference' is required"
    comp = detect_compositor()
    if comp is None:
        return _no_comp()
    return sh(compositor_argv(comp, "move_to_workspace", ref=ref))


def _set_wallpaper(a):
    """Set a wallpaper by path, or switch to a random one if no path given."""
    path = str(a.get("path") or "").strip()
    conn = str(a.get("connector") or "").strip()
    if path:
        argv = ["noctalia", "msg", "wallpaper-set"] + ([conn] if conn else []) + [path]
    else:
        argv = ["noctalia", "msg", "wallpaper-random"] + ([conn] if conn else [])
    return sh(argv)


# name -> (description, inputSchema properties, handler). Commands verified against
# noctalia 5.0.0 (`noctalia msg --help`); window/workspace ops route through the
# compositor abstraction above (niri / Hyprland / Sway).
TOOLS = {
    # ── senses (low/medium tier) ──────────────────────────────────────────────
    "get_workspace": (
        "Focused output (connector, mode, current workspace) as compositor-native JSON.",
        {},
        _get_workspace,
    ),
    "get_window": (
        "Focused window (app_id/class and title) as compositor-native JSON.",
        {},
        _get_window,
    ),
    "get_media": (
        "Now-playing media (artist - title), or empty if nothing is playing.",
        {},
        lambda a: sh(["playerctl", "metadata", "--format", "{{artist}} - {{title}}"]),
    ),
    "get_shell_state": (
        "Noctalia shell-internal state (active panel, theme mode, etc.) as JSON.",
        {},
        lambda a: sh(["noctalia", "msg", "status"]),
    ),
    "get_power": (
        "Battery level/status and AC state as JSON (battery=null on desktops).",
        {},
        _get_power,
    ),
    "get_network": (
        "Connectivity and the active Wi-Fi connection (SSID/signal) as JSON.",
        {},
        _get_network,
    ),
    "get_processes": (
        "Top processes by CPU (pid, %cpu, %mem, command) as text.",
        {},
        _get_processes,
    ),
    # ── memory (durable, cross-session) ───────────────────────────────────────
    "remember": (
        "Persist a durable fact, preference, or system detail to GLOBAL memory "
        "(system-wide, cross-project) so future sessions know it. Use for things "
        "true beyond the current task; memd distills it into ~/.memory.",
        {
            "text": {"type": "string", "required": True,
                     "description": "The durable fact/preference, 1-2 sentences."},
            "topic": {"type": "string",
                      "description": "Short kebab-case slug for the note (optional)."},
        },
        _remember,
    ),
    # ── hands ─────────────────────────────────────────────────────────────────
    "notify": (
        "Post a desktop notification.",
        {
            "title": {"type": "string", "description": "Notification title"},
            "body": {"type": "string", "description": "Notification body"},
        },
        lambda a: sh(["notify-send", a.get("title", "Claude"), a.get("body", "")]),
    ),
    "set_theme_mode": (
        "Set the shell light/dark mode.",
        {"mode": {"type": "string", "enum": ["dark", "light", "auto"]}},
        lambda a: sh(["noctalia", "msg", "theme-mode-set", a.get("mode", "auto")]),
    ),
    "set_color_scheme": (
        "Set the active color palette.",
        {
            "source": {
                "type": "string",
                "description": "builtin | wallpaper | community | custom",
            },
            "name": {"type": "string", "description": "Scheme name/id for that source"},
        },
        lambda a: sh(["noctalia", "msg", "color-scheme-set", a.get("source", "builtin"), a.get("name", "")]),
    ),
    "focus_window": (
        "Focus a window by its id (the id/address returned by get_window).",
        {"id": {"type": "string", "required": True,
                "description": "Window id from get_window (niri id, Hyprland address, Sway con_id)"}},
        _focus_window,
    ),
    "switch_workspace": (
        "Switch to a workspace by reference (index like '2', or its name).",
        {"reference": {"type": "string", "required": True,
                       "description": "Workspace index or name"}},
        _switch_workspace,
    ),
    "move_to_workspace": (
        "Move the focused column to a workspace by reference (index or name).",
        {"reference": {"type": "string", "required": True,
                       "description": "Target workspace index or name"}},
        _move_to_workspace,
    ),
    "set_wallpaper": (
        "Set the wallpaper to an image path, or switch to a random one if no path.",
        {"path": {"type": "string",
                  "description": "Image path; omit for a random wallpaper"},
         "connector": {"type": "string",
                       "description": "Output connector (optional; default all)"}},
        _set_wallpaper,
    ),
}


def _tool_list():
    tools = []
    for name, (desc, props, _fn) in TOOLS.items():
        # `required` is a control flag in our table, not a JSON Schema property
        # keyword — lift it to the object-level `required` array and strip it
        # from each property def so strict MCP validators accept the schema.
        clean = {k: {pk: pv for pk, pv in spec.items() if pk != "required"}
                 for k, spec in props.items()}
        tools.append({
            "name": name,
            "description": desc,
            "inputSchema": {
                "type": "object",
                "properties": clean,
                "required": [k for k, v in props.items() if v.get("required")],
            },
        })
    return tools


def _dispatch(method, params):
    """Return (result, error) for a request; result is None for notifications."""
    if method == "initialize":
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": SERVER_INFO,
        }, None
    if method == "tools/list":
        return {"tools": _tool_list()}, None
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        entry = TOOLS.get(name)
        if not entry:
            return None, {"code": -32602, "message": f"unknown tool: {name}"}
        try:
            text = entry[2](args if isinstance(args, dict) else {})
        except Exception as e:  # noqa: BLE001 — a tool bug must not crash the server
            return None, {"code": -32603, "message": f"tool '{name}' failed: {e}"}
        is_error = isinstance(text, str) and text.startswith("error:")
        return {"content": [{"type": "text", "text": str(text)}], "isError": is_error}, None
    return None, {"code": -32601, "message": f"method not found: {method}"}


def _emit(out, payload):
    out.write(json.dumps(payload) + "\n")
    out.flush()


def main():
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            _emit(out, {"jsonrpc": "2.0", "id": None,
                        "error": {"code": -32700, "message": "parse error"}})
            continue
        if not isinstance(req, dict):
            _emit(out, {"jsonrpc": "2.0", "id": None,
                        "error": {"code": -32600, "message": "invalid request"}})
            continue
        mid = req.get("id")
        method = req.get("method", "")
        # Notifications (no id) — e.g. notifications/initialized: ack by ignoring.
        if mid is None:
            continue
        try:
            result, error = _dispatch(method, req.get("params") or {})
        except Exception as e:  # noqa: BLE001 — never let a handler kill the loop
            result, error = None, {"code": -32603, "message": f"internal error: {e}"}
        resp = {"jsonrpc": "2.0", "id": mid}
        if error is not None:
            resp["error"] = error
        else:
            resp["result"] = result
        _emit(out, resp)


if __name__ == "__main__":
    main()
