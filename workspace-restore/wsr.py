#!/usr/bin/env python3
"""Workspace Restore helper for the Noctalia plugin.

save [--ws N]        snapshot workspaces, their monitors and windows to layout.json
                     (--ws: re-record only workspace N, keep the rest as saved)
status               print layout + user choices as one JSON object for the panel,
                     plus open workspaces that aren't saved yet
set-tick 0|1 WS ...  tick or untick workspaces for restoring at login
set-keyword KEY TEXT title keyword for one window slot (browser windows)
candidates [--ws N]  open windows and installed apps that can be added (to N)
add-window WS (--address ADDR | --desktop ID)
                     add an open window or an installed app to saved workspace WS
add-open WS          add every window open on WS that its list doesn't have yet
remove-window WS N CLASS
                     drop the Nth (from 1) saved window of WS; CLASS must match
set-monitor WS       save the monitor open workspace WS is on now as its monitor
move-window WS FROM N CLASS
                     move the Nth (from 1) saved window of workspace FROM to WS
move-workspace WS DESC
                     move workspace WS to the monitor with this description now
                     (if it is open) and save that monitor as its monitor
renumber [OLD:NEW ...] [--name OLD=NAME ...]
                     give workspaces new numbers and names; their windows,
                     lists and settings keep their monitor. Refuses duplicate
                     numbers and numbers pinned to another monitor.
rename WS [NAME]     name workspace WS (no NAME: back to its default name)
set-identity WS real|borrowed
                     say whether open workspace WS is saved workspace WS
renumber-saved WS [NEW]
                     give saved workspace WS a free number (NEW or the lowest),
                     leaving the open workspace with that number alone
watch                follow Hyprland's events and note which saved numbers are
                     in use by another workspace (the bar widget starts it)
set-auto-add 0|1 WS [WS ...]
                     turn auto-add on or off for workspaces
auto-add             add apps that aren't saved anywhere yet and are open on an
                     auto-add workspace (the bar widget runs this every poll)
restore [--all] [--ticked] [--ws N ...] [--monitor DESC] [--wait-monitors] [--once] [--dry-run]
                     put workspaces back on their monitors, launch missing apps
                     and move windows to their saved workspaces
                     (--once: only the first call per Hyprland session runs;
                     the bar widget uses it for the login restore)

The snapshot (layout.json) and the user's choices (config.json) are separate
files so saving again never loses ticks or keywords. Both live in
$XDG_STATE_HOME/workspace-restore unless --state-dir is given.

WS is a workspace number or name:<name> for a named workspace. Named
workspaces are kept by name: Hyprland gives them a new negative id each
session. Their name is their identity, so rename, renumber, renumber-saved
and set-identity refuse them.

Workspace rules in the Hyprland config count: a workspace pinned to a
monitor uses that monitor and can't be moved, and a rule's default name is
its name unless it was given another.
"""

import argparse
import configparser
import fcntl
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time

# A terminal holding a plain shell would come back as a fresh, unrelated one,
# so only terminals started with a command (kitty -e btop) are saved. They are
# matched by that exact command line, since their titles say little ("sh").
TERMINALS = {"kitty", "alacritty", "foot", "org.wezfurlong.wezterm", "com.mitchellh.ghostty"}
LAUNCH_TIMEOUT = 45
POLL_INTERVAL = 0.5
SETTLE = 15  # seconds to keep watching after the last window was placed
IDENTITY_STATES = ("closed", "pending", "borrowed", "ask")
HEARTBEAT_MAX = 300  # the watcher quits when the bar hasn't checked in for this long
ACTING_S = 3  # workspaces created this soon after the plugin acted are its own


def state_dir(args):
    if args.state_dir:
        return os.path.expanduser(args.state_dir)
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "workspace-restore")


BROKEN = set()  # copies made this run of files that couldn't be read


def read_json(path, default):
    """The file's data, or default when it's missing. A file that can't be
    read is copied aside first, so the next write doesn't lose it."""
    try:
        with open(path) as f:
            data = json.load(f)
        if isinstance(data, type(default)):
            return data
    except FileNotFoundError:
        return default
    except (OSError, ValueError):
        pass
    try:
        # Named after the file's mtime: one copy per broken version.
        copy = f"{path}.broken-{int(os.path.getmtime(path))}"
        if not os.path.exists(copy):
            shutil.copy2(path, copy)
        BROKEN.add(copy)
    except OSError:
        pass
    return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path)


def ws_key(ws_id, name):
    """How a workspace is known everywhere here: its number, or "name:<name>"
    for a named workspace. Hyprland gives those negative ids in the order
    they're created, so the same name can get another id next session.
    None for special workspaces."""
    if ws_id > 0:
        return ws_id
    if not name or name.startswith("special:"):
        return None
    return "name:" + name


def parse_key(text):
    """A workspace key from a command line or config.json key."""
    if text.startswith("name:") and len(text) > len("name:"):
        return text
    return int(text)


def sort_key(key):
    """Numbered workspaces first, by number, then named ones by name."""
    if isinstance(key, int):
        return (0, key, "")
    return (1, 0, (key or "").lower())


def ws_label(key):
    """A workspace key as people read it: 3, or Web for name:Web."""
    return key[len("name:"):] if isinstance(key, str) else str(key)


def hypr(what):
    """hyprctl's JSON, with every workspace id replaced by its key (ws_key).
    Special workspaces are left out of the workspace list."""
    out = subprocess.run(["hyprctl", what, "-j"], capture_output=True, text=True, check=True)
    data = json.loads(out.stdout)
    if what == "workspaces":
        for w in data:
            w["id"] = ws_key(w["id"], w["name"])
        data = [w for w in data if w["id"] is not None]
    elif what == "clients":
        for c in data:
            c["workspace"]["id"] = ws_key(c["workspace"]["id"], c["workspace"]["name"])
    elif what == "monitors":
        for m in data:
            m["activeWorkspace"]["id"] = ws_key(m["activeWorkspace"]["id"], m["activeWorkspace"]["name"])
    return data


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def selector(ws):
    """A workspace key as a Lua workspace selector: 3 or "name:Web"."""
    return lua_str(ws) if isinstance(ws, str) else str(int(ws))


class Dispatcher:
    def __init__(self, dry_run):
        self.dry_run = dry_run
        self.changes = 0

    def __call__(self, expr):
        if self.dry_run:
            print("dispatch:", expr)
            return
        subprocess.run(["hyprctl", "dispatch", expr], capture_output=True, check=False)

    # Only these call shapes are verified on Hyprland 0.56. Unknown keys are
    # ignored and the action falls back to the focused workspace, so every
    # target here is named explicitly.
    def move_window(self, address, ws):
        self.changes += 1
        self(f"hl.dsp.window.move({{ workspace = {selector(ws)}, follow = false, window = {lua_str('address:' + address)} }})")

    def move_workspace(self, ws, monitor):
        self.changes += 1
        self(f"hl.dsp.workspace.move({{ workspace = {selector(ws)}, monitor = {lua_str(monitor)} }})")

    def rename_workspace(self, ws, name):
        # An unknown workspace is an error here, not the focused one.
        self(f"hl.dsp.workspace.rename({{ workspace = {selector(ws)}, name = {lua_str(name)} }})")

    def focus_workspace(self, ws):
        self(f"hl.dsp.focus({{ workspace = {selector(ws)} }})")

    def exec(self, cmd, ws=None):
        # Launched by Hyprland, not by us, so apps get the session's own
        # environment instead of whatever started this script. The workspace
        # goes in as an exec rule: it beats window rules that send the app to
        # another monitor, and a window that opens late lands right without a move.
        self.changes += 1
        rules = "no_initial_focus = true" + (f", workspace = {lua_str(f'{ws} silent')}" if ws is not None else "")
        self(f"hl.dsp.exec_cmd({lua_str(cmd)}, {{ {rules} }})")


# --- launch commands -------------------------------------------------------

def desktop_dirs():
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    data_dirs = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    dirs = [data_home] + data_dirs.split(":")
    dirs += [os.path.expanduser("~/.local/share/flatpak/exports/share"), "/var/lib/flatpak/exports/share"]
    return [os.path.join(d, "applications") for d in dirs]


_desktop = None


def desktop_index():
    """Every .desktop entry. A file name found in several dirs counts once,
    the first (user) one wins, as XDG says."""
    global _desktop
    if _desktop is not None:
        return _desktop
    _desktop, seen = [], set()
    for d in desktop_dirs():
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for name in names:
            if not name.endswith(".desktop") or name in seen:
                continue
            seen.add(name)
            cp = configparser.ConfigParser(interpolation=None, strict=False)
            try:
                cp.read(os.path.join(d, name), encoding="utf-8")
            except (configparser.Error, UnicodeDecodeError):
                continue
            if not cp.has_section("Desktop Entry"):
                continue
            e = cp["Desktop Entry"]
            stem = name[: -len(".desktop")]
            _desktop.append({
                "id": stem,
                "name": e.get("Name", stem),
                "about": e.get("GenericName") or e.get("Comment") or "",
                "wm_class": e.get("StartupWMClass", ""),
                "exec": re.sub(r"\s*%[a-zA-Z]", "", e.get("Exec", "")).strip(),
                "app": e.get("Type", "Application") == "Application"
                and not any(e.get(k, "").lower() == "true" for k in ("NoDisplay", "Hidden", "Terminal")),
            })
    return _desktop


def find_desktop(window_class, loose=False):
    """The .desktop entry for a window class: StartupWMClass first, then the
    file name. loose also tries the class's last part (dev.noctalia.Noctalia
    finds noctalia.desktop); that is for names and icons only, never launching."""
    wanted = window_class.lower()
    by_name = None
    for e in desktop_index():
        if not e["exec"]:
            continue
        if e["wm_class"].lower() == wanted:
            return e
        stem = e["id"].lower()
        if by_name is None and (stem == wanted or stem.split(".")[-1] == wanted
                                or (loose and wanted.split(".")[-1] == stem)):
            by_name = e
    return by_name


def desktop_exec(window_class):
    """Exec line of the .desktop file for a window class, field codes removed."""
    entry = find_desktop(window_class)
    return entry["exec"] if entry else None


SHELLS = {"sh", "bash", "zsh", "fish", "dash"}


def terminal_inner(command):
    """The program a terminal was started with: btop for `kitty -e sh -lc btop`."""
    try:
        args = shlex.split(command)
        rest = next((args[i + 1:] for i, a in enumerate(args) if i and a in ("-e", "--")), [])
        if len(rest) >= 3 and os.path.basename(rest[0]) in SHELLS and rest[1].startswith("-") and "c" in rest[1]:
            rest = shlex.split(rest[2])
    except ValueError:
        return None
    return os.path.basename(rest[0]) if rest else None


def display(window):
    """Name and icon id the panel shows for a window. Matching and launching
    still go by class and command."""
    cls = window["class"]
    if window.get("match_command"):
        inner = terminal_inner(window["command"])
        if inner:
            entry = find_desktop(inner, loose=True)
            return f"{inner} ({cls})", entry["id"] if entry else cls
    entry = find_desktop(cls, loose=True)
    if entry:
        # "Spotify (Launcher)" reads as Spotify.
        return re.sub(r"\s*\([^)]*\)$", "", entry["name"]) or entry["name"], entry["id"]
    last = cls.split(".")[-1]
    return last[:1].upper() + last[1:], cls


def firefox_profile(pid):
    """Absolute path of the Firefox profile whose lock belongs to pid."""
    root = os.path.expanduser("~/.config/mozilla/firefox")
    if not os.path.isdir(root):
        root = os.path.expanduser("~/.mozilla/firefox")
    try:
        names = os.listdir(root)
    except OSError:
        return None
    for name in names:
        try:
            target = os.readlink(os.path.join(root, name, "lock"))
        except OSError:
            continue
        if target.endswith(":+" + str(pid)):
            return os.path.join(root, name)
    return None


def proc_cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            parts = [p.decode(errors="replace") for p in f.read().split(b"\0") if p]
        return shlex.join(parts) if parts else None
    except OSError:
        return None


def terminal_command(client):
    """Command line of a terminal started with a command, else None."""
    cmd = proc_cmdline(client["pid"])
    if cmd and ("-e" in shlex.split(cmd)[1:] or "--" in shlex.split(cmd)[1:]):
        return cmd
    return None


def launch_command(client):
    cmd = desktop_exec(client["class"])
    if cmd is None:
        cmd = proc_cmdline(client["pid"])
    if cmd and client["class"].lower() == "firefox":
        # Naming the profile skips Firefox's profile picker.
        profile = firefox_profile(client["pid"])
        if profile:
            cmd += " --profile " + shlex.quote(profile)
    return cmd


# --- save / status / settings -----------------------------------------------

def window_entry(client):
    """Saved form of an open window, or None for a plain-shell terminal."""
    if client["class"].lower() in TERMINALS:
        cmd = terminal_command(client)
        if not cmd:
            return None
        return {"class": client["class"], "title": client["title"], "command": cmd, "match_command": True}
    return {"class": client["class"], "title": client["title"], "command": launch_command(client)}


def workspace_entry(ws, monitors, clients):
    mon = monitors.get(ws["monitor"], {})
    wins = []
    for c in sorted(clients, key=lambda c: (c["at"][0], c["at"][1])):
        if c["workspace"]["id"] != ws["id"] or not c["class"]:
            continue
        w = window_entry(c)
        if w:
            wins.append(w)
    return {
        "id": ws["id"],
        "name": ws["name"],
        "monitor": ws["monitor"],
        "monitor_desc": mon.get("description", ""),
        "monitor_x": mon.get("x", 0),
        "windows": wins,
    }


def workspace_rules(monitors):
    """{ws key: {"name": default name, "pin": monitor fields}} from the
    Hyprland config's workspace rules for plain workspace numbers and
    name:<name> workspaces. A desc: rule matches monitors whose description
    starts with it."""
    try:
        rules = hypr("workspacerules")
    except (OSError, subprocess.CalledProcessError, ValueError):
        return {}
    out = {}
    for r in rules if isinstance(rules, list) else []:
        ws = str(r.get("workspaceString", ""))
        if not (ws.isdigit() or ws.startswith("name:")) or not r.get("enabled", True):
            continue
        info = out.setdefault(parse_key(ws), {})
        if r.get("defaultName"):
            info["name"] = r["defaultName"]
        mon = r.get("monitor")
        if mon:
            want = mon[5:] if mon.startswith("desc:") else None
            m = next((m for m in monitors if (m["description"].startswith(want) if want else m["name"] == mon)), None)
            info["pin"] = {"monitor": m["name"] if m else mon, "monitor_desc": m["description"] if m else (want or mon),
                           "monitor_x": m["x"] if m else 0}
    return out


def apply_pins(workspaces, rules):
    """A pinned workspace's saved monitor is the rule's."""
    for ws in workspaces:
        pin = rules.get(ws["id"], {}).get("pin")
        if pin:
            ws.update(pin)
            ws["pinned"] = True


def custom_name(ws):
    """The name the user gave a saved workspace, or None. A named
    workspace's name is how it's found, so it never has another."""
    name = ws.get("name", "")
    if isinstance(ws["id"], str):
        return None
    return name if name and name != str(ws["id"]) else None


def default_name(ws_id, rules):
    if isinstance(ws_id, str):
        return ws_label(ws_id)
    return rules.get(ws_id, {}).get("name") or str(ws_id)


def refuse_named(ws_id):
    """Numbers and names of named workspaces come from the Hyprland config."""
    if isinstance(ws_id, str):
        print(json.dumps({"ok": False, "error": f"{ws_label(ws_id)} is a named workspace; "
                                                 "rename it in your Hyprland config"}))
        return True
    return False


def layout_path(args):
    return os.path.join(state_dir(args), "layout.json")


def cmd_save(args):
    monitors = {m["name"]: m for m in hypr("monitors")}
    clients = hypr("clients")
    live = {ws["id"]: ws for ws in hypr("workspaces")}
    if args.ws is None:
        workspaces = [workspace_entry(live[i], monitors, clients) for i in sorted(live, key=sort_key)]
    else:
        workspaces = read_json(layout_path(args), {}).get("workspaces", [])
        if args.ws in live:
            entry = workspace_entry(live[args.ws], monitors, clients)
        else:
            # An empty workspace does not exist in Hyprland; keep its saved
            # monitor and clear its apps.
            entry = next((dict(w, windows=[]) for w in workspaces if w["id"] == args.ws), None)
            if entry is None:
                print(json.dumps({"ok": False, "error": f"workspace {args.ws} is not open"}))
                return 1
        workspaces = sorted([w for w in workspaces if w["id"] != args.ws] + [entry], key=lambda w: sort_key(w["id"]))
    write_json(layout_path(args), {"saved": int(time.time()), "workspaces": workspaces})
    print(json.dumps({"ok": True, "workspaces": len(workspaces)}))


def slot_keys(layout):
    """Window slots that need a title keyword: classes saved more than once."""
    count = {}
    for ws in layout.get("workspaces", []):
        for w in ws["windows"]:
            if not w.get("match_command"):
                count[w["class"]] = count.get(w["class"], 0) + 1
    keys = {}
    for ws in layout.get("workspaces", []):
        seen = {}
        for i, w in enumerate(ws["windows"]):
            if w.get("match_command"):
                continue
            n = seen.get(w["class"], 0)
            seen[w["class"]] = n + 1
            if count[w["class"]] > 1:
                keys[(ws["id"], i)] = f"{ws['id']}|{w['class']}|{n}"
    return keys


def cmd_status(args):
    d = state_dir(args)
    layout = read_json(os.path.join(d, "layout.json"), {})
    config = read_json(os.path.join(d, "config.json"), {})
    ticked = config.get("ticked", {})
    keywords = config.get("keywords", {})
    keys = slot_keys(layout)
    workspaces = layout.setdefault("workspaces", [])
    saved = {ws["id"] for ws in workspaces}
    try:
        monitors = hypr("monitors")
        live = hypr("workspaces")
        clients = hypr("clients")
    except (OSError, subprocess.CalledProcessError, ValueError):
        monitors, live, clients = [], [], []
    # A saved number another workspace is using: that workspace and its
    # windows are kept apart, so the saved one shows as not open.
    ids = read_ids(args)
    busy = (ids["borrowed"] | ids["ask"]) & {w["id"] for w in workspaces if w["windows"]}
    other_live = [ws for ws in live if ws["id"] in busy]
    other_clients = [c for c in clients if c["workspace"]["id"] in busy]
    live = [ws for ws in live if ws["id"] not in busy]
    clients = [c for c in clients if c["workspace"]["id"] not in busy]
    by_name = {m["name"]: m for m in monitors}
    for ws in live:
        if ws["id"] not in saved:
            workspaces.append(dict(workspace_entry(ws, by_name, []), unsaved=True))
    # A saved workspace whose apps were all removed only shows while it is
    # open, like any other open workspace.
    live_ids = {ws["id"] for ws in live}
    workspaces[:] = sorted((w for w in workspaces if w["windows"] or w["id"] in live_ids), key=lambda w: sort_key(w["id"]))

    rules = workspace_rules(monitors)
    apply_pins(workspaces, rules)
    live_names = {ws["id"]: ws["name"] for ws in live}
    for ws in workspaces:
        live_name = live_names.get(ws["id"], "")
        ws["name"] = (live_name if live_name and live_name != str(ws["id"]) else None) \
            or custom_name(ws) or default_name(ws["id"], rules)
    layout["pins"] = {str(i): r["pin"]["monitor_desc"] for i, r in rules.items() if "pin" in r}

    # Screens left to right: every connected one, plus saved ones that aren't.
    screens = {}
    for m in monitors:
        make = m.get("make", "").split()
        screens[m["description"]] = {"desc": m["description"], "connector": m["name"], "x": m["x"],
                                     "make": make[0] if make else "", "model": m.get("model", ""),
                                     "connected": True}
    for ws in workspaces:
        if ws["monitor_desc"] not in screens:
            screens[ws["monitor_desc"]] = {"desc": ws["monitor_desc"], "connector": ws["monitor"],
                                           "x": ws.get("monitor_x", 0), "make": "", "model": "",
                                           "connected": False}
    for sc in screens.values():
        sc["builtin"] = sc["connector"].startswith(("eDP", "LVDS", "DSI"))
    layout["screens"] = sorted(screens.values(), key=lambda sc: sc["x"])

    open_classes = {c["class"].lower() for c in clients}
    open_commands = {proc_cmdline(c["pid"]) for c in clients if c["class"].lower() in TERMINALS}
    # Where each class is saved, so a repeated app can say where else it is.
    where = {}
    for ws in workspaces:
        for w in ws["windows"]:
            if not w.get("match_command"):
                where.setdefault(w["class"].lower(), []).append(ws["id"])
    live_monitor = {ws["id"]: by_name.get(ws["monitor"], {}).get("description") for ws in live}
    auto = auto_add_ids(config)
    empty = empty_slots(layout, clients, keywords, keys)
    empty_at = {(e[0], e[1]): e[3] for e in empty}
    for ws in workspaces:
        ws["ticked"] = bool(ticked.get(str(ws["id"])))
        ws["auto_add"] = ws["id"] in auto
        ws["unsaved_open"] = []
        for c in unsaved_open(ws["windows"], clients, ws["id"]):
            entry = window_entry(c)
            if entry:
                label, icon = display(entry)
                item = {"address": c["address"], "label": label, "icon": icon, "title": c["title"]}
                src = moved_from(entry, c, ws["id"], empty)
                if src:
                    item["from"] = src
                ws["unsaved_open"].append(item)
        for i, w in enumerate(ws["windows"]):
            w["label"], w["icon"] = display(w)
            # here: a matching window is on this workspace; elsewhere: one is
            # open on another workspace (open_on); closed: none is open.
            if (ws["id"], i) not in empty_at:
                w["state"] = "here"
            else:
                entry = dict(w, keyword=empty_at[(ws["id"], i)] or None)
                hit = next((c for c in clients if c["workspace"]["id"] != ws["id"] and matches(c, entry)), None)
                w["state"] = "elsewhere" if hit else "closed"
                if hit:
                    w["open_on"] = hit["workspace"]["id"]
            w["open"] = w["command"] in open_commands if w.get("match_command") \
                else w["class"].lower() in open_classes
            key = keys.get((ws["id"], i))
            if key:
                w["keyword_key"] = key
                w["keyword"] = keywords.get(key, "")
                saved_on = where.get(w["class"].lower(), [])
                w["twice_here"] = saved_on.count(ws["id"]) > 1
                w["also_on"] = sorted({i for i in saved_on if i != ws["id"]}, key=sort_key)
        ws["in_place"] = in_place(ws, keys, keywords, clients, live_monitor)
        # Open on another monitor than the saved one: restoring moves it back
        # until set-monitor saves the new one.
        # The panel shows each workspace on the screen it is on now.
        now = live_monitor.get(ws["id"])
        ws["screen"] = now or ws["monitor_desc"]
        if not ws.get("unsaved") and now and now != ws["monitor_desc"]:
            ws["now_on"] = now
    for ws in workspaces:
        if ws["id"] in busy:
            ws["in_use"] = identity(ids, ws["id"])
    for lw in other_live:
        desc = by_name.get(lw["monitor"], {}).get("description", "")
        items = []
        for c in other_clients:
            entry = window_entry(c) if c["workspace"]["id"] == lw["id"] else None
            if entry:
                label, icon = display(entry)
                items.append({"address": c["address"], "label": label, "icon": icon, "title": c["title"]})
        # borrowed: "borrowed" or "ask", the open workspace using the number.
        workspaces.append({"id": lw["id"], "name": lw["name"], "monitor": lw["monitor"], "monitor_desc": desc,
                           "screen": desc, "windows": [], "unsaved_open": items, "unsaved": True,
                           "borrowed": identity(ids, lw["id"]), "in_place": True, "ticked": False,
                           "auto_add": False})
    workspaces.sort(key=lambda w: (sort_key(w["id"]), "borrowed" in w))
    for ws in workspaces:
        ws["named"] = isinstance(ws["id"], str)
    layout["restoring"] = restore_running(d)
    # Copies of unreadable files, shown until the user deletes them.
    layout["broken"] = sorted({os.path.basename(p) for p in BROKEN}
                              | {f for f in os.listdir(d) if ".broken-" in f} if os.path.isdir(d) else ())
    layout["last_restore"] = read_json(os.path.join(d, "last-restore.json"), {})
    print(json.dumps(layout))


def empty_slots(layout, clients, keywords, keys):
    """Saved windows with no matching window open on their workspace, as
    [ws id, index, entry, keyword]. Slots with a title keyword are matched
    first, so a plain slot doesn't take their window."""
    out = []
    for ws in layout.get("workspaces", []):
        if ws.get("unsaved"):
            continue
        here = [c for c in clients if c["workspace"]["id"] == ws["id"]]
        kws = {i: keywords.get(keys.get((ws["id"], i)), "") for i in range(len(ws["windows"]))}
        taken = set()
        for i in sorted(kws, key=lambda i: not kws[i]):
            entry = dict(ws["windows"][i], keyword=kws[i] or None)
            hit = next((c for c in here if c["address"] not in taken and matches(c, entry)), None)
            if hit:
                taken.add(hit["address"])
            else:
                out.append([ws["id"], i, ws["windows"][i], kws[i]])
    return out


def moved_from(entry, client, ws_id, empty):
    """The saved slot an open window seems to have left: same app, saved on
    another workspace, nothing open there for it. A title keyword picks among
    several; with no keyword match and more than one plain slot, None. A slot
    is offered to one window only, so it's removed from empty."""
    cands = [s for s in empty if s[0] != ws_id and app_key(s[2]) == app_key(entry)]
    title = client["title"].lower()
    by_kw = [s for s in cands if s[3] and s[3].lower() in title]
    plain = [s for s in cands if not s[3]]
    pick = by_kw[0] if len(by_kw) == 1 else plain[0] if not by_kw and len(plain) == 1 else None
    if pick is None:
        return None
    empty.remove(pick)
    return {"ws": pick[0], "index": pick[1] + 1, "class": pick[2]["class"]}


def in_place(ws, keys, keywords, clients, live_monitor):
    """True when restoring this workspace would change nothing: it is on its
    saved screen and every app on its list has a window on it."""
    if live_monitor.get(ws["id"]) != ws["monitor_desc"]:
        return False
    taken = set()
    for i, w in enumerate(ws["windows"]):
        key = keys.get((ws["id"], i))
        keyword = keywords.get(key, "") if key else ""
        if key and not keyword:
            # Restore leaves this window where it opens; it only launches
            # the app if it isn't running at all.
            if not any(c["class"].lower() == w["class"].lower() for c in clients):
                return False
            continue
        entry = dict(w, keyword=keyword or None)
        hit = next((c for c in clients if c["address"] not in taken and c["workspace"]["id"] == ws["id"]
                    and matches(c, entry)), None)
        if hit is None:
            return False
        taken.add(hit["address"])
    return True


def update_config(args, fn):
    path = os.path.join(state_dir(args), "config.json")
    config = read_json(path, {})
    fn(config)
    write_json(path, config)
    print(json.dumps({"ok": True}))


def cmd_set_tick(args):
    def fn(config):
        ticked = config.setdefault("ticked", {})
        for ws in args.ws:
            ticked[str(ws)] = args.value == "1"
    update_config(args, fn)


def cmd_set_keyword(args):
    def fn(config):
        keywords = config.setdefault("keywords", {})
        text = args.text.strip()
        if text:
            keywords[args.key] = text
        else:
            keywords.pop(args.key, None)
    update_config(args, fn)


# --- editing the saved layout ----------------------------------------------

def installed_apps():
    """Launchable apps from .desktop files, by name."""
    apps = [{"id": e["id"], "name": e["name"], "about": e["about"],
             "class": e["wm_class"] or e["id"], "command": e["exec"]}
            for e in desktop_index() if e["app"] and e["exec"]]
    return sorted(apps, key=lambda a: a["name"].lower())


def saved_windows(layout, ws_id):
    return next((ws["windows"] for ws in layout.get("workspaces", []) if ws["id"] == ws_id), [])


def unsaved_open(saved, clients, ws_id):
    """Windows open on workspace ws_id that its saved list doesn't cover yet.
    Counts per class, so a second Firefox window counts as new."""
    left, commands = {}, set()
    for w in saved:
        if w.get("match_command"):
            commands.add(w["command"])
        else:
            left[w["class"].lower()] = left.get(w["class"].lower(), 0) + 1
    out = []
    for c in sorted(clients, key=lambda c: (c["at"][0], c["at"][1])):
        if c["workspace"]["id"] != ws_id or not c["class"]:
            continue
        cls = c["class"].lower()
        if cls in TERMINALS:
            cmd = terminal_command(c)
            if not cmd or cmd in commands:
                continue
            commands.add(cmd)
        elif left.get(cls):
            left[cls] -= 1
            continue
        out.append(c)
    return out


def cmd_candidates(args):
    here = saved_windows(read_json(layout_path(args), {}), args.ws)
    here_classes = {w["class"].lower() for w in here if not w.get("match_command")}
    here_commands = {w["command"] for w in here if w.get("match_command")}
    clients = hypr("clients")
    new_here = {c["address"] for c in unsaved_open(here, clients, args.ws)}
    wins = []
    # Windows on this workspace first, then the others by workspace.
    for c in sorted(clients, key=lambda c: (c["workspace"]["id"] != args.ws, sort_key(c["workspace"]["id"]), c["at"][0])):
        if not c["class"] or c["workspace"]["id"] is None:
            continue
        entry = window_entry(c)
        if entry is None:  # plain shells can't be restored
            continue
        label, icon = display(entry)
        saved = entry["command"] in here_commands if entry.get("match_command") \
            else entry["class"].lower() in here_classes
        # A window on this workspace that its list already covers can't be
        # added again (add-window skips it).
        listed = c["workspace"]["id"] == args.ws and c["address"] not in new_here
        wins.append({"address": c["address"], "label": label, "icon": icon, "title": c["title"],
                     "ws": c["workspace"]["id"], "saved_here": saved, "listed": listed})
    apps = [dict(a, saved_here=a["class"].lower() in here_classes) for a in installed_apps()]
    unsaved = len(unsaved_open(here, clients, args.ws)) if args.ws is not None else 0
    print(json.dumps({"windows": wins, "apps": apps, "unsaved_here": unsaved}))


def live_workspace(ws_id):
    """Saved form of an open workspace with no windows yet, or None."""
    ws = next((w for w in hypr("workspaces") if w["id"] == ws_id), None)
    if ws is None:
        return None
    return workspace_entry(ws, {m["name"]: m for m in hypr("monitors")}, [])


def get_workspace(layout, ws_id):
    """The saved workspace, created from the open one if it isn't saved yet."""
    workspaces = layout.setdefault("workspaces", [])
    ws = next((w for w in workspaces if w["id"] == ws_id), None)
    if ws is None:
        ws = live_workspace(ws_id)
        if ws is not None:
            workspaces.append(ws)
            workspaces.sort(key=lambda w: sort_key(w["id"]))
    return ws


def edit_layout(args, fn):
    layout = read_json(layout_path(args), {})
    ws = get_workspace(layout, args.ws)
    if ws is None:
        print(json.dumps({"ok": False, "error": f"workspace {args.ws} is not saved or open"}))
        return 1
    error = fn(layout, ws)
    if error:
        print(json.dumps({"ok": False, "error": error}))
        return 1
    layout["saved"] = int(time.time())
    write_json(layout_path(args), layout)
    print(json.dumps({"ok": True}))
    return 0


def app_key(window):
    """How auto-add's skip list names an app: class, or command for terminals."""
    return "cmd:" + window["command"] if window.get("match_command") else window["class"].lower()


def set_skipped(args, ws_id, keys, skip):
    """Add keys to (skip=True) or drop them from workspace ws_id's auto-add
    skip list: apps the user removed there, which auto-add must not bring
    back until the user adds them again."""
    path = os.path.join(state_dir(args), "config.json")
    config = read_json(path, {})
    lists = config.setdefault("auto_add_skip", {})
    current = set(lists.get(str(ws_id), []))
    new = current | set(keys) if skip else current - set(keys)
    if new != current:
        lists[str(ws_id)] = sorted(new)
        write_json(path, config)


def cmd_add_window(args):
    if refuse_in_use(args, args.ws):
        return 1
    if args.address:
        clients = hypr("clients")
        client = next((c for c in clients if c["address"] == args.address), None)
        if client is None:
            print(json.dumps({"ok": False, "error": "that window is gone"}))
            return 1
        # A window on this workspace that its list already covers (auto-add
        # may have just added it while the panel still offered it) is not
        # added twice. A second window of the same app still counts as new.
        if client["workspace"]["id"] == args.ws:
            here = saved_windows(read_json(layout_path(args), {}), args.ws)
            if all(c["address"] != args.address for c in unsaved_open(here, clients, args.ws)):
                print(json.dumps({"ok": True, "note": "already on the list"}))
                return 0
        entry = window_entry(client)
    else:
        app = next((a for a in installed_apps() if a["id"] == args.desktop), None)
        entry = app and {"class": app["class"], "title": app["name"], "command": app["command"]}
    if entry is None:
        print(json.dumps({"ok": False, "error": "nothing to add"}))
        return 1

    def fn(layout, ws):
        ws["windows"].append(entry)
        set_skipped(args, ws["id"], [app_key(entry)], False)
    return edit_layout(args, fn)


def cmd_add_open(args):
    if refuse_in_use(args, args.ws):
        return 1
    clients = hypr("clients")

    def fn(layout, ws):
        new = [w for w in (window_entry(c) for c in unsaved_open(ws["windows"], clients, ws["id"])) if w]
        ws["windows"].extend(new)
        set_skipped(args, ws["id"], [app_key(w) for w in new], False)
    return edit_layout(args, fn)


def cmd_remove_window(args):
    def fn(layout, ws):
        i = args.index - 1
        if not 0 <= i < len(ws["windows"]) or ws["windows"][i]["class"] != args.cls:
            return "the layout changed, reopen the panel"
        # Keyword keys count windows of one class per workspace, so the ones
        # after the removed window move down by one.
        old = slot_keys(layout)
        removed = ws["windows"].pop(i)
        new = slot_keys(layout)
        if not any(app_key(w) == app_key(removed) for w in ws["windows"]):
            set_skipped(args, ws["id"], [app_key(removed)], True)
        path = os.path.join(state_dir(args), "config.json")
        config = read_json(path, {})
        keywords = config.get("keywords", {})
        if keywords:
            moved = {}
            for (ws_id, j), key in old.items():
                if ws_id == ws["id"] and j == i:
                    continue
                nj = j - 1 if ws_id == ws["id"] and j > i else j
                if key in keywords and (ws_id, nj) in new:
                    moved[new[(ws_id, nj)]] = keywords[key]
            config["keywords"] = moved
            write_json(path, config)
    return edit_layout(args, fn)


def cmd_set_monitor(args):
    def fn(layout, ws):
        live = live_workspace(ws["id"])
        if live is None:
            return f"workspace {ws['id']} is not open"
        if pinned_elsewhere(ws["id"], live["monitor_desc"]):
            return f"workspace {ws['id']} is pinned to another monitor"
        ws.update({k: live[k] for k in ("monitor", "monitor_desc", "monitor_x")})
    return edit_layout(args, fn)


def pinned_elsewhere(ws_id, desc, rules=None):
    """The monitor a rule pins ws_id to, if that isn't desc."""
    if rules is None:
        rules = workspace_rules(hypr("monitors"))
    pin = rules.get(ws_id, {}).get("pin")
    return pin["monitor_desc"] if pin and pin["monitor_desc"] != desc else None


def cmd_rename(args):
    if refuse_named(args.ws):
        return 1
    rules = workspace_rules(hypr("monitors"))
    name = (args.name or "").strip()[:40]

    def fn(layout, ws):
        ws["name"] = name or str(ws["id"])
    if edit_layout(args, fn):
        return 1
    if any(w["id"] == args.ws for w in hypr("workspaces")):
        Dispatcher(False).rename_workspace(args.ws, name or default_name(args.ws, rules))
    return 0


def slot_windows(layout):
    return {(ws["id"], j): w for ws in layout.get("workspaces", []) for j, w in enumerate(ws["windows"])}


def cmd_move_window(args):
    if refuse_in_use(args, args.ws):
        return 1

    def fn(layout, ws):
        src = next((w for w in layout["workspaces"] if w["id"] == args.from_ws), None)
        i = args.index - 1
        if src is None or src is ws or not 0 <= i < len(src["windows"]) \
                or src["windows"][i]["class"] != args.cls:
            return "the layout changed, reopen the panel"
        # Keyword keys are positions, so carry each keyword by its window.
        path = os.path.join(state_dir(args), "config.json")
        config = read_json(path, {})
        keywords = config.get("keywords", {})
        wins = slot_windows(layout)
        by_window = {id(wins[pos]): keywords[key] for pos, key in slot_keys(layout).items() if key in keywords}
        entry = src["windows"].pop(i)
        ws["windows"].append(entry)
        set_skipped(args, ws["id"], [app_key(entry)], False)
        if keywords:
            config = read_json(path, {})  # set_skipped may have written it
            wins = slot_windows(layout)
            config["keywords"] = {key: by_window[id(wins[pos])] for pos, key in slot_keys(layout).items()
                                  if id(wins[pos]) in by_window}
            write_json(path, config)
    return edit_layout(args, fn)


def auto_add_ids(config):
    auto = config.get("auto_add")
    return {parse_key(k) for k, v in auto.items() if v} if isinstance(auto, dict) else set()


def cmd_set_auto_add(args):
    def fn(config):
        auto = config.get("auto_add")
        if not isinstance(auto, dict):
            auto = config["auto_add"] = {}
        for ws in args.ws:
            auto[str(ws)] = args.value == "1"
    update_config(args, fn)


def restore_running(d):
    path = os.path.join(d, "restore.lock")
    if not os.path.exists(path):
        return False
    try:
        with open(path, "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(lock, fcntl.LOCK_UN)
        return False
    except OSError:
        return True


def cmd_auto_add(args):
    d = state_dir(args)
    touch(session_path(args, "heartbeat"))  # the bar is alive: the watcher keeps going
    config = read_json(os.path.join(d, "config.json"), {})
    # During a restore windows sit on the wrong workspace for a moment.
    auto = auto_add_ids(config)
    if not auto or restore_running(d):
        print(json.dumps({"ok": True, "added": []}))
        return 0
    layout = read_json(layout_path(args), {})
    # Only apps saved nowhere yet: an app moved to another workspace for a
    # while must not end up saved twice. Floating windows are mostly dialogs.
    classes = {w["class"].lower() for ws in layout.get("workspaces", []) for w in ws["windows"]
               if not w.get("match_command")}
    commands = {w["command"] for ws in layout.get("workspaces", []) for w in ws["windows"]
                if w.get("match_command")}
    skipped = config.get("auto_add_skip", {})
    busy = in_use(args)  # another workspace has that number
    added = []
    for c in sorted(hypr("clients"), key=lambda c: (c["at"][0], c["at"][1])):
        if c["workspace"]["id"] not in auto or c["workspace"]["id"] in busy or not c["class"] \
                or c.get("floating"):
            continue
        entry = window_entry(c)
        if entry is None or app_key(entry) in skipped.get(str(c["workspace"]["id"]), []):
            continue
        if entry.get("match_command"):
            if entry["command"] in commands:
                continue
            commands.add(entry["command"])
        else:
            if entry["class"].lower() in classes:
                continue
            classes.add(entry["class"].lower())
        ws = get_workspace(layout, c["workspace"]["id"])
        if ws is None:
            continue
        ws["windows"].append(entry)
        added.append({"class": entry["class"], "label": display(entry)[0], "ws": ws["id"]})
    if added:
        layout["saved"] = int(time.time())
        write_json(layout_path(args), layout)
    print(json.dumps({"ok": True, "added": added}))
    return 0


# --- restore ----------------------------------------------------------------

def matches(client, entry):
    if client["class"].lower() != entry["class"].lower():
        return False
    if entry.get("match_command"):
        return proc_cmdline(client["pid"]) == entry["command"]
    kw = entry.get("keyword")
    return not kw or kw.lower() in client["title"].lower()


def first_in_session():
    """True for the first call per Hyprland session, False after that.

    The marker sits in $XDG_RUNTIME_DIR, which is cleared at logout, and is
    named after the Hyprland instance, so restarting the bar doesn't reopen
    apps but a new login does. O_EXCL settles the race between the bar
    widgets on several monitors.
    """
    run_dir = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    instance = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "default")
    path = os.path.join(run_dir, f"workspace-restore-login-{os.getuid()}-{instance}")
    try:
        os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
    except FileExistsError:
        return False
    return True


# --- workspace identity --------------------------------------------------------
# A saved number that closed can come back as a different workspace, such as
# a new one taking the lowest free number. The watcher follows Hyprland's
# events and notes per saved number: closed (not open), pending (open again,
# no window yet), borrowed (another workspace uses the number) or ask (the
# signs are mixed, the panel asks). A saved number in none of these is the
# saved workspace.

def session_path(args, name):
    """A file for this Hyprland session: in $XDG_RUNTIME_DIR, or in
    --state-dir when testing."""
    if args.state_dir:
        return os.path.join(state_dir(args), name)
    run_dir = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    instance = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "default")
    return os.path.join(run_dir, f"workspace-restore-{name}-{os.getuid()}-{instance}")


def read_ids(args):
    data = read_json(session_path(args, "ids.json"), {})
    return {state: set(data.get(state, [])) for state in IDENTITY_STATES}


def identity(ids, ws_id):
    return next((s for s in IDENTITY_STATES if ws_id in ids[s]), "real")


def set_identity(ids, ws_id, state):
    for s in IDENTITY_STATES:
        ids[s].discard(ws_id)
    if state != "real":
        ids[state].add(ws_id)


def edit_ids(args, fn):
    path = session_path(args, "ids.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        ids = read_ids(args)
        fn(ids)
        write_json(path, {s: sorted(v) for s, v in ids.items()})


def in_use(args):
    """Saved numbers another workspace is using, or that the panel asks about.
    A saved workspace with no apps left isn't kept apart any more."""
    ids = read_ids(args)
    return (ids["borrowed"] | ids["ask"]) & saved_ids(args)


def refuse_in_use(args, ws_id):
    if ws_id in in_use(args):
        print(json.dumps({"ok": False, "error": f"workspace {ws_id} is in use by another workspace"}))
        return True
    return False


def touch(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a"):
        pass
    os.utime(path)


def mark_acting(args):
    """Workspaces created in the next few seconds are the plugin's own."""
    touch(session_path(args, "acting"))


def acting(args):
    d = state_dir(args)
    try:
        recent = time.time() - os.path.getmtime(session_path(args, "acting")) < ACTING_S
    except OSError:
        recent = False
    return recent or restore_running(d)


def saved_ids(args):
    """Saved numbers with apps. Named workspaces aren't tracked: no other
    workspace can come back under their name."""
    return {w["id"] for w in read_json(layout_path(args), {}).get("workspaces", [])
            if w["windows"] and isinstance(w["id"], int)}


def first_window_identity(args, ws_id, client):
    """Whose is a saved number that came back, judged by its first window:
    one of its saved apps on its saved monitor is the saved workspace, an app
    it doesn't have is another workspace, a saved app elsewhere is unclear."""
    ws = next((w for w in read_json(layout_path(args), {}).get("workspaces", []) if w["id"] == ws_id), None)
    if ws is None:
        return "real"
    if not any(matches(client, dict(w, keyword=None)) for w in ws["windows"]):
        return "borrowed"
    monitors = hypr("monitors")
    apply_pins([ws], workspace_rules(monitors))
    on = next((w["monitor"] for w in hypr("workspaces") if w["id"] == ws_id), None)
    here = next((m["description"] for m in monitors if m["name"] == on), None)
    return "real" if here == ws["monitor_desc"] else "ask"


def watch_event(args, event, data):
    if event in ("createworkspacev2", "destroyworkspacev2"):
        ws_id, _, name = data.partition(",")
        ws_id = ws_key(int(ws_id), name)
        if ws_id not in saved_ids(args):
            return
        if event == "destroyworkspacev2":
            state = "closed"
        else:
            state = "real" if acting(args) else "pending"
        edit_ids(args, lambda ids: set_identity(ids, ws_id, state))
    elif event in ("openwindow", "movewindowv2"):
        pending = read_ids(args)["pending"]
        if not pending:
            return
        # openwindow names the workspace, which may be a custom name, so look
        # the window up by its address.
        address = "0x" + data.split(",")[0]
        client = next((c for c in hypr("clients") if c["address"] == address), None)
        if client is None or client["workspace"]["id"] not in pending:
            return
        ws_id = client["workspace"]["id"]
        state = "real" if acting(args) else first_window_identity(args, ws_id, client)
        edit_ids(args, lambda ids: set_identity(ids, ws_id, state))


def cmd_watch(args):
    os.makedirs(state_dir(args), exist_ok=True)
    with open(session_path(args, "watch.lock"), "w") as lock:  # one watcher per session
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print(json.dumps({"ok": True, "note": "already watching"}))
            return 0
        return watch(args)


def watch(args):
    me = os.path.abspath(__file__)
    version = os.path.getmtime(me)
    heartbeat = session_path(args, "heartbeat")
    touch(heartbeat)
    run_dir = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    sock = socket.socket(socket.AF_UNIX)
    sock.connect(os.path.join(run_dir, "hypr", os.environ["HYPRLAND_INSTANCE_SIGNATURE"], ".socket2.sock"))
    sock.settimeout(10)
    # First start this session: saved numbers that are open now are the
    # saved workspaces. A restarted watcher keeps what it had noted.
    if not os.path.exists(session_path(args, "ids.json")):
        closed = saved_ids(args) - {w["id"] for w in hypr("workspaces")}
        edit_ids(args, lambda ids: ids["closed"].update(closed))
    buf = b""
    while True:
        try:
            chunk = sock.recv(65536)
            if not chunk:
                return 0  # Hyprland quit
            buf += chunk
        except TimeoutError:
            pass
        # A changed wsr.py means an update: quit so the bar starts the new
        # one. No check-in from the bar for a while means it's gone or the
        # plugin is off.
        try:
            stale = time.time() - os.path.getmtime(heartbeat) > HEARTBEAT_MAX
        except OSError:
            stale = True
        if os.path.getmtime(me) != version or stale:
            return 0
        *lines, buf = buf.split(b"\n")
        for line in lines:
            event, _, data = line.decode(errors="replace").partition(">>")
            try:
                watch_event(args, event, data)
            except (OSError, ValueError, subprocess.CalledProcessError):
                pass


def cmd_set_identity(args):
    if refuse_named(args.ws):
        return 1
    edit_ids(args, lambda ids: set_identity(ids, args.ws, args.state))
    print(json.dumps({"ok": True}))
    return 0


def cmd_renumber_saved(args):
    """Only the saved files change; Hyprland's workspace with that number
    stays as it is and is no longer the saved one."""
    layout = read_json(layout_path(args), {})
    workspaces = layout.get("workspaces", [])
    if refuse_named(args.ws):
        return 1
    ws = next((w for w in workspaces if w["id"] == args.ws), None)
    if ws is None:
        print(json.dumps({"ok": False, "error": f"workspace {args.ws} is not saved"}))
        return 1
    ruled = {i for i in workspace_rules(hypr("monitors")) if isinstance(i, int)}
    taken = {w["id"] for w in workspaces + hypr("workspaces") if isinstance(w["id"], int)}
    used = taken | ruled
    new = args.new
    if new is None:
        # Above every saved and open number: the low free ones are what new
        # workspaces take next, which would take this one's number again.
        new = max(taken - ruled, default=0) + 1
        while new in used:
            new += 1
    elif new in used or new < 1:
        print(json.dumps({"ok": False, "error": f"{new} is open, saved or has a workspace rule"}))
        return 1
    if ws["name"] == str(ws["id"]):
        ws["name"] = str(new)
    ws["id"] = new
    workspaces.sort(key=lambda w: sort_key(w["id"]))
    layout["saved"] = int(time.time())
    write_json(layout_path(args), layout)
    path = os.path.join(state_dir(args), "config.json")
    config = read_json(path, {})
    renumber_config(config, {args.ws: new})
    write_json(path, config)
    def fn(ids):
        set_identity(ids, args.ws, "real")  # the open one is just a workspace now
        set_identity(ids, new, "closed")
    edit_ids(args, fn)
    print(json.dumps({"ok": True, "ws": new}))
    return 0


def show_again(dsp, visible, focused):
    """Show each monitor's workspace from visible again, focused monitor last."""
    for name, ws_id in visible.items():
        if name != focused:
            dsp.focus_workspace(ws_id)
    if focused in visible:
        dsp.focus_workspace(visible[focused])


def cmd_move_workspace(args):
    d = state_dir(args)
    if restore_running(d):
        print(json.dumps({"ok": False, "error": "a restore is running"}))
        return 1
    mon = next((m for m in hypr("monitors") if m["description"] == args.desc), None)
    if mon is None:
        print(json.dumps({"ok": False, "error": "that screen isn't connected"}))
        return 1
    if pinned_elsewhere(args.ws, mon["description"]):
        print(json.dumps({"ok": False, "error": f"workspace {args.ws} is pinned to another monitor"}))
        return 1
    if any(w["id"] == args.ws for w in hypr("workspaces")):
        Dispatcher(False).move_workspace(args.ws, mon["name"])
    layout = read_json(layout_path(args), {})
    ws = next((w for w in layout.get("workspaces", []) if w["id"] == args.ws), None)
    if ws is not None:
        ws.update({"monitor": mon["name"], "monitor_desc": mon["description"], "monitor_x": mon["x"]})
        layout["saved"] = int(time.time())
        write_json(layout_path(args), layout)
    print(json.dumps({"ok": True}))
    return 0


def drop_config(config, ids):
    """Forget everything config.json keeps for these workspaces."""
    keys = {str(i) for i in ids}
    for name in ("ticked", "auto_add", "auto_add_skip"):
        if isinstance(config.get(name), dict):
            config[name] = {k: v for k, v in config[name].items() if k not in keys}
    if isinstance(config.get("keywords"), dict):
        config["keywords"] = {k: v for k, v in config["keywords"].items() if k.partition("|")[0] not in keys}


def renumber_config(config, mapping):
    """Re-key everything config.json keeps per workspace."""
    for name in ("ticked", "auto_add", "auto_add_skip"):
        table = config.get(name)
        if isinstance(table, dict):
            config[name] = {str(mapping.get(int(k), int(k))) if k.lstrip("-").isdigit() else k: v
                            for k, v in table.items()}
    keywords = config.get("keywords")
    if isinstance(keywords, dict):
        out = {}
        for key, v in keywords.items():
            ws_id, _, rest = key.partition("|")
            if ws_id.lstrip("-").isdigit():
                key = f"{mapping.get(int(ws_id), int(ws_id))}|{rest}"
            out[key] = v
        config["keywords"] = out


def cmd_renumber(args):
    d = state_dir(args)
    try:
        mapping = {int(a): int(b) for a, b in (pair.split(":") for pair in args.pairs)}
    except ValueError:
        print(json.dumps({"ok": False, "error": "use OLD:NEW pairs of numbers"}))
        return 1
    mapping = {a: b for a, b in mapping.items() if a != b}
    names = {}
    for item in args.name or []:
        old, sep, name = item.partition("=")
        if not sep or not old.isdigit():
            print(json.dumps({"ok": False, "error": "use --name OLD=NAME"}))
            return 1
        names[int(old)] = name.strip()[:40]
    if restore_running(d):
        print(json.dumps({"ok": False, "error": "a restore is running"}))
        return 1
    layout = read_json(layout_path(args), {})
    workspaces = layout.get("workspaces", [])
    # Named workspaces keep their names: they aren't renumbered.
    live = {w["id"]: w for w in hypr("workspaces") if isinstance(w["id"], int)}
    clients = hypr("clients")
    # Workspaces that count: saved ones with apps, and open ones with windows
    # (an empty open workspace is dropped by Hyprland once it isn't shown).
    shown = {w["id"] for w in workspaces if w["windows"] and isinstance(w["id"], int)} | set(live)
    if any(b <= 0 for b in mapping.values()):
        print(json.dumps({"ok": False, "error": "numbers start at 1"}))
        return 1
    final = [mapping.get(i, i) for i in shown | set(mapping)]
    dupes = sorted({n for n in final if final.count(n) > 1})
    if dupes:
        print(json.dumps({"ok": False, "error": "duplicate numbers", "duplicates": dupes}))
        return 1
    # A number pinned to a monitor only goes to a workspace on that monitor.
    monitors = hypr("monitors")
    rules = workspace_rules(monitors)
    by_name = {m["name"]: m["description"] for m in monitors}
    saved_desc = {w["id"]: w["monitor_desc"] for w in workspaces}
    for old, new in mapping.items():
        desc = by_name.get(live[old]["monitor"]) if old in live else saved_desc.get(old)
        pin = pinned_elsewhere(new, desc, rules)
        if pin:
            print(json.dumps({"ok": False, "error": f"{new} is pinned to {pin}", "pinned": new}))
            return 1
    busy = in_use(args) & (set(mapping) | set(mapping.values()))
    if busy:
        print(json.dumps({"ok": False, "error": f"workspace {min(busy)} is in use by another workspace"}))
        return 1
    if not mapping and not names:
        print(json.dumps({"ok": True}))
        return 0
    if not args.dry_run:
        mark_acting(args)

    # Hyprland: every window of a renumbered workspace goes to its new
    # number, through a spare number first so swaps don't mix them up. Each
    # new workspace then goes to the old one's monitor.
    focused = next((m["name"] for m in monitors if m.get("focused")), None)
    visible = {m["name"]: m["activeWorkspace"]["id"] for m in monitors}
    dsp = Dispatcher(args.dry_run)
    spare = max(final + list(live) + [1000]) + 1
    moving = [c for c in clients if c["workspace"]["id"] in mapping]
    for c in moving:
        dsp.move_window(c["address"], spare + c["workspace"]["id"])
    for c in moving:
        dsp.move_window(c["address"], mapping[c["workspace"]["id"]])
    # Only numbers that got windows exist now. Moving or focusing one that
    # doesn't would hit the focused workspace instead, so an empty open
    # workspace keeps its old number in Hyprland; its saved list still moves.
    filled = {c["workspace"]["id"] for c in moving}
    for old in filled:
        dsp.move_workspace(mapping[old], live[old]["monitor"])
    # Screens that showed a renumbered workspace show it under its new number.
    if any(i in filled for i in visible.values()):
        show_again(dsp, {n: mapping.get(i, i) for n, i in visible.items() if i in filled or n == focused}, focused)

    # A saved workspace with no apps that isn't open doesn't show in the
    # panel. If its number is taken, drop it and its settings, so the
    # workspace getting the number keeps its own.
    stale = {w["id"] for w in workspaces if not w["windows"] and w["id"] not in live
             and w["id"] not in mapping and w["id"] in mapping.values()}
    workspaces[:] = [w for w in workspaces if w["id"] not in stale]
    by_old = {}
    for ws in workspaces:
        by_old[ws["id"]] = ws
        if ws["id"] in mapping:
            if ws["name"] == str(ws["id"]):
                ws["name"] = str(mapping[ws["id"]])
            ws["id"] = mapping[ws["id"]]
    for old, name in names.items():
        new = mapping.get(old, old)
        if old not in by_old and old in live:  # open but not saved yet
            by_old[old] = dict(workspace_entry(live[old], {m["name"]: m for m in monitors}, []), id=new)
            workspaces.append(by_old[old])
        if old in by_old:
            by_old[old]["name"] = name or str(new)
    workspaces.sort(key=lambda w: sort_key(w["id"]))
    # Names in Hyprland: given ones, and the ones renumbered workspaces carry.
    exists = {mapping.get(i, i) for i in live if i not in mapping or i in filled}
    for old, ws in by_old.items():
        if ws["id"] in exists and (old in names or (old in filled and custom_name(ws))):
            dsp.rename_workspace(ws["id"], custom_name(ws) or default_name(ws["id"], rules))
    if not args.dry_run:
        layout["saved"] = int(time.time())
        write_json(layout_path(args), layout)
        path = os.path.join(d, "config.json")
        config = read_json(path, {})
        drop_config(config, stale)
        renumber_config(config, mapping)
        write_json(path, config)

        def remap(ids):
            for state in IDENTITY_STATES:
                ids[state] = {mapping.get(i, i) for i in ids[state] if i not in stale}
        edit_ids(args, remap)
        mark_acting(args)
    print(json.dumps({"ok": True, "kept_open": sorted(i for i in mapping if i in live and i not in filled)}))
    return 0


def cmd_restore(args):
    if args.once and not args.dry_run and not first_in_session():
        print(json.dumps({"ok": True, "note": "already ran this session"}))
        return 0
    d = state_dir(args)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "restore.lock"), "w") as lock:
        # status probes this lock for a moment on every bar poll, and at
        # login that poll can land right as this starts, so retry briefly. A
        # real restore holds it far longer.
        deadline = time.time() + 2
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.time() >= deadline:
                    print(json.dumps({"ok": False, "error": "a restore is already running"}))
                    return 1
                time.sleep(0.1)
        return restore(args, d)


def restore(args, d):
    layout = read_json(os.path.join(d, "layout.json"), {})
    config = read_json(os.path.join(d, "config.json"), {})
    ticked = config.get("ticked", {})
    keywords = config.get("keywords", {})
    keys = slot_keys(layout)

    selected = []
    for ws in layout.get("workspaces", []):
        if args.all or (args.ticked and ticked.get(str(ws["id"]))) or ws["id"] in (args.ws or []) \
                or (args.monitor and ws["monitor_desc"] == args.monitor):
            selected.append(ws)
    # A number another workspace is using: don't move that one, launch apps
    # into it or pull windows to it.
    busy = in_use(args)
    in_use_skipped = sorted(ws["id"] for ws in selected if ws["id"] in busy)
    selected = [ws for ws in selected if ws["id"] not in busy]
    if not selected:
        if in_use_skipped and not args.dry_run:
            write_json(os.path.join(d, "last-restore.json"),
                       {"time": int(time.time()), "workspaces": [], "skipped": [], "launched": [], "moved": 0,
                        "unmatched": [], "set_aside": [], "in_use": in_use_skipped})
        print(json.dumps({"ok": True, "note": "nothing selected", "in_use": in_use_skipped}))
        return 0
    # At login monitors can show up a moment after Hyprland starts. Until
    # then a pin is only its rule's text: a description prefix or a name.
    pins = {i: r["pin"]["monitor_desc"] for i, r in workspace_rules([]).items() if "pin" in r}
    wanted = {pins.get(ws["id"], ws["monitor_desc"]) for ws in selected}
    deadline = time.time() + (20 if args.wait_monitors else 0)
    while True:
        monitors = hypr("monitors")
        if all(any(m["description"].startswith(w) or m["name"] == w for m in monitors) for w in wanted) \
                or time.time() >= deadline:
            break
        time.sleep(POLL_INTERVAL)
    desc_to_name = {m["description"]: m["name"] for m in monitors}
    rules = workspace_rules(monitors)
    apply_pins(selected, rules)

    dsp = Dispatcher(args.dry_run)
    focused = next((m["name"] for m in monitors if m.get("focused")), None)
    visible = {m["name"]: m["activeWorkspace"]["id"] for m in monitors}

    report = {"time": int(time.time()), "workspaces": [], "skipped": [], "launched": [], "moved": 0, "unmatched": [],
              "set_aside": [], "in_use": in_use_skipped}
    entries = []
    ws_monitor = {}
    for ws in selected:
        mon = desc_to_name.get(ws["monitor_desc"])
        if mon is None:
            report["skipped"].append(ws["id"])  # its monitor is not connected
            continue
        ws_monitor[ws["id"]] = mon
        report["workspaces"].append(ws["id"])
        for i, w in enumerate(ws["windows"]):
            key = keys.get((ws["id"], i))
            keyword = keywords.get(key, "") if key else ""
            # A class saved more than once is told apart by its title keyword;
            # without one, that window stays wherever it opens.
            entries.append({"class": w["class"], "ws": ws["id"], "command": w["command"],
                            "keyword": keyword or None, "place": not (key and not keyword),
                            "match_command": bool(w.get("match_command")), "label": display(w)[0]})

    taken_numbers, aside_done = set(), set()

    def free_number(existing):
        """Lowest number that isn't open, saved, pinned or already used here."""
        used = existing | {w["id"] for w in layout.get("workspaces", [])} | set(rules) | taken_numbers
        n = 1
        while n in used:
            n += 1
        taken_numbers.add(n)
        return n

    def set_aside(ws_id, here, current):
        """Windows on ws_id that aren't on its list go to a new workspace on
        the monitor they're on, so moving ws_id doesn't drag them along."""
        mine = [e for e in entries if e["ws"] == ws_id]
        others = [c for c in hypr("clients") if c["workspace"]["id"] == ws_id
                  and not any(matches(c, e) for e in mine)]
        if not others or ws_id in aside_done:
            return
        aside_done.add(ws_id)
        free = free_number(set(current))
        for c in others:
            dsp.move_window(c["address"], free)
        # Move the new workspace only once it exists: a missing one would
        # hit the focused workspace instead.
        if args.dry_run or any(w["id"] == free for w in hypr("workspaces")):
            dsp.move_workspace(free, here)
            if visible.get(here) == ws_id:
                visible[here] = free  # that screen keeps showing those windows
        report["set_aside"].append({"from": ws_id, "ws": free, "count": len(others)})

    def place_workspaces():
        current = {w["id"]: w["monitor"] for w in hypr("workspaces")}
        for ws_id, mon in ws_monitor.items():
            # Only existing workspaces are moved; a missing one is created on
            # its monitor once a window lands in it and placed next round.
            if ws_id in current and current[ws_id] != mon:
                set_aside(ws_id, current[ws_id], current)
                dsp.move_workspace(ws_id, mon)
                current[ws_id] = mon

    place_workspaces()

    # Launch each class with no window at all, once. One Firefox launch brings
    # back every window through its own session restore.
    clients = hypr("clients")
    running = {c["class"].lower() for c in clients}
    launched = set()
    for e in entries:
        # Terminals launch per command: one btop window says nothing about
        # whether another terminal command is open.
        if e["match_command"]:
            if e["command"] and not any(matches(c, e) for c in clients):
                dsp.exec(e["command"], e["ws"] if e["place"] else None)
                launched.add(e["command"])
                report["launched"].append(e["label"])
            continue
        cls = e["class"].lower()
        if cls in running or cls in launched or not e["command"]:
            continue
        dsp.exec(e["command"], e["ws"] if e["place"] else None)
        launched.add(cls)
        report["launched"].append(e["label"])

    # Keyword slots first so a plain class match cannot take a window a
    # keyword is waiting for.
    pending = sorted((e for e in entries if e["place"]), key=lambda e: not e["keyword"])
    done = set()
    deadline = time.time() + (LAUNCH_TIMEOUT if launched and not args.dry_run else 0)
    settle_until = 0
    while True:
        clients = hypr("clients")
        # Apps like Vesktop open a splash window first. The exec rule only
        # places that first window, so when a matched window closes, the slot
        # opens again for the real window that follows.
        alive = {c["address"] for c in clients}
        for e in pending:
            if e.get("address") and e["address"] not in alive:
                del e["address"]
        taken = {a for a in done if a in alive}
        for e in pending:
            if e.get("address"):
                continue
            for c in clients:
                if c["address"] in taken or not matches(c, e):
                    continue
                taken.add(c["address"])
                e["address"] = c["address"]
                if c["workspace"]["id"] != e["ws"]:
                    dsp.move_window(c["address"], e["ws"])
                    report["moved"] += 1
                settle_until = time.time() + SETTLE
                break
        done = taken
        place_workspaces()
        if time.time() >= deadline:
            break
        # Keep watching a little after the last match for windows that
        # replace a splash.
        if all(e.get("address") for e in pending) and time.time() >= settle_until:
            break
        time.sleep(POLL_INTERVAL)
    report["unmatched"] = [f"{e['label']} ({e['keyword']})" if e["keyword"] else e["label"]
                           for e in pending if not e.get("address")]

    # Names the user gave, and rule names Hyprland didn't apply.
    live_names = {w["id"]: w["name"] for w in hypr("workspaces")}
    for ws in selected:
        if isinstance(ws["id"], str):
            continue  # its name is how it's found
        want = custom_name(ws) or rules.get(ws["id"], {}).get("name")
        if want and ws["id"] in live_names and live_names[ws["id"]] != want:
            dsp.rename_workspace(ws["id"], want)

    # Put back what each monitor was showing, focused monitor last, so a
    # restore in the middle of a session does not swap the visible workspaces.
    if dsp.changes and not args.wait_monitors:
        show_again(dsp, visible, focused)

    if not args.dry_run:
        mark_acting(args)  # its last windows' events may arrive after the lock is gone
        write_json(os.path.join(d, "last-restore.json"), report)
    print(json.dumps(report))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--state-dir")
    sub = p.add_subparsers(dest="cmd", required=True)
    sv = sub.add_parser("save")
    sv.add_argument("--ws", type=parse_key, help="re-record only this workspace")
    sv.set_defaults(fn=cmd_save)
    sub.add_parser("status").set_defaults(fn=cmd_status)
    t = sub.add_parser("set-tick")
    t.add_argument("value", choices=["0", "1"])
    t.add_argument("ws", type=parse_key, nargs="+")
    t.set_defaults(fn=cmd_set_tick)
    k = sub.add_parser("set-keyword")
    k.add_argument("key")
    k.add_argument("text")
    k.set_defaults(fn=cmd_set_keyword)
    cd = sub.add_parser("candidates")
    cd.add_argument("--ws", type=parse_key, help="mark what this workspace already has")
    cd.set_defaults(fn=cmd_candidates)
    a = sub.add_parser("add-window")
    a.add_argument("ws", type=parse_key)
    src = a.add_mutually_exclusive_group(required=True)
    src.add_argument("--address")
    src.add_argument("--desktop")
    a.set_defaults(fn=cmd_add_window)
    ao = sub.add_parser("add-open")
    ao.add_argument("ws", type=parse_key)
    ao.set_defaults(fn=cmd_add_open)
    rm = sub.add_parser("remove-window")
    rm.add_argument("ws", type=parse_key)
    rm.add_argument("index", type=int)
    rm.add_argument("cls")
    rm.set_defaults(fn=cmd_remove_window)
    sm = sub.add_parser("set-monitor")
    sm.add_argument("ws", type=parse_key)
    sm.set_defaults(fn=cmd_set_monitor)
    mv = sub.add_parser("move-window")
    mv.add_argument("ws", type=parse_key)
    mv.add_argument("from_ws", type=parse_key)
    mv.add_argument("index", type=int)
    mv.add_argument("cls")
    mv.set_defaults(fn=cmd_move_window)
    mw = sub.add_parser("move-workspace")
    mw.add_argument("ws", type=parse_key)
    mw.add_argument("desc")
    mw.set_defaults(fn=cmd_move_workspace)
    rn = sub.add_parser("renumber")
    rn.add_argument("pairs", nargs="*", metavar="OLD:NEW")
    rn.add_argument("--name", action="append", metavar="OLD=NAME", help="new name for workspace OLD")
    rn.add_argument("--dry-run", action="store_true", help="print dispatches, change nothing")
    rn.set_defaults(fn=cmd_renumber)
    si = sub.add_parser("set-identity")
    si.add_argument("ws", type=parse_key)
    si.add_argument("state", choices=["real", "borrowed"])
    si.set_defaults(fn=cmd_set_identity)
    rs = sub.add_parser("renumber-saved")
    rs.add_argument("ws", type=parse_key)
    rs.add_argument("new", type=int, nargs="?")
    rs.set_defaults(fn=cmd_renumber_saved)
    sub.add_parser("watch").set_defaults(fn=cmd_watch)
    rw = sub.add_parser("rename")
    rw.add_argument("ws", type=parse_key)
    rw.add_argument("name", nargs="?")
    rw.set_defaults(fn=cmd_rename)
    aa = sub.add_parser("set-auto-add")
    aa.add_argument("value", choices=["0", "1"])
    aa.add_argument("ws", type=parse_key, nargs="+")
    aa.set_defaults(fn=cmd_set_auto_add)
    sub.add_parser("auto-add").set_defaults(fn=cmd_auto_add)
    r = sub.add_parser("restore")
    r.add_argument("--all", action="store_true", help="every saved workspace")
    r.add_argument("--ticked", action="store_true", help="every ticked workspace")
    r.add_argument("--ws", type=parse_key, nargs="*", help="these workspaces")
    r.add_argument("--monitor", help="every workspace saved on this monitor description")
    r.add_argument("--wait-monitors", action="store_true", help="login mode: wait for monitors, keep focus as is")
    r.add_argument("--once", action="store_true", help="only the first call per Hyprland session runs")
    r.add_argument("--dry-run", action="store_true", help="print dispatches without sending them")
    r.set_defaults(fn=cmd_restore)
    args = p.parse_args()
    writers = {cmd_save, cmd_set_tick, cmd_set_keyword, cmd_add_window, cmd_add_open, cmd_remove_window,
               cmd_set_monitor, cmd_move_window, cmd_move_workspace, cmd_renumber, cmd_rename,
               cmd_renumber_saved,
               cmd_set_auto_add, cmd_auto_add}
    try:
        if args.fn in writers:
            # The bar's auto-add and the panel's edits read, change and write
            # the same files; one at a time so neither loses the other's change.
            d = state_dir(args)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "state.lock"), "w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                return args.fn(args) or 0
        return args.fn(args) or 0
    except (subprocess.CalledProcessError, ConnectionError, FileNotFoundError, KeyError) as e:
        # hyprctl or Hyprland's socket isn't there (Hyprland quit, or this
        # runs outside a Hyprland session).
        print(json.dumps({"ok": False, "error": f"Hyprland isn't reachable: {e}"}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
