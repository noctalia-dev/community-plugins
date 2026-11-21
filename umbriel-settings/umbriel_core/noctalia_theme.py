"""Follow the Noctalia shell's colors, font and corner radius in the standalone app (Qt-free).

Sources, first available wins:
1. A palette file written by a Noctalia user template (exact Material roles, see PALETTE_TEMPLATE).
2. The KDE color scheme Noctalia writes for qt6ct (roles mapped from its sections).
3. Nothing: the host falls back to the Qt palette.
"""

import math
import os
import re
import tomllib

from . import kde
from .backups import snapshot_file
from .paths import DATA_DIR_NAME, LEGACY_DIR_NAME, atomic_write, xdg_config_home

ROLES = (
    "primary", "on_primary", "primary_container", "on_primary_container", "secondary", "on_secondary",
    "secondary_container", "tertiary", "on_tertiary", "error", "on_error", "surface", "on_surface",
    "on_surface_variant", "surface_container_lowest", "surface_container_low", "surface_container",
    "surface_container_high", "surface_container_highest", "outline", "outline_variant", "hover", "on_hover",
)

# Noctalia template (TemplateEngine syntax) that writes every color role as name=#rrggbb.
PALETTE_TEMPLATE = """\
# Written by Noctalia for Umbriel Settings; regenerated on every theme change.
<* for name, value in colors *>
{{ name }}={{ value.default.hex }}
<* endfor *>
"""


ROLE_NAME = re.compile(r"[a-z][a-z0-9_]*")  # role names become CSS custom properties


def palette_file():
    """Where Noctalia writes the palette; templates set up before the rename still write to the old directory."""
    path = os.path.join(xdg_config_home(), DATA_DIR_NAME, "noctalia-palette.conf")
    legacy = os.path.join(xdg_config_home(), LEGACY_DIR_NAME, "noctalia-palette.conf")
    return legacy if not os.path.exists(path) and os.path.exists(legacy) else path


def template_file():
    return os.path.join(xdg_config_home(), "noctalia", "templates", "umbriel-settings-palette.conf")


def noctalia_config_file():
    return os.path.join(xdg_config_home(), "noctalia", "noctalia-config.toml")


def _hex(value):
    value = value.strip().strip('"')
    if value.startswith("#") and len(value) in (7, 9):
        try:
            int(value[1:], 16)
        except ValueError:
            return None
        return value[:7].lower()
    return None


def parse_palette(text):
    """Parse name=#rrggbb lines into {role: '#rrggbb'}."""
    roles = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, _, value = line.partition("=")
        name, color = name.strip(), _hex(value)
        if color and ROLE_NAME.fullmatch(name):
            roles[name] = color
    return roles


# KDE scheme (section, key) → role. Missing roles are derived later by fill_roles.
KDE_ROLES = {
    "surface": ("Colors:Window", "BackgroundNormal"),
    "on_surface": ("Colors:Window", "ForegroundNormal"),
    "on_surface_variant": ("Colors:Window", "ForegroundInactive"),
    "surface_container_low": ("Colors:View", "BackgroundNormal"),
    "surface_container": ("Colors:Button", "BackgroundNormal"),
    "surface_container_high": ("Colors:Header", "BackgroundNormal"),
    "primary": ("Colors:Selection", "BackgroundNormal"),
    "on_primary": ("Colors:Selection", "ForegroundNormal"),
    "secondary": ("Colors:View", "ForegroundLink"),
    "tertiary": ("Colors:View", "ForegroundPositive"),
    "error": ("Colors:View", "ForegroundNegative"),
}


def palette_from_kde_scheme(path):
    colors = kde.read_scheme(path)
    return {role: "#{:02x}{:02x}{:02x}".format(*colors[place]) for role, place in KDE_ROLES.items() if place in colors}


def qt6ct_scheme():
    """qt6ct's selected KDE scheme even while its custom palette is off (only the colors are used), or None."""
    try:
        return kde.qt6ct_scheme_path(None, require_custom=False)
    except ValueError:
        return None


def mix(a, b, amount):
    """Blend two #rrggbb colors; amount 0 keeps a, 1 gives b."""
    ca = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    cb = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x + (y - x) * amount):02x}" for x, y in zip(ca, cb, strict=True))


def fill_roles(roles):
    """Derive missing roles from the ones a source provided, like a Material palette would."""
    r = dict(roles)
    r.setdefault("surface", "#1d1b20")
    r.setdefault("on_surface", "#e6e0e9")
    r.setdefault("primary", "#d0bcff")
    surface, text, primary = r["surface"], r["on_surface"], r["primary"]
    r.setdefault("on_surface_variant", mix(text, surface, 0.3))
    r.setdefault("surface_container_lowest", mix(surface, "#000000", 0.25))
    r.setdefault("surface_container_low", mix(surface, text, 0.04))
    r.setdefault("surface_container", mix(surface, text, 0.08))
    r.setdefault("surface_container_high", mix(surface, text, 0.12))
    r.setdefault("surface_container_highest", mix(surface, text, 0.17))
    r.setdefault("on_primary", surface)
    r.setdefault("primary_container", mix(surface, primary, 0.3))
    r.setdefault("on_primary_container", text)
    r.setdefault("secondary", mix(primary, text, 0.3))
    r.setdefault("on_secondary", surface)
    r.setdefault("secondary_container", mix(surface, r["secondary"], 0.3))
    r.setdefault("tertiary", mix(primary, "#7fd1ae", 0.5))
    r.setdefault("on_tertiary", surface)
    r.setdefault("error", "#f2b8b5")
    r.setdefault("on_error", surface)
    r.setdefault("outline", mix(text, surface, 0.5))
    r.setdefault("outline_variant", mix(text, surface, 0.75))
    r.setdefault("hover", r["tertiary"])
    r.setdefault("on_hover", r["on_tertiary"])
    return r


def load_roles(fallback=None):
    """Return (roles, source) from the palette file, the qt6ct KDE scheme or `fallback` (a dict)."""
    try:
        with open(palette_file(), encoding="utf-8") as handle:
            roles = parse_palette(handle.read())
        if "primary" in roles and "surface" in roles:
            return fill_roles(roles), "noctalia"
    except (OSError, UnicodeError):
        pass
    scheme = qt6ct_scheme()
    if scheme:
        roles = palette_from_kde_scheme(scheme)
        if "surface" in roles:
            return fill_roles(roles), "qt6ct"
    return fill_roles(fallback or {}), "qt"


def noctalia_settings_file():
    """Noctalia's settings-window overrides, laid over the config dir (FileUtils::stateDir)."""
    state = os.environ.get("NOCTALIA_STATE_HOME") or os.environ.get("XDG_STATE_HOME") \
        or os.path.expanduser("~/.local/state")
    return os.path.join(state, "noctalia", "settings.toml")


def _shell_table(path):
    try:
        with open(path, "rb") as handle:
            shell = tomllib.load(handle).get("shell", {})
    except (OSError, tomllib.TOMLDecodeError):
        return {}
    return shell if isinstance(shell, dict) else {}


def shell_style():
    """Font family and corner radius scale from Noctalia's effective [shell] settings (defaults when absent):
    the config, then what its settings window saved (settings.toml wins, like in Noctalia)."""
    shell = {**_shell_table(noctalia_config_file()), **_shell_table(noctalia_settings_file())}
    family = shell.get("font_family") if isinstance(shell.get("font_family"), str) else None
    scale = shell.get("corner_radius_scale")
    # Noctalia clamps corner roundness to [0, 2] (Style::setCornerRadiusScale).
    valid = isinstance(scale, (int, float)) and not isinstance(scale, bool) and not math.isnan(scale)
    scale = min(max(float(scale), 0.0), 2.0) if valid else 1.0
    return {"font_family": family, "radius_scale": scale}


def _css_string(text):
    """Quote text as a CSS string; control characters are dropped."""
    text = "".join(char for char in text if char.isprintable())
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def css_variables(roles, style):
    """CSS custom properties for the web renderer: --<role>, --font, --radius-scale."""
    lines = [f"--{name}: {color};" for name, color in sorted(roles.items()) if ROLE_NAME.fullmatch(name)]
    family = style.get("font_family")
    fonts = (f"{_css_string(family)}, " if family else "") + "system-ui, sans-serif"
    lines.append(f"--font: {fonts};")
    lines.append(f"--radius-scale: {style.get('radius_scale', 1.0)};")
    return ":root {\n  " + "\n  ".join(lines) + "\n}\n"


TEMPLATE_KEY = "umbriel_settings"  # [theme.templates.user.<key>] in noctalia-config.toml
TEMPLATE_ENTRY = {
    "input_path": "$XDG_CONFIG_HOME/noctalia/templates/umbriel-settings-palette.conf",
    "output_path": f"$XDG_CONFIG_HOME/{DATA_DIR_NAME}/noctalia-palette.conf",
}


def template_status():
    """Whether Noctalia is set up to write the palette the app follows."""
    config = noctalia_config_file()
    entry = False
    try:
        with open(config, "rb") as handle:
            user = tomllib.load(handle).get("theme", {}).get("templates", {}).get("user", {})
        entry = isinstance(user, dict) and isinstance(user.get(TEMPLATE_KEY), dict)
    except (OSError, tomllib.TOMLDecodeError, AttributeError):
        pass
    return {
        "noctalia": os.path.isfile(config),
        "template": os.path.isfile(template_file()),
        "entry": entry,
        "palette": load_roles()[1] == "noctalia",
    }


def _write_config(config, updated, backup_dir):
    """Replace Noctalia's config with `updated` once it parses, keeping a backup of the old file."""
    tomllib.loads(updated)
    snapshot_file(config, backup_dir)
    atomic_write(config, updated)


def write_user_template(key, template, text, entry, backup_dir):
    """Write a Noctalia user template and make [theme.templates.user.<key>] point at it.

    Noctalia's config is changed only when the entry is missing or different; the old file is backed up first.
    """
    import tomlkit

    config = noctalia_config_file()
    for path in (config, template):
        if os.path.islink(path):
            raise ValueError(f"{path} is a symlink; edit its target directly.")
    if not os.path.isfile(config):
        raise ValueError(f"Noctalia's config was not found: {config}")
    with open(config, encoding="utf-8") as handle:
        original = handle.read()
    document = tomlkit.parse(original)
    node = document
    for part in ("theme", "templates", "user"):
        if part not in node:
            node[part] = tomlkit.table(is_super_table=True)
        node = node[part]
        if not isinstance(node, dict):
            raise ValueError(f"Noctalia's config: [{part}] is not a table.")
    atomic_write(template, text, 0o644)
    current = node.get(key)
    if not isinstance(current, dict) or any(current.get(name) != value for name, value in entry.items()):
        if isinstance(current, dict):
            current.update(entry)
        else:
            table = tomlkit.table()
            table.update(entry)
            node[key] = table
        _write_config(config, tomlkit.dumps(document), backup_dir)


def remove_user_template(key, template, backup_dir):
    """Drop [theme.templates.user.<key>] from Noctalia's config (backed up first) and delete the template file."""
    import tomlkit

    config = noctalia_config_file()
    if os.path.isfile(config) and not os.path.islink(config):
        with open(config, encoding="utf-8") as handle:
            original = handle.read()
        document = tomlkit.parse(original)
        user = document
        for part in ("theme", "templates", "user"):
            user = user.get(part) if isinstance(user, dict) else None
        if isinstance(user, dict) and key in user:
            del user[key]
            _write_config(config, tomlkit.dumps(document), backup_dir)
    if os.path.isfile(template) and not os.path.islink(template):
        os.remove(template)


def install_template(backup_dir):
    """Write the palette template and add its user-template entry to Noctalia's config (backed up first)."""
    write_user_template(TEMPLATE_KEY, template_file(), PALETTE_TEMPLATE, TEMPLATE_ENTRY, backup_dir)
    os.makedirs(os.path.join(xdg_config_home(), DATA_DIR_NAME), exist_ok=True)
    return template_status()
