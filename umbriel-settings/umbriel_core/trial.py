"""Rollback for a display "Try" that doesn't depend on the panel or the app staying open.

`arm` runs before the trial settings are written: it writes a token next to the config's backups and starts a
detached watcher (this file's source, run by the system's `python3 -I -c`, so it keeps working after an AppImage
that started it is gone). `confirm` records the backup and the SHA-256 the tried file will have, and starts the
countdown; it runs after the backup and before the config is replaced, so a failure there writes nothing.
At the deadline the watcher takes the shared write lock and, if the token is still there, puts the backup
back, unless the config changed since the try; what happened goes to `trial.result.json` and a notification.
Keep and Go back `claim` the token, so only one of them and the watcher acts. A save that fails or is
interrupted (SIGTERM) after `confirm` only `abandon`s it: once the tried file may be written, the watcher decides.
Everything at module level is standard library only.
"""

import datetime
import fcntl
import hashlib
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time

TOKEN_NAME = "trial.json"
RESULT_NAME = "trial.result.json"
GRACE = 15  # seconds after the panel's own countdown, which normally goes back first
CONFIRM_WINDOW = 60  # until `confirm`: the save may wait for the lock and validate first
LOCK_TIMEOUT = 60  # one wait for the write lock
GIVE_UP = 300  # seconds after the deadline: stop waiting for the lock
SPAWN_TIMEOUT = 5
STAMP = "%Y%m%d-%H%M%S-%f"  # backups.STAMP

RESTORED, CHANGED, BUSY = "restored", "changed", "busy"


class Busy(Exception):
    """Another Try of the same config is still waiting for an answer."""


def token_file(config_dir):
    return os.path.join(config_dir, TOKEN_NAME)


def result_file(config_dir):
    return os.path.join(config_dir, RESULT_NAME)


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) and isinstance(data.get("id"), str) else None


def read_token(path):
    return _read_json(path)


def _write(path, data, mode):
    handle, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=f".{os.path.basename(path)}.", suffix=".tmp")
    try:
        with os.fdopen(handle, "wb") as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _write_json(path, data):
    _write(path, json.dumps(data).encode("utf-8"), 0o600)


def _remove(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def host_python(env):
    """The system's python3, never one inside a running AppImage (its mount goes away when the app quits)."""
    appdir = env.get("APPDIR") or os.environ.get("APPDIR")
    entries = [entry for entry in (env.get("PATH") or "").split(os.pathsep) if entry]
    if appdir:
        root = os.path.realpath(appdir)
        entries = [entry for entry in entries if not os.path.realpath(entry).startswith(root + os.sep)]
    found = shutil.which("python3", path=os.pathsep.join(entries))
    if found:
        return found
    if appdir or os.environ.get("APPIMAGE"):
        raise OSError("Try needs python3 installed on the system for its automatic rollback.")
    return sys.executable


def arm(config, config_dir, lock_dir, seconds, keep=10):
    """Write the token and start the watcher (call under the write lock); raise Busy while another Try of this
    config waits, OSError (leaving no token) when the watcher can't start."""
    from .launch import child_env
    from .paths import private_dir
    private_dir(config_dir)
    path = token_file(config_dir)
    current = read_token(path)
    if current is not None and time.time() < float(current.get("deadline", 0)):
        raise Busy("Another Try of this config is still waiting for an answer.")
    token = {"id": secrets.token_hex(8), "config": config, "seconds": seconds, "keep": keep,
             "deadline": time.time() + seconds + GRACE + CONFIRM_WINDOW}
    _write_json(path, token)
    _remove(result_file(config_dir))
    try:
        env = child_env()
        python = host_python(env)
        with open(os.path.abspath(__file__), encoding="utf-8") as handle:
            source = handle.read()
        # The watcher forks and exits at once, so this returns quickly and leaves no zombie behind.
        subprocess.run([python, "-I", "-c", source, path, lock_dir], env=env, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=SPAWN_TIMEOUT, check=True)
    except BaseException as error:
        _remove(path)
        if isinstance(error, (OSError, subprocess.SubprocessError)):
            raise OSError(f"The automatic rollback could not be started ({error}), so nothing was tried.") from error
        raise
    return token


def confirm(config_dir, token, backup, revision):
    """Record what the watcher restores (the backup the save took, the SHA-256 of the tried file) and start the
    countdown; called right before the tried file is written (`Session.save(before_write=...)`)."""
    deadline = time.time() + float(token.get("seconds", 0)) + GRACE
    try:
        _write_json(token_file(config_dir), {**token, "backup": backup, "revision": revision, "deadline": deadline})
    except OSError as error:
        raise OSError(f"The automatic rollback could not be set up ({error}), so nothing was tried.") from error


def claim(config_dir, trial_id):
    """Remove the token if it is this trial's (call under the write lock); return it, else None."""
    path = token_file(config_dir)
    token = read_token(path)
    if token is None or token["id"] != trial_id:
        return None
    _remove(path)
    return token


def abandon(config_dir, trial_id):
    """After a failed or interrupted save (call under the write lock): end this trial only if the tried file is
    surely not in place; a config that may hold it keeps the token, and the watcher puts the backup back."""
    path = token_file(config_dir)
    token = read_token(path)
    if token is None or token["id"] != trial_id:
        return
    revision = token.get("revision")
    if isinstance(revision, str):
        try:
            with open(token["config"], "rb") as handle:
                if hashlib.sha256(handle.read()).hexdigest() == revision:
                    return
        except (OSError, KeyError, TypeError):
            return
    _remove(path)


def pending_backup(config_dir):
    """The snapshot a pending Try goes back to, or None. A token past its deadline plus GIVE_UP is left over from
    a watcher that died with the session (logout, reboot): it protects nothing any more."""
    token = read_token(token_file(config_dir))
    if token is None or time.time() >= float(token.get("deadline", 0)) + GIVE_UP:
        return None
    backup = token.get("backup")
    return backup if isinstance(backup, str) else None


def protect_pending(config_dir, marked):
    """Split Backups' marked snapshots into (deletable, errors): the pending Try's backup is kept."""
    protected = pending_backup(config_dir)
    protected = os.path.abspath(protected) if protected else None
    kept = [item for item in marked if isinstance(item, str) and os.path.abspath(item) == protected]
    return ([item for item in marked if item not in kept],
            [f"{os.path.basename(item)}: kept until the running Try ends (it is its rollback)" for item in kept])


def outcome(config_dir, trial_id):
    """What the watcher did with this trial ({"restored", "reason"}), or None when it didn't act."""
    result = _read_json(result_file(config_dir))
    return result if result is not None and result["id"] == trial_id else None


def describe(result):
    """A sentence for the panel about a trial that ended without it."""
    if result is None:
        return "This Try already ended."
    if result.get("restored"):
        return "The previous display settings were already restored."
    if result.get("reason") == CHANGED:
        return "The automatic rollback was skipped because the config changed during the Try."
    return f"The automatic rollback failed ({result.get('reason')}); restore the config from Backups."


def _prune(directory, config, keep, protect):
    prefix = os.path.basename(config) + "."
    try:
        names = sorted(name for name in os.listdir(directory) if name.startswith(prefix) and name.endswith(".bak"))
    except OSError:
        return
    paths = [os.path.join(directory, name) for name in names]
    paths = [path for path in paths if os.path.isfile(path) and not os.path.islink(path) and path != protect]
    for path in paths[:max(0, len(paths) - (keep - 1))]:
        _remove(path)


def _unwritten(tried, backup):
    """Whether the config still is the backup (the save was confirmed but stopped before writing)."""
    try:
        with open(backup, "rb") as handle:
            return handle.read() == tried
    except OSError:
        return False


def restore(token):
    """Put the backup back unless the config changed since the try; return (restored, reason)."""
    config, backup, revision = token.get("config"), token.get("backup"), token.get("revision")
    if not all(isinstance(value, str) for value in (config, backup, revision)):
        return False, "the Try was never confirmed"
    if os.path.islink(config):
        return False, "the config is a symlink"
    try:
        with open(config, "rb") as handle:
            tried = handle.read()
        if hashlib.sha256(tried).hexdigest() != revision:
            return (True, RESTORED) if _unwritten(tried, backup) else (False, CHANGED)
        with open(backup, "rb") as handle:
            previous = handle.read()
        mode = os.stat(config).st_mode & 0o7777
        # keep the tried version restorable from Backups, as a restore from the panel does
        directory = os.path.dirname(backup)
        snapshot = os.path.join(directory,
                                f"{os.path.basename(config)}.{datetime.datetime.now().strftime(STAMP)}.bak")
        _write(snapshot, tried, 0o600)
        _write(config, previous, mode)
        _prune(directory, config, int(token.get("keep", 10)), backup)
    except OSError as error:
        return False, str(error) or type(error).__name__
    return True, RESTORED


def _lock(lock_dir):
    os.makedirs(lock_dir, mode=0o700, exist_ok=True)
    handle = open(os.path.join(lock_dir, "write.lock"), "a+b")  # the caller closes it, which unlocks
    deadline = time.monotonic() + LOCK_TIMEOUT
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return handle
        except BlockingIOError:
            if time.monotonic() >= deadline:
                handle.close()
                return None
            time.sleep(0.1)


def expire(path, lock_dir, trial_id):
    """At the deadline: claim the token under the write lock, restore and record the result; return
    (restored, reason), None when another writer kept the lock, or False when the trial already ended."""
    handle = _lock(lock_dir)
    if handle is None:
        return None
    try:
        token = read_token(path)
        if token is None or token["id"] != trial_id:
            return False
        _remove(path)
        restored, reason = restore(token)
        _write_json(os.path.join(os.path.dirname(path), RESULT_NAME),
                    {"id": trial_id, "restored": restored, "reason": reason})
        return restored, reason
    finally:
        handle.close()


def _notify(text):
    try:
        subprocess.run(["notify-send", "--app-name=Umbriel Settings", "Umbriel Settings", text],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        pass


def _message(restored, reason):
    if restored:
        return "No answer to Try in time. The previous display settings are back."
    if reason == CHANGED:
        return "Try ran out of time, but the config changed meanwhile, so it was left as it is."
    return f"Try ran out of time, but the previous display settings could not be restored ({reason}). " \
           "Restore them from Backups."


def watch(path, lock_dir):
    token = read_token(path)
    if token is None:
        return 1
    if os.fork():
        return 0
    os.setsid()
    os.chdir("/")  # never keep a plugin folder or an AppImage mount busy
    while True:
        current = read_token(path)
        if current is None or current["id"] != token["id"]:
            return 0  # kept, gone back, or a newer try took over
        deadline = float(current.get("deadline", 0))
        if time.time() >= deadline:
            done = expire(path, lock_dir, token["id"])
            if done is None:
                if time.time() < deadline + GIVE_UP:
                    continue
                _remove(path)  # the panel's Go back still finds the backup in Backups
                _notify(_message(False, "another save kept the config busy"))
                return 0
            if done:
                _notify(_message(*done))
            return 0
        time.sleep(1)


if __name__ == "__main__":
    sys.exit(watch(*sys.argv[1:3]))
