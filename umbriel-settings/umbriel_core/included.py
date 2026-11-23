"""Names defined in a config's include files (effect presets and pools, named curves), for choices."""

import os
import tomllib

KINDS = {
    "effect_preset": ("effects", "preset"),
    "effect_pool": ("effects", "pool"),
    "beziers": ("animation", "beziers"),
    "springs": ("animation", "springs"),
}
MAX_FILES = 50
MAX_BYTES = 1 << 20


def _table(data, path):
    for part in path:
        data = data.get(part) if isinstance(data, dict) else None
    return data if isinstance(data, dict) else {}


def _include_lists(data):
    include = _table(data, ("include",))
    lists = [include.get("files"), _table(include, ("optional",)).get("files")]
    return [item for files in lists if isinstance(files, list) for item in files if isinstance(item, str)]


def included_names(data, config_dir):
    """{kind: [names]} from the files `data` (a parsed config) includes, and the files they include in turn.
    Unreadable or missing files are skipped: this only feeds suggestions."""
    names = {kind: [] for kind in KINDS}
    pending = [(path, config_dir) for path in _include_lists(data)]
    seen = set()
    while pending and len(seen) < MAX_FILES:
        path, base = pending.pop(0)
        path = os.path.expandvars(os.path.expanduser(path))
        path = os.path.normpath(path if os.path.isabs(path) else os.path.join(base, path))
        if path in seen:
            continue
        seen.add(path)
        try:
            # a FIFO or device would block the read: only regular files
            if not os.path.isfile(path) or os.path.getsize(path) > MAX_BYTES:
                continue
            with open(path, "rb") as handle:
                included = tomllib.load(handle)
        except (OSError, tomllib.TOMLDecodeError, UnicodeDecodeError):
            continue
        for kind, table_path in KINDS.items():
            for name in _table(included, table_path):
                if name not in names[kind]:
                    names[kind].append(name)
        pending += [(child, os.path.dirname(path)) for child in _include_lists(included)]
    return names
