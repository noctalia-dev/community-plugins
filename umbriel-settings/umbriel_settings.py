"""Single helper behind the Umbriel Settings panel.

Usage: umbriel_settings.py COMMAND [--request FILE] [--response FILE]

Requests and responses are JSON files, because helper output and argv sizes are limited. On success
the response file is written and stdout is {"ok": true}; on a handled error stdout is
{"ok": false, "error": "...", "code": "..."} and the exit status is still 0. Without --response the
result is printed to stdout instead (useful for tests).
"""

import contextlib
import datetime
import fnmatch
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import traceback

PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, PLUGIN_DIR)

from umbriel_core import backups, legacy, paths, schema  # noqa: E402
from umbriel_core.launch import child_env  # noqa: E402

TOMLKIT_HINT = ("Python's tomlkit module is missing. Install it with your package manager "
                "(Arch: pacman -S python-tomlkit) or `pip install --user tomlkit`.")


class HelperError(Exception):
    def __init__(self, message, code="error"):
        super().__init__(message)
        self.code = code


def plugin_version():
    try:
        with open(os.path.join(PLUGIN_DIR, "plugin.toml"), encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("version"):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return ""


def need_tomlkit():
    try:
        import tomlkit  # noqa: F401
    except ImportError as error:
        raise HelperError(TOMLKIT_HINT, "missing_dependency") from error


def data_dir():
    return paths.default_gui_data_dir()


def saved_config_file():
    return os.path.join(data_dir(), "gui-config-path")


def config_path(request):
    """The config the request names, else the one the app or plugin last used, else the default."""
    requested = request.get("config")
    if isinstance(requested, str) and requested.strip():
        return paths.normalize_config_path(requested)
    return paths.load_saved_config_path(saved_config_file(), paths.DEFAULT_CONFIG_PATH)


def schema_state(coverage=False):
    """Return (options by path, info) from the installed Umbriel, or ({}, reason) when unavailable.

    With `coverage`, info also lists options without a setting (`missing`) and settings Umbriel lacks (`stale`).
    """
    try:
        document = schema.load_umbriel_schema()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        return {}, {"available": False, "reason": str(error)}
    info = {"available": True, "version": document.get("version"), "revision": document.get("revision")}
    if coverage:
        info["missing"], info["stale"] = schema.check_schema_coverage(document)
    return schema.schema_options_by_path(document), info


def session(request):
    need_tomlkit()
    from umbriel_core.session import ConfigSession
    return ConfigSession(config_path(request), data_dir(), lambda: schema_state()[0])


# ------------------------------------------------------------------ commands
def cmd_meta(request):
    """Write meta.json and search.json next to the response and return their paths."""
    from umbriel_core.meta import build_meta
    options, info = schema_state(coverage=True)
    meta = build_meta(options, info, plugin_version())
    search = []
    for fid, field in meta["fields"].items():
        search.append([fid, field.pop("search")])
    out_dir = request.get("out_dir")
    if not isinstance(out_dir, str) or not out_dir:
        return {"meta": meta, "search": search}
    os.makedirs(out_dir, exist_ok=True)
    result = {}
    for name, data in (("meta", meta), ("search", search)):
        path = os.path.join(out_dir, f"{name}.json")
        atomic_write_text(path, json.dumps(data, ensure_ascii=False, separators=(",", ":")))
        result[name] = path
    return result


def cmd_read(request):
    return session(request).read()


def cmd_preview(request):
    return session(request).preview(request.get("changes"), bool(request.get("validate", True)),
                                    bool(request.get("check")))


def trial_seconds(request):
    seconds = request.get("trial")
    if seconds is None:
        return None
    if not isinstance(seconds, int) or isinstance(seconds, bool) or not 1 <= seconds <= 120:
        raise HelperError("trial must be a number of seconds from 1 to 120.")
    return seconds


def cmd_save(request):
    """With `trial` (seconds, Try): a watcher restores the backup unless the trial is ended (`trial.py`); the
    report then has the trial's id as `trial`."""
    from umbriel_core import backups as backup_files
    from umbriel_core import titlebar_theme, trial
    current = session(request)
    seconds = trial_seconds(request)
    intents = follow_intents(request.get("changes"))
    titlebar_theme.refresh_script()  # under the write lock: an installed hook from an earlier version is replaced
    try:
        token = trial.arm(current.path, current.config_dir, data_dir(), seconds,
                          backup_files.MAX_BACKUPS) if seconds else None
    except trial.Busy as error:
        raise HelperError(str(error), "busy") from error
    try:
        report = current.save(request.get("changes"), bool(request.get("validate", True)), before_write=(
            lambda backup, revision: trial.confirm(current.config_dir, token, backup, revision)) if token else None)
    except BaseException:
        if token:
            with contextlib.suppress(OSError):  # keep the save's own error
                trial.claim(current.config_dir, token["id"])
        raise
    if token and not (report.get("saved") and report.get("backup")):
        trial.claim(current.config_dir, token["id"])  # nothing changed, so nothing to try
        token = None
    if not report.get("saved"):
        return report
    if token:
        report["trial"] = token["id"]
    # the config is written: from here on a failure is a warning, or the UI would offer to save it again
    warnings = report.setdefault("warnings", [])
    apply_follow_intents(current.path, intents, warnings)
    if request.get("remember_path"):
        try:
            paths.write_text_file(saved_config_file(), current.path, 0o600)
        except OSError as error:
            warnings.append(f"The config path could not be remembered: {error}.")
    report["state"] = read_after_write(current, warnings)
    if not warnings:
        del report["warnings"]
    return report


def read_after_write(current, warnings):
    """Re-read a config this command just wrote; None (plus a warning) when that fails."""
    try:
        return current.read()
    except (OSError, UnicodeError, ValueError, KeyError, TypeError) as error:
        warnings.append(f"The file was written but could not be read back: {error}")
        return None


def cmd_set_config(request):
    """Check that a config can be read, remember it for the app and the plugin, and return it."""
    current = session(request)
    state = current.read()
    paths.write_text_file(saved_config_file(), current.path, 0o600)
    return state


def backup_listing(path):
    config_dir = paths.config_gui_data_dir(path, data_dir())
    directory = backups.backup_dir(config_dir)
    items = []
    for snapshot in reversed(backups.list_backup_snapshots(directory, path)):
        try:
            stat = os.stat(snapshot)
        except OSError:
            continue
        items.append({
            "path": snapshot,
            "name": os.path.basename(snapshot),
            "time": datetime.datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
            "size": stat.st_size,
        })
    return {"path": path, "directory": directory, "backups": items}


def cmd_backups(request):
    return backup_listing(config_path(request))


def cmd_backup_diff(request):
    """Diff the current config against one snapshot (snapshot shown as the new side)."""
    import difflib
    path = config_path(request)
    snapshot = checked_snapshot(path, request.get("snapshot"))
    with open(path, encoding="utf-8") as current, open(snapshot, encoding="utf-8") as old:
        diff = "".join(difflib.unified_diff(
            current.read().splitlines(keepends=True), old.read().splitlines(keepends=True),
            fromfile="current", tofile=os.path.basename(snapshot), n=2,
        ))
    return {"diff": diff}


def checked_snapshot(path, snapshot):
    listing = backup_listing(path)
    if snapshot not in {item["path"] for item in listing["backups"]}:
        raise HelperError("That backup no longer exists.")
    return snapshot


def cmd_restore(request):
    need_tomlkit()
    import tomlkit

    from umbriel_core import trial
    current = session(request)
    trial_id = request.get("trial")  # Go back (or the panel's countdown) on a Try: only while it is pending
    if trial_id is not None:
        token = trial.read_token(trial.token_file(current.config_dir))
        if token is None or token["id"] != trial_id:  # checked first: the watcher's restore changed the revision
            raise HelperError(trial.describe(trial.outcome(current.config_dir, trial_id)), "trial_over")
    snapshot = checked_snapshot(current.path, request.get("snapshot"))
    if current.revision() != request.get("revision"):
        raise HelperError("The config changed since it was loaded. Reload before restoring.", "conflict")
    with open(snapshot, encoding="utf-8") as handle:
        text = handle.read()
    try:
        tomlkit.parse(text)
    except tomlkit.exceptions.TOMLKitError as error:
        raise HelperError(f"The backup is not valid TOML: {error}") from error
    if os.path.islink(current.path):
        raise HelperError("The config is a symlink; edit its target directly.")
    validation = current.validate(text) if request.get("validate", True) else {"ran": False}
    if current.revision() != request.get("revision"):  # again: validation takes a while
        raise HelperError("The config changed since it was loaded. Reload before restoring.", "conflict")
    backups.create_backup_snapshot(current.path, current.config_dir, protect=snapshot)
    paths.write_text_file(current.path, text)
    if trial_id is not None:  # only now: until the write the watcher still goes back; killed after it, a no-op
        with contextlib.suppress(OSError):
            trial.claim(current.config_dir, trial_id)
    warnings = []
    if validation.get("ran") and not validation.get("valid"):
        problems = [item["message"] for item in validation.get("diagnostics", []) if item.get("severity") == "error"]
        warnings.append("Umbriel reports problems in the restored config: " + "; ".join(problems[:3]))
    result = {"state": read_after_write(current, warnings), "backups": backup_listing(current.path)}
    if warnings:
        result["warnings"] = warnings
    return result


def cmd_trial_end(request):
    """Keep the settings of a Try: stop its watcher. `ended` is false (with `message`) when it already ended."""
    from umbriel_core import trial
    trial_id = request.get("trial")
    if not isinstance(trial_id, str) or not trial_id:
        raise HelperError("trial must name the Try to keep.")
    config_dir = paths.config_gui_data_dir(config_path(request), data_dir())
    if trial.claim(config_dir, trial_id) is not None:
        return {"ended": True}
    return {"ended": False, "message": trial.describe(trial.outcome(config_dir, trial_id))}


def cmd_delete_backups(request):
    from umbriel_core import trial
    path = config_path(request)
    listing = backup_listing(path)
    marked = request.get("snapshots")
    if not isinstance(marked, list):
        raise HelperError("Choose backups to delete.")
    marked, kept = trial.protect_pending(paths.config_gui_data_dir(path, data_dir()), marked)
    deleted, errors = backups.delete_backup_snapshots(listing["directory"], path, marked)
    errors += kept
    return {"deleted": deleted, "errors": errors, "backups": backup_listing(path)}


def cmd_desktop(request):
    from umbriel_core import mimeapps, xdg_dirs
    result = {"roles": mimeapps.ROLES}
    # each file on its own: an unreadable user-dirs.dirs must not hide the default apps, and the other way round
    try:
        result["userdirs"] = xdg_dirs.snapshot(*paths.read_document(xdg_dirs.config_path()))
    except (OSError, ValueError) as error:
        result["userdirs"] = {"values": {}, "revision": "unreadable", "error": str(error)}
    apps = mimeapps.installed_apps()
    try:
        result["apps"] = mimeapps.snapshot(*paths.read_document(mimeapps.config_path()), apps)
    except (OSError, ValueError) as error:
        result["apps"] = {**mimeapps.snapshot("", "unreadable", apps), "error": str(error)}
    listed = {app["id"] for app in apps}
    assigned = {value for part in ("roles", "mimes") for value in result["apps"][part].values()}
    result["apps"]["names"] = mimeapps.app_names(sorted(assigned - listed - {"", "<multiple>"}))
    return result


def cmd_desktop_save(request):
    """Save user folders and default apps; each part checks its own revision.

    The parts are saved independently: when one fails after the other was written, the reply still succeeds
    and names the failed part in `errors`, so the caller can take the written part's new revision.
    """
    from pathlib import Path

    from umbriel_core import mimeapps, xdg_dirs
    backup_dir = Path(data_dir()) / "backups"
    result = {}
    folders, apps = request.get("userdirs"), request.get("apps")
    if any(part is not None and not isinstance(part, dict) for part in (folders, apps)):
        raise HelperError("Desktop changes must be objects.")
    errors = {}
    parts = (("userdirs", folders, lambda: xdg_dirs.save(
                 xdg_dirs.config_path(), backup_dir, folders.get("revision"), folders.get("changes"))),
             ("apps", apps, lambda: mimeapps.save(
                 mimeapps.config_path(), backup_dir, apps.get("revision"), apps.get("changes"))))
    for name, part, save in parts:
        if not part:
            continue
        try:
            result[name] = save()
        except (ValueError, OSError, UnicodeError) as error:
            errors[name] = str(error)
    if errors and not result:
        raise HelperError(" ".join(errors.values()))
    if errors:
        result["errors"] = errors
    return result


def cmd_extension(request):
    from umbriel_core.mimeapps import extension_mime
    return {"mime": extension_mime(str(request.get("extension", "")))}


def ask_umbriel(command, read):
    """Run `read()` (which asks the running Umbriel), mapping its failures to readable helper errors."""
    try:
        return read()
    except FileNotFoundError as error:
        raise HelperError("The umbriel command was not found.", "missing_umbriel") from error
    except subprocess.TimeoutExpired as error:
        raise HelperError(f"`umbriel {command}` did not finish within {error.timeout:g} seconds. "
                          "Make sure Umbriel is running in this session.") from error
    except (RuntimeError, ValueError) as error:
        raise HelperError(str(error)) from error


def live_command(name, reader):
    """The `outputs`/`windows`/`layers` command: `umbriel <name> --json` read by `umbriel_core.live.<reader>`."""
    def command(request):
        from umbriel_core import live
        return {name: ask_umbriel(f"{name} --json", getattr(live, reader))}
    return command


cmd_outputs = live_command("outputs", "connected_outputs")
cmd_windows = live_command("windows", "open_windows")
cmd_layers = live_command("layers", "open_layers")


def cmd_focused_window(request):
    from umbriel_core import live
    return {"window": ask_umbriel("focused-window --json", live.focused_window)}


def cmd_wait_live(request):
    """Long poll: answers {event} once what one of `events` reports changes, or {event: null} after `timeout`
    seconds (at most 30)."""
    from umbriel_core import live
    events = request.get("events")
    if not isinstance(events, list) or not events or any(event not in live.WATCHABLE_EVENTS for event in events):
        raise HelperError("events must list some of: " + ", ".join(live.WATCHABLE_EVENTS) + ".")
    timeout = request.get("timeout", 25)
    timeout = min(max(timeout, 1), 30) if isinstance(timeout, (int, float)) else 25
    return {"event": ask_umbriel("subscribe", lambda: live.wait_change(events, timeout))}


def cmd_wait(request):
    """A timer for the UI (e.g. a countdown): answers after `seconds` (0 to 5)."""
    import time
    seconds = request.get("seconds", 1)
    time.sleep(min(max(seconds, 0), 5) if isinstance(seconds, (int, float)) else 1)
    return {}


def cmd_xkb(request):
    from umbriel_core import live, xkb
    catalog = xkb.catalog()
    if not catalog["layouts"]:
        raise HelperError(f"XKB's layout list {xkb.rules_file()} could not be read.", "missing_xkb")
    return {**catalog, "current": live.keyboard_layout()}


def cmd_run_action(request):
    """Send one keybind action to the running Umbriel (`umbriel msg`), unless it is one "Run now" refuses."""
    from umbriel_core.actions import msg_argv, run_block_reason
    action = str(request.get("action", "")).strip()
    reason = run_block_reason(action)
    if reason:
        raise HelperError(f"Not run: {reason}.", "blocked")
    try:
        argv = msg_argv(action)
    except ValueError as error:  # unbalanced quotes
        raise HelperError(f"Can't read the action: {error}.") from error
    result = ask_umbriel("msg", lambda: schema.run_umbriel(argv, 5))
    if result.returncode:
        detail = (result.stderr.strip() or result.stdout.strip()).splitlines()
        raise HelperError(detail[-1] if detail else f"umbriel msg failed (exit code {result.returncode}).")
    return {}


def cmd_kde_colors(request):
    from umbriel_core import kde
    try:
        scheme = kde.qt6ct_scheme_path()
        colors, backgrounds, _ = kde.read_title_bar_rgb(scheme)
    except (OSError, UnicodeError, ValueError) as error:
        return {"available": False, "reason": str(error)}  # reason: for debugging only

    def hex_map(found):
        return {".".join(path): "#{:02X}{:02X}{:02X}FF".format(*rgb) for path, rgb in found.items()}

    return {"available": True, "colors": hex_map(colors), "backgrounds": hex_map(backgrounds)}


def expand_home(path):
    return os.path.expanduser(str(path).replace("$HOME", os.path.expanduser("~"), 1))


def config_folder(request):
    config = str(request.get("config") or "")
    return os.path.dirname(os.path.abspath(os.path.expanduser(config))) if config else ""


def start_folder(request):
    """Where the file browser opens: `start` when it is a folder, else the config's folder, else home."""
    start = expand_home(request.get("start") or "")
    if os.path.isdir(start):
        return start
    folder = config_folder(request)
    return folder if os.path.isdir(folder) else os.path.expanduser("~")


def cmd_pick_folder(request):
    """The value for a folder chosen in the UI's file browser (`chosen`): home becomes `$HOME`."""
    chosen = str(request.get("chosen") or "")
    if not chosen:
        return {"cancelled": True}
    home = os.path.expanduser("~")
    if chosen == home or chosen.startswith(home + "/"):
        chosen = "$HOME" + chosen[len(home):]
    return {"path": chosen}


def file_patterns(request):
    pattern = request.get("filter")
    return pattern if isinstance(pattern, list) and len(pattern) == 2 else None


def cmd_pick_file(request):
    """The value for a file chosen in the UI's file browser (`chosen`): an absolute path, or relative to the
    config's folder (`relative`) when inside it; with `command`, an app's Exec command or the quoted program path."""
    chosen = str(request.get("chosen") or "")
    if not chosen:
        return {"cancelled": True}
    if request.get("command"):  # an autostart command: an app's Exec line, or the program itself
        if not chosen.endswith(".desktop"):
            return {"path": shlex.quote(chosen)}
        from umbriel_core import mimeapps
        command = mimeapps.exec_command(chosen)
        if not command:
            raise HelperError("That app has no command to run.", "no_command")
        return {"path": command}
    folder = config_folder(request)
    if request.get("relative") and folder:
        # compare real paths: the config folder is often a symlink into a dotfiles checkout
        real_folder, real_chosen = os.path.realpath(folder), os.path.realpath(chosen)
        if real_chosen.startswith(real_folder + os.sep):
            chosen = os.path.relpath(real_chosen, real_folder)
    return {"path": chosen}


LIST_DIR_LIMIT = 2000


def cmd_list_dir(request):
    """One folder for the UI's file browser (the plugin panel would hide a chooser window): `path`, else where
    it opens. Folders and files (matching `filter`; none with `folders`), hidden ones left out."""
    path = request.get("path")
    path = os.path.abspath(expand_home(path)) if path else start_folder(request)
    if not os.path.isdir(path):
        raise HelperError(f"{path} is not a folder.", "not_folder")
    pattern = file_patterns(request)
    patterns = pattern[1].lower().split() if pattern else None
    folders, files = [], []
    try:
        with os.scandir(path) as listing:
            for entry in listing:
                if entry.name.startswith("."):
                    continue
                try:
                    is_dir = entry.is_dir()
                except OSError:
                    continue
                if is_dir:
                    folders.append(entry.name)
                elif not request.get("folders") and (
                        not patterns or any(fnmatch.fnmatchcase(entry.name.lower(), p) for p in patterns)):
                    files.append(entry.name)
    except OSError as error:
        raise HelperError(f"Can't open {path}: {error.strerror or error}", "unreadable") from error
    folders.sort(key=str.casefold)
    files.sort(key=str.casefold)
    truncated = len(folders) + len(files) > LIST_DIR_LIMIT
    files = files[:max(0, LIST_DIR_LIMIT - len(folders))]
    parent = os.path.dirname(path)
    return {"path": path, "parent": parent if parent != path else None, "folders": folders[:LIST_DIR_LIMIT],
            "files": files, "truncated": truncated, "home": os.path.expanduser("~")}


def cmd_app_command(request):
    """The command that starts an installed app (its desktop file's Exec, without field codes)."""
    from umbriel_core import mimeapps
    app_id = str(request.get("id") or "")
    path = mimeapps.app_path(app_id)
    command = mimeapps.exec_command(path) if path else None
    if not command:
        raise HelperError(f"{app_id or 'That app'} has no command to run.", "no_command")
    return {"command": command}


def cmd_launch_app(request):
    """Start the standalone app through its per-user desktop entry, detached from this helper's output."""
    entry = os.path.join(paths.xdg_data_home(), "applications", paths.DESKTOP_ENTRY)
    if not os.path.isfile(entry):
        raise HelperError("Standalone desktop entry not found. Run Umbriel Settings once first.", "missing_app")
    gio = shutil.which("gio")
    if not gio:
        raise HelperError("Cannot launch the standalone app: gio is not installed.", "missing_gio")
    try:
        result = subprocess.run(
            [gio, "launch", entry], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True, timeout=10, check=False, env=child_env(),
        )
    except subprocess.TimeoutExpired as error:
        raise HelperError("Desktop launcher timed out; the app may still open.") from error
    if result.returncode:
        raise HelperError(f"Desktop launcher failed (exit code {result.returncode}).")
    return {}


def editor_file():
    return os.path.join(data_dir(), "editor-command")


def saved_editor():
    try:
        with open(editor_file(), encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def editor_argv(command):
    """Split an editor command (the file is appended); None for the default app."""
    try:
        argv = shlex.split(command)
    except ValueError as error:
        raise HelperError(f"Editor command: {error}.") from error
    if not argv:
        return None
    if not shutil.which(argv[0]):
        raise HelperError(f"Editor not found: {argv[0]}", "missing_editor")
    return argv


def cmd_open_config(request):
    path = config_path(request)
    argv = editor_argv(saved_editor())
    if argv is None:
        if not shutil.which("xdg-open"):
            raise HelperError("xdg-open was not found. Set an editor command under About.", "missing_editor")
        argv = ["xdg-open"]
    process = subprocess.Popen(argv + [path], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, start_new_session=True, env=child_env())
    # The app runs this in-process and keeps running: collect the exit status so no zombie stays behind.
    import threading
    threading.Thread(target=process.wait, daemon=True).start()
    return {}


def cmd_set_editor(request):
    """Remember the command "Edit file" uses; empty means the default app (xdg-open)."""
    command = request.get("editor")
    command = command.strip() if isinstance(command, str) else ""
    if any(char in command for char in "\r\n\0"):
        raise HelperError("The editor command must be a single line.")
    editor_argv(command)
    if command:
        atomic_write_text(editor_file(), command + "\n")
    elif os.path.exists(editor_file()):
        os.unlink(editor_file())
    return {"editor": command}


def cmd_about(request):
    from umbriel_core import noctalia_theme
    return {"editor": saved_editor(), "palette": noctalia_theme.template_status()}


def cmd_palette_template(request):
    """Set up the Noctalia user template that writes the palette the standalone app follows."""
    need_tomlkit()
    from umbriel_core import noctalia_theme
    return {"palette": noctalia_theme.install_template(os.path.join(data_dir(), "noctalia-backups"))}


def cmd_titlebar(request):
    from umbriel_core import titlebar_theme
    return titlebar_theme.status(config_path(request))


def noctalia_backups():
    return os.path.join(data_dir(), "noctalia-backups")


def follow_intents(changes):
    """[(field, source or None, alpha 0-255)] from title-bar field changes that carry `follow` ({source, alpha
    "XX"} starts following Noctalia, false stops); the panel queues them like any other edit."""
    from umbriel_core import titlebar_theme
    intents = []
    fields = changes.get("fields") if isinstance(changes, dict) else None
    for fid, change in (fields or {}).items():
        if not isinstance(change, dict) or "follow" not in change:
            continue
        field = fid.removeprefix("colors.title_bar.")
        follow = change["follow"]
        if field == fid or field not in titlebar_theme.FIELDS:
            raise HelperError(f"{fid} can't follow Noctalia.")
        if follow is False:
            intents.append((field, None, 0))
            continue
        alpha = follow.get("alpha") if isinstance(follow, dict) else None
        source = follow.get("source") if isinstance(follow, dict) else None
        if source not in titlebar_theme.ROLES[field] or not isinstance(alpha, str) \
                or not re.fullmatch(r"[0-9A-Fa-f]{2}", alpha):
            raise HelperError(f"{fid}: follow needs a source (kde, kde_header) and an alpha byte.")
        intents.append((field, source, int(alpha, 16)))
    return intents


def apply_follow_intents(config, intents, warnings):
    """After the config is written (under the write lock): start or stop following; failures are warnings."""
    from umbriel_core import titlebar_theme
    for field, source, alpha in intents:
        try:
            titlebar_theme.follow(config, field, source, alpha, noctalia_backups())
        except (OSError, ValueError) as error:
            verb = "follow" if source else "stop following"
            warnings.append(f"The title bar {field.replace('_', ' ')} could not {verb} Noctalia: {error}")


def cmd_titlebar_cleanup(request):
    """Stop following Noctalia for every config and remove the hook's files (the plugin was disabled or
    uninstalled); the configs keep their last colors."""
    need_tomlkit()
    from umbriel_core import titlebar_theme
    return {"followed": titlebar_theme.cleanup(noctalia_backups())}


COMMANDS = {
    "meta": cmd_meta, "read": cmd_read, "preview": cmd_preview, "save": cmd_save, "set-config": cmd_set_config,
    "backups": cmd_backups, "backup-diff": cmd_backup_diff, "restore": cmd_restore, "trial-end": cmd_trial_end,
    "delete-backups": cmd_delete_backups, "desktop": cmd_desktop, "desktop-save": cmd_desktop_save,
    "extension": cmd_extension, "outputs": cmd_outputs, "kde-colors": cmd_kde_colors,
    "pick-folder": cmd_pick_folder, "pick-file": cmd_pick_file, "list-dir": cmd_list_dir,
    "app-command": cmd_app_command, "launch-app": cmd_launch_app, "open-config": cmd_open_config,
    "set-editor": cmd_set_editor, "about": cmd_about, "palette-template": cmd_palette_template,
    "titlebar": cmd_titlebar, "titlebar-cleanup": cmd_titlebar_cleanup, "windows": cmd_windows,
    "layers": cmd_layers, "xkb": cmd_xkb, "run-action": cmd_run_action, "focused-window": cmd_focused_window,
    "wait-live": cmd_wait_live, "wait": cmd_wait,
}

# Commands that write the config, its sidecars, backups or desktop files; they run one at a time across the
# plugin, the app and other windows, so a revision check and the write that follows can't interleave.
WRITE_COMMANDS = {"save", "set-config", "restore", "trial-end", "delete-backups", "desktop-save", "set-editor",
                  "palette-template", "titlebar-cleanup"}


def atomic_write_text(path, text):
    """Responses, caches and the editor command are private to the user."""
    paths.atomic_write(path, text, 0o600)


def parse_args(argv):
    if not argv or argv[0] not in COMMANDS:
        raise HelperError("Usage: umbriel_settings.py {" + ",".join(COMMANDS) + "} [--request F] [--response F]")
    options = {"--request": None, "--response": None}
    rest = argv[1:]
    while rest:
        flag = rest.pop(0)
        if flag not in options or not rest:
            raise HelperError(f"Unknown or incomplete option: {flag}")
        options[flag] = rest.pop(0)
    return argv[0], options["--request"], options["--response"]


def run(argv):
    """Run one command and return what the panel reads from stdout (the standalone app calls this in-process)."""
    try:
        command, request_file, response = parse_args(argv)
        request = {}
        if request_file:
            with open(request_file, encoding="utf-8") as handle:
                request = json.load(handle)
            if request == []:  # an empty Lua table encodes as a JSON array
                request = {}
            if not isinstance(request, dict):
                raise HelperError("The request must be a JSON object.")
        if command in WRITE_COMMANDS:
            with paths.write_lock(data_dir()):
                legacy.migrate_data_dir(data_dir())  # before the first new snapshot
                result = COMMANDS[command](request)
        else:
            result = COMMANDS[command](request)
        if response:
            atomic_write_text(response, json.dumps(result, ensure_ascii=False, separators=(",", ":")))
            return json.dumps({"ok": True})
        return json.dumps({"ok": True, "result": result}, ensure_ascii=False)
    except HelperError as error:
        return json.dumps({"ok": False, "error": str(error), "code": error.code})
    except TimeoutError as error:  # the write lock (subprocess timeouts are handled by each command)
        return json.dumps({"ok": False, "error": str(error), "code": "busy"})
    except (OSError, UnicodeError, ValueError, KeyError, TypeError) as error:
        return json.dumps({"ok": False, "error": str(error) or type(error).__name__, "code": "error"})
    except Exception as error:  # a bug: still answer, so the panel and the app never wait forever
        traceback.print_exc(file=sys.stderr)
        return json.dumps({"ok": False, "error": f"Internal error ({type(error).__name__}: {error}). "
                                                 "Please report it with the details printed to stderr.",
                           "code": "internal"})


RUN_FILE = re.compile(r"^[a-z-]+-\d+-\d+\.(req|res)\.json$")
STALE_RUN_FILE = 600  # seconds: far past the longest helper timeout (60 s)


def sweep_run_files(request_file):
    """Remove request/response pairs that the panel never cleaned up: Noctalia drops the callbacks of helpers still
    running when it unloads the plugin (disable, reload), and only those callbacks remove the files."""
    if not request_file:
        return
    folder = os.path.dirname(os.path.abspath(request_file))
    cutoff = time.time() - STALE_RUN_FILE
    with contextlib.suppress(OSError):
        for entry in os.scandir(folder):
            with contextlib.suppress(OSError):
                if RUN_FILE.match(entry.name) and entry.is_file(follow_symlinks=False) \
                        and entry.stat(follow_symlinks=False).st_mtime < cutoff:
                    os.unlink(entry.path)


def main(argv):
    # Noctalia ends a helper that runs past its timeout with SIGTERM; exiting through SystemExit runs the
    # `finally` blocks that remove temporary files (the app calls run() in-process and keeps its handlers).
    import signal
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    print(run(argv))
    with contextlib.suppress(HelperError):
        sweep_run_files(parse_args(argv)[1])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
