"""Title-bar backgrounds that follow Noctalia's palette (Qt-free), per Umbriel config.

A Noctalia user template renders the chosen colors on every palette change: one block per config (`# config: <path>`)
with a line per followed field naming the palette role behind the chosen KDE source and the opacity as a hex byte.
Its `post_hook` runs `titlebar_apply.py`, which copies each block into its config. An include cannot do this:
Noctalia's built-in umbriel template always moves `noctalia.toml` to the end of `include.optional.files`, and only
the config itself is applied after it.
"""

import os
import re
import tomllib

from . import noctalia_theme
from .paths import DATA_DIR_NAME, atomic_write, xdg_config_home

TEMPLATE_KEY = "umbriel_titlebar"
OLD_INCLUDE = "titlebar.toml"  # earlier versions included the rendered file; Noctalia's include order defeated it
FIELDS = ("background", "background_unfocused")
# Which palette role each KDE button reads from Noctalia's kcolorscheme template.
ROLES = {
    "background": {"kde": "primary_container", "kde_header": "surface_container"},
    "background_unfocused": {"kde": "surface", "kde_header": "surface"},
}
CONFIG_LINE = re.compile(r"^# config: (.+)$")
LINE = re.compile(r'^(background(?:_unfocused)?) = "#\{\{colors\.(\w+)\.default\.hex_stripped\}\}([0-9A-F]{2})"'
                  r"\s*# source=(\w+)$")
ROLE = re.compile(r"\{\{colors\.(\w+)\.default\.hex_stripped\}\}")
# Earlier versions followed one config, named as the last argument of the post_hook.
OLD_HOOK = re.compile(r"^python3 '[^']*' '[^']*' '([^']*)'$")
# Text Noctalia's template engine would interpret, or that would end the `# config:` line.
UNSAFE_PATH = ("\n", "\r", "{{", "}}", "<*", "*>")


def template_file():
    return os.path.join(xdg_config_home(), "noctalia", "templates", "umbriel-titlebar.toml")


def output_file():
    return os.path.join(xdg_config_home(), DATA_DIR_NAME, "titlebar-colors.toml")


def script_file():
    return os.path.join(xdg_config_home(), DATA_DIR_NAME, "titlebar_apply.py")


SCRIPT_VERSION = re.compile(rb"^SCRIPT_VERSION = (\d+)$", re.M)


def _bundled_script():
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "titlebar_apply.py"), "rb") as source:
        return source.read()


def _script_version(data):
    match = SCRIPT_VERSION.search(data)
    return int(match.group(1)) if match else 0


def _install_script():
    """Copy the standard-library applier to a stable place (the app may run from a temporary AppImage mount)."""
    target = script_file()
    if os.path.islink(target):
        raise ValueError(f"{target} is a symlink; remove it first.")
    atomic_write(target, _bundled_script(), 0o644)
    return target


def refresh_script():
    """Replace an installed applier from an earlier version (a lower SCRIPT_VERSION), so fixes reach configs that
    already follow; a newer one stays. Call under the write lock (helper `save`)."""
    target = script_file()
    if not os.path.isfile(target) or os.path.islink(target):
        return
    try:
        bundled = _bundled_script()
        with open(target, "rb") as handle:
            if _script_version(handle.read()) >= _script_version(bundled):
                return
        atomic_write(target, bundled, 0o644)
    except OSError:
        pass  # the old copy keeps working; the next save tries again


def _noctalia_path(path):
    """Write paths under $XDG_CONFIG_HOME the way Noctalia's own entries do."""
    home = xdg_config_home().rstrip("/") + "/"
    return "$XDG_CONFIG_HOME/" + path[len(home):] if path.startswith(home) else path


def _old_hook_config():
    """The config an earlier single-config post_hook wrote to, if Noctalia's config still names one."""
    try:
        with open(noctalia_theme.noctalia_config_file(), "rb") as handle:
            entry = tomllib.load(handle)["theme"]["templates"]["user"][TEMPLATE_KEY]
    except (OSError, tomllib.TOMLDecodeError, KeyError, TypeError):
        return None
    match = OLD_HOOK.match(str(entry.get("post_hook", ""))) if isinstance(entry, dict) else None
    return match.group(1) if match else None


def read_all(path=None):
    """{config path: {field: {"source", "role", "alpha"}}} from the template; empty when there is none."""
    try:
        with open(path or template_file(), encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return {}
    result, current = {}, None
    for line in lines:
        config = CONFIG_LINE.match(line)
        if config:
            current = result.setdefault(config.group(1), {})
            continue
        item = LINE.match(line)
        if not item:
            continue
        if current is None:  # a template from before per-config following
            owner = _old_hook_config()
            if owner is None:
                continue
            current = result.setdefault(owner, {})
        field, role, alpha, source = item.groups()
        current[field] = {"role": role, "alpha": alpha, "source": source}
    return {config: fields for config, fields in result.items() if fields}


def read_follow(config, path=None):
    """{field: {"source", "role", "alpha"}} for one config."""
    return read_all(path).get(os.path.abspath(config), {})


def template_text(follow_all):
    lines = ["# Written by Umbriel Settings: title bar colors follow Noctalia's palette.",
             "# One block per Umbriel config; titlebar_apply.py copies each into [colors.title_bar] of that file."]
    for config in sorted(follow_all):
        lines.append(f"# config: {config}")
        for field in FIELDS:
            if field in follow_all[config]:
                item = follow_all[config][field]
                lines.append(f'{field} = "#{{{{colors.{item["role"]}.default.hex_stripped}}}}{item["alpha"]}"'
                             f'  # source={item["source"]}')
    return "\n".join(lines) + "\n"


def render(text, roles):
    """Fill the template from palette roles (#rrggbb); None when a role is missing."""
    missing = [name for name in ROLE.findall(text) if name not in roles]
    if missing:
        return None
    return ROLE.sub(lambda match: roles[match.group(1)][1:], text)


def status(config):
    """What the Colors page needs for `config` (reads only): followed fields with their current colors, the
    palette color behind each source (`sources[field][source]`, #RRGGBB, for following a field once saved), and
    whether Noctalia is there."""
    follow = read_follow(config)
    roles, source = noctalia_theme.load_roles()
    palette = source == "noctalia"
    fields, sources = {}, {}
    for field, item in follow.items():
        color = roles.get(item["role"]) if palette else None
        fields[field] = {**item, "color": (color.upper() + item["alpha"]) if color else None}
    for field, by_source in ROLES.items():
        sources[field] = {name: roles[role].upper() for name, role in by_source.items() if palette and role in roles}
    return {"noctalia": os.path.isfile(noctalia_theme.noctalia_config_file()), "fields": fields,
            "sources": sources, "old_include": OLD_INCLUDE, "palette": palette}


def _remove_files(*paths):
    for path in paths:
        if os.path.isfile(path) and not os.path.islink(path):
            os.remove(path)


def _remove_hook(backup_dir):
    """Drop the user template entry, the template, the rendered colors, the script and the script's backups of
    configs; remove `~/.config/umbriel-settings/` when nothing else is left in it."""
    noctalia_theme.remove_user_template(TEMPLATE_KEY, template_file(), backup_dir)
    folder = os.path.dirname(script_file())
    backups = [os.path.join(folder, name) for name in _list(folder) if name.endswith(".titlebar.bak")]
    _remove_files(output_file(), script_file(), *backups)
    if os.path.isdir(folder) and not os.path.islink(folder) and not _list(folder):
        os.rmdir(folder)


def _list(folder):
    try:
        return os.listdir(folder)
    except OSError:
        return []


def cleanup(backup_dir):
    """Stop following for every config and remove everything the hook installed (plugin disabled or
    uninstalled). The configs keep their last colors. Returns whether anything followed."""
    followed = bool(read_all()) or os.path.exists(template_file()) or os.path.exists(script_file())
    _remove_hook(backup_dir)
    return followed


def follow(config_path, field, source, alpha, backup_dir):
    """Make one title-bar field of `config_path` follow Noctalia (`source` "kde"/"kde_header", `alpha` 0-255), or
    stop (source None). Other configs keep following as they are."""
    if field not in FIELDS:
        raise ValueError(f"Unknown title bar field: {field}")
    config = os.path.abspath(config_path)
    everything = read_all()
    current = everything.setdefault(config, {})
    if source is None:
        current.pop(field, None)
    else:
        if source not in ROLES[field]:
            raise ValueError(f"Unknown color source: {source}")
        if not isinstance(alpha, int) or isinstance(alpha, bool) or not 0 <= alpha <= 255:
            raise ValueError("Opacity must be between 0 and 1.")
        if any(text in config for text in UNSAFE_PATH):
            raise ValueError("Title bars can't follow Noctalia for a config whose path contains {{, }}, <*, *> "
                             "or a line break.")
        current[field] = {"role": ROLES[field][source], "alpha": f"{alpha:02X}", "source": source}
    everything = {path: fields for path, fields in everything.items() if fields}
    if not everything:  # nothing follows any more: remove the hook; the configs keep their last colors
        _remove_hook(backup_dir)
        return status(config)
    text = template_text(everything)
    output, script = output_file(), script_file()
    # everything that can refuse is checked before anything is written
    for path in (output, script, noctalia_theme.noctalia_config_file(), template_file()):
        if os.path.islink(path):
            raise ValueError(f"{path} is a symlink; edit its target directly.")
    if not os.path.isfile(noctalia_theme.noctalia_config_file()):
        raise ValueError(f"Noctalia's config was not found: {noctalia_theme.noctalia_config_file()}")
    if any("'" in path for path in (output, script)):
        raise ValueError("Paths with ' cannot be used in Noctalia's post_hook.")
    entry = {"input_path": _noctalia_path(template_file()), "output_path": output,
             "post_hook": f"python3 '{script}' '{output}'"}
    noctalia_theme.write_user_template(TEMPLATE_KEY, template_file(), text, entry, backup_dir)
    _install_script()  # last: Noctalia only runs it once the entry is there
    roles, palette = noctalia_theme.load_roles()
    rendered = render(text, roles) if palette == "noctalia" else None
    if rendered is not None:  # the UI queues these colors for review; Noctalia refreshes the file later
        atomic_write(output, rendered, 0o644)
    return status(config)
