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
"""

import argparse
import configparser
import fcntl
import json
import os
import re
import shlex
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


def state_dir(args):
    if args.state_dir:
        return os.path.expanduser(args.state_dir)
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "workspace-restore")


def read_json(path, default):
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, type(default)) else default
    except (OSError, ValueError):
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path)


def hypr(what):
    out = subprocess.run(["hyprctl", what, "-j"], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


class Dispatcher:
    def __init__(self, dry_run):
        self.dry_run = dry_run
        self.changes = 0

    def __call__(self, expr):
        if self.dry_run:
            print("dispatch:", expr)
            return
        subprocess.run(["hyprctl", "dispatch", expr], capture_output=True)

    # Only these call shapes are verified on Hyprland 0.56. Unknown keys are
    # ignored and the action falls back to the focused workspace, so every
    # target here is named explicitly.
    def move_window(self, address, ws):
        self.changes += 1
        self(f"hl.dsp.window.move({{ workspace = {int(ws)}, follow = false, window = {lua_str('address:' + address)} }})")

    def move_workspace(self, ws, monitor):
        self.changes += 1
        self(f"hl.dsp.workspace.move({{ workspace = {int(ws)}, monitor = {lua_str(monitor)} }})")

    def focus_workspace(self, ws):
        self(f"hl.dsp.focus({{ workspace = {int(ws)} }})")

    def exec(self, cmd, ws=None):
        # Launched by Hyprland, not by us, so apps get the session's own
        # environment instead of whatever started this script. The workspace
        # goes in as an exec rule: it beats window rules that send the app to
        # another monitor, and a window that opens late lands right without a move.
        self.changes += 1
        rules = "no_initial_focus = true" + (f", workspace = \"{int(ws)} silent\"" if ws is not None else "")
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


def layout_path(args):
    return os.path.join(state_dir(args), "layout.json")


def cmd_save(args):
    monitors = {m["name"]: m for m in hypr("monitors")}
    clients = hypr("clients")
    live = {ws["id"]: ws for ws in hypr("workspaces") if ws["id"] > 0}  # skip special workspaces
    if args.ws is None:
        workspaces = [workspace_entry(live[i], monitors, clients) for i in sorted(live)]
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
        workspaces = sorted([w for w in workspaces if w["id"] != args.ws] + [entry], key=lambda w: w["id"])
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
        live = [ws for ws in hypr("workspaces") if ws["id"] > 0]
        clients = hypr("clients")
    except (OSError, subprocess.CalledProcessError, ValueError):
        monitors, live, clients = [], [], []
    by_name = {m["name"]: m for m in monitors}
    for ws in live:
        if ws["id"] not in saved:
            workspaces.append(dict(workspace_entry(ws, by_name, []), unsaved=True))
    # A saved workspace whose apps were all removed only shows while it is
    # open, like any other open workspace.
    live_ids = {ws["id"] for ws in live}
    workspaces[:] = sorted((w for w in workspaces if w["windows"] or w["id"] in live_ids), key=lambda w: w["id"])

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
    for ws in workspaces:
        ws["ticked"] = bool(ticked.get(str(ws["id"])))
        ws["auto_add"] = ws["id"] in auto
        ws["unsaved_open"] = []
        for c in unsaved_open(ws["windows"], clients, ws["id"]):
            entry = window_entry(c)
            if entry:
                label, icon = display(entry)
                ws["unsaved_open"].append({"address": c["address"], "label": label, "icon": icon,
                                           "title": c["title"]})
        for i, w in enumerate(ws["windows"]):
            w["label"], w["icon"] = display(w)
            w["open"] = w["command"] in open_commands if w.get("match_command") \
                else w["class"].lower() in open_classes
            key = keys.get((ws["id"], i))
            if key:
                w["keyword_key"] = key
                w["keyword"] = keywords.get(key, "")
                ids = where.get(w["class"].lower(), [])
                w["twice_here"] = ids.count(ws["id"]) > 1
                w["also_on"] = sorted({i for i in ids if i != ws["id"]})
        ws["in_place"] = in_place(ws, keys, keywords, clients, live_monitor)
    layout["restoring"] = restore_running(d)
    layout["last_restore"] = read_json(os.path.join(d, "last-restore.json"), {})
    print(json.dumps(layout))


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
    for c in sorted(clients, key=lambda c: (c["workspace"]["id"] != args.ws, c["workspace"]["id"], c["at"][0])):
        if not c["class"] or c["workspace"]["id"] <= 0:
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
            workspaces.sort(key=lambda w: w["id"])
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


def auto_add_ids(config):
    auto = config.get("auto_add")
    return {int(k) for k, v in auto.items() if v} if isinstance(auto, dict) else set()


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
    added = []
    for c in sorted(hypr("clients"), key=lambda c: (c["at"][0], c["at"][1])):
        if c["workspace"]["id"] not in auto or not c["class"] or c.get("floating"):
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


def cmd_restore(args):
    if args.once and not args.dry_run and not first_in_session():
        print(json.dumps({"ok": True, "note": "already ran this session"}))
        return 0
    d = state_dir(args)
    os.makedirs(d, exist_ok=True)
    lock = open(os.path.join(d, "restore.lock"), "w")
    # status probes this lock for a moment on every bar poll, and at login
    # that poll can land right as this starts, so retry briefly. A real
    # restore holds it far longer.
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
    if not selected:
        print(json.dumps({"ok": True, "note": "nothing selected"}))
        return 0

    # At login monitors can show up a moment after Hyprland starts.
    wanted = {ws["monitor_desc"] for ws in selected}
    deadline = time.time() + (20 if args.wait_monitors else 0)
    while True:
        monitors = hypr("monitors")
        desc_to_name = {m["description"]: m["name"] for m in monitors}
        if wanted <= desc_to_name.keys() or time.time() >= deadline:
            break
        time.sleep(POLL_INTERVAL)

    dsp = Dispatcher(args.dry_run)
    focused = next((m["name"] for m in monitors if m.get("focused")), None)
    visible = {m["name"]: m["activeWorkspace"]["id"] for m in monitors}

    report = {"time": int(time.time()), "workspaces": [], "skipped": [], "launched": [], "moved": 0, "unmatched": []}
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

    def place_workspaces():
        current = {w["id"]: w["monitor"] for w in hypr("workspaces")}
        for ws_id, mon in ws_monitor.items():
            # Only existing workspaces are moved; a missing one is created on
            # its monitor once a window lands in it and placed next round.
            if ws_id in current and current[ws_id] != mon:
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

    # Put back what each monitor was showing, focused monitor last, so a
    # restore in the middle of a session does not swap the visible workspaces.
    if dsp.changes and not args.wait_monitors:
        for name, ws_id in visible.items():
            if name != focused:
                dsp.focus_workspace(ws_id)
        if focused in visible:
            dsp.focus_workspace(visible[focused])

    if not args.dry_run:
        write_json(os.path.join(d, "last-restore.json"), report)
    print(json.dumps(report))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--state-dir")
    sub = p.add_subparsers(dest="cmd", required=True)
    sv = sub.add_parser("save")
    sv.add_argument("--ws", type=int, help="re-record only this workspace")
    sv.set_defaults(fn=cmd_save)
    sub.add_parser("status").set_defaults(fn=cmd_status)
    t = sub.add_parser("set-tick")
    t.add_argument("value", choices=["0", "1"])
    t.add_argument("ws", type=int, nargs="+")
    t.set_defaults(fn=cmd_set_tick)
    k = sub.add_parser("set-keyword")
    k.add_argument("key")
    k.add_argument("text")
    k.set_defaults(fn=cmd_set_keyword)
    cd = sub.add_parser("candidates")
    cd.add_argument("--ws", type=int, help="mark what this workspace already has")
    cd.set_defaults(fn=cmd_candidates)
    a = sub.add_parser("add-window")
    a.add_argument("ws", type=int)
    src = a.add_mutually_exclusive_group(required=True)
    src.add_argument("--address")
    src.add_argument("--desktop")
    a.set_defaults(fn=cmd_add_window)
    ao = sub.add_parser("add-open")
    ao.add_argument("ws", type=int)
    ao.set_defaults(fn=cmd_add_open)
    rm = sub.add_parser("remove-window")
    rm.add_argument("ws", type=int)
    rm.add_argument("index", type=int)
    rm.add_argument("cls")
    rm.set_defaults(fn=cmd_remove_window)
    aa = sub.add_parser("set-auto-add")
    aa.add_argument("value", choices=["0", "1"])
    aa.add_argument("ws", type=int, nargs="+")
    aa.set_defaults(fn=cmd_set_auto_add)
    sub.add_parser("auto-add").set_defaults(fn=cmd_auto_add)
    r = sub.add_parser("restore")
    r.add_argument("--all", action="store_true", help="every saved workspace")
    r.add_argument("--ticked", action="store_true", help="every ticked workspace")
    r.add_argument("--ws", type=int, nargs="*", help="these workspaces")
    r.add_argument("--monitor", help="every workspace saved on this monitor description")
    r.add_argument("--wait-monitors", action="store_true", help="login mode: wait for monitors, keep focus as is")
    r.add_argument("--once", action="store_true", help="only the first call per Hyprland session runs")
    r.add_argument("--dry-run", action="store_true", help="print dispatches without sending them")
    r.set_defaults(fn=cmd_restore)
    args = p.parse_args()
    writers = {cmd_save, cmd_set_tick, cmd_set_keyword, cmd_add_window, cmd_add_open, cmd_remove_window,
               cmd_set_auto_add, cmd_auto_add}
    if args.fn in writers:
        # The bar's auto-add and the panel's edits read, change and write the
        # same files; one at a time so neither loses the other's change.
        d = state_dir(args)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "state.lock"), "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            return args.fn(args) or 0
    return args.fn(args) or 0


if __name__ == "__main__":
    sys.exit(main())
