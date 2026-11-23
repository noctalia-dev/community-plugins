"""What the running compositor reports (outputs, open windows, layer surfaces, keyboard layout), for pickers."""

import json
import os
import re
import select
import subprocess
import time

from .launch import child_env
from .schema import run_umbriel_json, umbriel_executable

# `umbriel subscribe` events a page can wait for.
WATCHABLE_EVENTS = ("outputs", "windows", "layers", "keyboard_layout")


def _objects(data, command):
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise ValueError(f"`umbriel {command}` returned an unexpected list.")
    return data


def connected_outputs(timeout=5):
    """`umbriel outputs --json` as it is (names, descriptions, modes), checked to be a list of named outputs."""
    outputs = _objects(run_umbriel_json(["outputs", "--json"], timeout), "outputs --json")
    if any(not isinstance(output.get("name"), str) for output in outputs):
        raise ValueError("`umbriel outputs --json` returned an output without a name.")
    return outputs


def open_windows(timeout=5):
    """[{app_id, title, count, pattern, title_pattern}] for the open windows, one per app id (the first window's
    title), sorted; the patterns match the app id / title exactly."""
    found = {}
    for window in _objects(run_umbriel_json(["windows", "--json"], timeout), "windows --json"):
        app_id = window.get("app_id")
        if not isinstance(app_id, str) or not app_id:
            continue
        title = window.get("title") if isinstance(window.get("title"), str) else ""
        entry = found.setdefault(app_id, {"app_id": app_id, "title": title, "count": 0})
        entry["count"] += 1
    for entry in found.values():
        entry["pattern"], entry["title_pattern"] = regex_literal(entry["app_id"]), regex_literal(entry["title"])
    return sorted(found.values(), key=lambda item: item["app_id"].casefold())


def open_layers(timeout=5):
    """[{namespace, layer, outputs, pattern}] for the mapped layer surfaces, one per namespace, sorted."""
    found = {}
    for surface in _objects(run_umbriel_json(["layers", "--json"], timeout), "layers --json"):
        namespace = surface.get("namespace")
        if not isinstance(namespace, str) or not namespace:
            continue
        layer = surface.get("layer") if isinstance(surface.get("layer"), str) else ""
        entry = found.setdefault(namespace, {"namespace": namespace, "layer": layer, "outputs": []})
        output = surface.get("output")
        if isinstance(output, str) and output and output not in entry["outputs"]:
            entry["outputs"].append(output)
    for entry in found.values():
        entry["pattern"] = regex_literal(entry["namespace"])
    return sorted(found.values(), key=lambda item: item["namespace"].casefold())


def focused_window(timeout=5):
    """{app_id, title, pattern, title_pattern} of the focused window, or None when nothing has the focus."""
    window = run_umbriel_json(["focused-window", "--json"], timeout)
    if not isinstance(window, dict) or not isinstance(window.get("app_id"), str) or not window["app_id"]:
        return None
    title = window.get("title") if isinstance(window.get("title"), str) else ""
    return {"app_id": window["app_id"], "title": title, "pattern": regex_literal(window["app_id"]),
            "title_pattern": regex_literal(title)}


def _digest(event, data):
    """What a page shows of an event's data: window titles and focus change all the time, so windows count
    by app id (the picker lists app ids), layers by namespace, layer and output."""
    items = data if isinstance(data, list) else []
    if event == "windows":
        return sorted(str(item.get("app_id")) for item in items if isinstance(item, dict))
    if event == "layers":
        return sorted(f"{item.get('namespace')}|{item.get('layer')}|{item.get('output')}"
                      for item in items if isinstance(item, dict))
    return json.dumps(data, sort_keys=True)


def wait_change(events, timeout):
    """Wait until what one of `events` (WATCHABLE_EVENTS) reports changes, through `umbriel subscribe`: the
    event's name, or None after `timeout` seconds. Umbriel first sends each event's current state; that is
    the baseline. Raises FileNotFoundError (no umbriel) or RuntimeError (the stream ended early)."""
    process = subprocess.Popen([umbriel_executable(), "subscribe", ",".join(events)], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=child_env())
    deadline = time.monotonic() + timeout
    baseline, pending = {}, b""
    try:
        fd = process.stdout.fileno()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
                return None
            chunk = os.read(fd, 65536)
            if not chunk:
                raise RuntimeError("`umbriel subscribe` stopped. Make sure Umbriel is running in this session.")
            *lines, pending = (pending + chunk).split(b"\n")
            for line in lines:
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                event = message.get("event") if isinstance(message, dict) else None
                if event not in events:
                    continue
                digest = _digest(event, message.get("data"))
                if event not in baseline:
                    baseline[event] = digest
                elif digest != baseline[event]:
                    return event
    finally:
        process.kill()
        process.wait()


def keyboard_layout(timeout=5):
    """The active keyboard layout's name, or None when Umbriel can't tell."""
    try:
        data = run_umbriel_json(["keyboard-layouts", "--json"], timeout)
        names, index = data["names"], data["current_index"]
        if type(index) is not int or not 0 <= index < len(names):  # e.g. -1 for "unknown"
            return None
        return names[index] if isinstance(names[index], str) else None
    except Exception:  # best effort: a hint only
        return None


def regex_literal(text):
    """A rule pattern that matches exactly `text` (escapes only the metacharacters every regex dialect
    shares, so `org.gajim.Gajim` → `^org\\.gajim\\.Gajim$` and a `-` stays as it is)."""
    return "^" + re.sub(r"([\\.^$|?*+()\[\]{}])", r"\\\1", text) + "$"
