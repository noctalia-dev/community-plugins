"""GUI data locations, atomic file writes and config snapshots shared by the app and the plugin."""

import contextlib
import fcntl
import hashlib
import json
import os
import stat
import tempfile
import time

DEFAULT_CONFIG_PATH = os.path.expanduser("~/.config/umbriel/config.toml")
DATA_DIR_NAME = "umbriel-settings"
LEGACY_DIR_NAME = "umbriel-config-gui"  # data, config and desktop-entry name before the rename to Umbriel Settings
DESKTOP_ENTRY = "umbriel-settings.desktop"  # per-user entry the app installs and the plugin launches
LABELS_FILE_NAME = "gui-labels.json"  # sidecars in each config's GUI data directory
LOCK_FILE_NAME = "gui-locked-keybinds.json"


def xdg_config_home():
    return os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")


def xdg_data_home():
    return os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")


def xdg_data_dirs():
    return [d for d in (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":") if d]


def tighten_dir(path):
    """Make an existing directory of ours owner-only (0700); symlinks and other users' directories stay as they are."""
    try:
        info = os.lstat(path)
        if stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o077:
            os.chmod(path, 0o700)
    except OSError:
        pass


def private_dir(path):
    """Create `path` (0700) or tighten it; for directories that hold copies of the user's files."""
    os.makedirs(path, mode=0o700, exist_ok=True)
    tighten_dir(path)
    return path


def default_gui_data_dir():
    """Return `$XDG_DATA_HOME/umbriel-settings`, the data directory shared by the app and the plugin (kept 0700:
    it holds config backups).

    The pre-rename `umbriel-config-gui` directory (backups, labels, locks, last config) is moved there once;
    if that move fails the old directory keeps being used so nothing appears lost.
    """
    base = xdg_data_home()
    path = os.path.join(base, DATA_DIR_NAME)
    legacy = os.path.join(base, LEGACY_DIR_NAME)
    if not os.path.lexists(path) and os.path.isdir(legacy) and not os.path.islink(legacy):
        try:
            os.rename(legacy, path)
        except OSError:
            if not os.path.isdir(path):  # another process may have moved it meanwhile
                path = legacy
    tighten_dir(path)
    return path


def normalize_config_path(path, default=DEFAULT_CONFIG_PATH):
    """Normalize a config path and return an absolute version suitable for the GUI."""
    if not path:
        return default
    return os.path.abspath(os.path.expanduser(path.strip()))


def config_gui_data_dir(config_path, data_dir):
    """Return a private GUI-data directory associated with one config path."""
    identity = hashlib.sha256(
        os.path.abspath(config_path).encode("utf-8")
    ).hexdigest()[:20]
    return os.path.join(data_dir, "configs", identity)


def load_saved_config_path(saved_file, default_path):
    """Return the config path stored in `saved_file`, or `default_path` when there is none."""
    if not os.path.exists(saved_file):
        return default_path
    try:
        with open(saved_file, encoding="utf-8") as f:
            saved = f.read().strip()
        if saved:
            return normalize_config_path(saved)
    except (OSError, UnicodeError):
        pass
    return default_path


def atomic_write(path, data, mode=None):
    """Replace `path` with `data` (str or bytes) so readers and file watchers never see a partial file.

    The data goes to a unique temporary file in the same directory and reaches the disk before it replaces the
    old file. `mode` defaults to the replaced file's permissions, else 0o644. A symlink at `path` is replaced
    itself; callers that must refuse symlinks check first.
    """
    path = os.fspath(path)
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, mode=0o700, exist_ok=True)  # only directories it creates
    if isinstance(data, str):
        data = data.encode("utf-8")
    if mode is None:
        try:
            mode = stat.S_IMODE(os.stat(path).st_mode)
        except OSError:
            mode = 0o644
    handle, tmp = tempfile.mkstemp(dir=directory, prefix=f".{os.path.basename(path)}.", suffix=".tmp")
    try:
        with os.fdopen(handle, "wb") as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


@contextlib.contextmanager
def write_lock(directory, timeout=20.0):
    """Hold `<directory>/write.lock` so one writer at a time edits the config, its sidecars and desktop files.

    The plugin's helper processes and the app's worker threads all take it (flock also excludes other open
    files in the same process). Raises TimeoutError when another writer keeps it longer than `timeout` seconds;
    20 s + schema (5 s) + validation (30 s) stays under the plugin's 60 s write timeout.
    """
    os.makedirs(directory, mode=0o700, exist_ok=True)
    handle = open(os.path.join(directory, "write.lock"), "a+b")  # closed in finally
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("Another Umbriel Settings window is still saving. Try again in a moment.") \
                        from None
                time.sleep(0.05)
        yield
    finally:
        handle.close()  # also releases the lock


def remove_stale_temp_files(directory, target_name, max_age=600.0):
    """Remove temporary files a killed writer left in `directory`: `atomic_write` copies of `target_name`
    and validation copies, once they are older than `max_age` seconds."""
    prefixes = (f".{target_name}.", ".umbriel-settings-")
    try:
        names = os.listdir(directory)
    except OSError:
        return
    cutoff = time.time() - max_age
    for name in names:
        if not name.startswith(prefixes) or not name.endswith((".tmp", ".toml")):
            continue
        full = os.path.join(directory, name)
        try:
            if os.path.isfile(full) and not os.path.islink(full) and os.path.getmtime(full) < cutoff:
                os.unlink(full)
        except OSError:
            pass


def decode_utf8(data, path):
    """`data` (bytes read from `path`) as text; ValueError naming the file and byte when it is not UTF-8."""
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"{path} is not UTF-8 text ({error.reason} at byte {error.start}).") from None


def read_document(path):
    """(text, SHA-256 revision) of a UTF-8 file, or ("", "missing") when it does not exist."""
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except FileNotFoundError:
        return "", "missing"
    return decode_utf8(data, path), hashlib.sha256(data).hexdigest()


def file_revision(path):
    """SHA-256 of a file's bytes, or 'missing'."""
    try:
        with open(path, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()
    except FileNotFoundError:
        return "missing"


def write_text_file(path, text, mode=None):
    """Write text atomically; a symlinked GUI file is written through to its target. `mode` as in atomic_write
    (0o600 for the GUI's own sidecars)."""
    atomic_write(os.path.realpath(path), text, mode)


def labels_file(config_dir):
    """Return the GUI-only entry label sidecar inside a per-config GUI data directory."""
    return os.path.join(config_dir, LABELS_FILE_NAME)


def load_all_entry_labels(config_dir):
    """Return every stored entry label keyed by entry path: a list for rules (by position), a name → label
    object for named entries such as outputs, e.g. {"window_rule": ["Foo", ""], "output": {"DP-1": "Desk"}}."""
    try:
        with open(labels_file(config_dir), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    found = {}
    for key, labels in data.items():
        if isinstance(labels, list):
            found[key] = [label if isinstance(label, str) else "" for label in labels]
        elif isinstance(labels, dict):
            found[key] = {name: label for name, label in labels.items() if isinstance(label, str) and label}
    return found
