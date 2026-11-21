"""Copy the rendered title-bar colors into Umbriel configs (standard library only).

Noctalia runs this as the `post_hook` of the `umbriel_titlebar` user template after every palette change:
    python3 titlebar_apply.py <rendered titlebar file>
The rendered file holds one block per config, each starting with `# config: <path>`. Earlier versions passed a
single config as a second argument and had no blocks; that form still works.
Only `background` and `background_unfocused` inside [colors.title_bar] change; everything else stays as written.
The config wins over every include (Noctalia's theme include is always last), which is why it is edited directly.
The result must parse as TOML or nothing is written; each config's previous version is kept as one rolling backup
next to this script.
"""

import hashlib
import os
import re
import sys
import tempfile

try:
    import tomllib
except ImportError:  # Python < 3.11: write without the parse check
    tomllib = None

KEYS = ("background", "background_unfocused")
VALUE = re.compile(r'^(background(?:_unfocused)?) = "(#[0-9A-Fa-f]{8})"', re.M)
HEADER = re.compile(r"^\s*\[colors\.title_bar\]\s*(#.*)?$")
KEY_LINE = re.compile(r"^(\s*)(background(?:_unfocused)?)\s*=")
CONFIG_LINE = re.compile(r"^# config: (.+)$")


def rendered_values(text):
    return {key: color.upper() for key, color in VALUE.findall(text)}


def rendered_blocks(text):
    """[(config path, {key: color})] in file order; values before the first `# config:` line are ignored."""
    blocks, current = [], None
    for line in text.splitlines():
        config = CONFIG_LINE.match(line)
        if config:
            current = (config.group(1), {})
            blocks.append(current)
        elif current is not None:
            current[1].update(rendered_values(line))
    return [(config, values) for config, values in blocks if values]


def apply(text, values):
    """Return `text` with the title-bar keys in `values` set; other lines are kept byte for byte."""
    lines = text.splitlines(keepends=True)
    start = next((index for index, line in enumerate(lines) if HEADER.match(line.rstrip("\r\n"))), None)
    if start is None:
        if not values:
            return text
        block = "".join(f'{key} = "{values[key]}"\n' for key in KEYS if key in values)
        separator = "" if not text or text.endswith("\n\n") else ("\n" if text.endswith("\n") else "\n\n")
        return text + separator + "[colors.title_bar]\n" + block
    end = next((index for index in range(start + 1, len(lines)) if lines[index].lstrip().startswith("[")), len(lines))
    done = set()
    for index in range(start + 1, end):
        match = KEY_LINE.match(lines[index])
        if match and match.group(2) in values:
            line = lines[index]
            newline = line[len(line.rstrip("\r\n")):]
            lines[index] = f'{match.group(1)}{match.group(2)} = "{values[match.group(2)]}"{newline}'
            done.add(match.group(2))
    eol = "\r\n" if lines[start].endswith("\r\n") else "\n"
    missing = "".join(f'{key} = "{values[key]}"{eol}' for key in KEYS if key in values and key not in done)
    if missing:
        lines.insert(start + 1, missing)
    return "".join(lines)


def backup_file(config):
    """`<name>.<path hash>.titlebar.bak` next to this script, so configs with the same name keep their own."""
    digest = hashlib.sha256(os.path.abspath(config).encode("utf-8")).hexdigest()[:8]
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        f"{os.path.basename(config)}.{digest}.titlebar.bak")


def check(text):
    """Return None when `text` is valid TOML (or cannot be checked), else the parse error."""
    if tomllib is None:
        return None
    try:
        tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        return str(error)
    return None


def write(path, text):
    # Its own copy of paths.atomic_write: this script is stdlib-only and runs from ~/.config/umbriel-settings/.
    mode = os.stat(path).st_mode & 0o7777 if os.path.exists(path) else 0o644
    handle, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="") as out:
            out.write(text)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def apply_file(config, values):
    """Write `values` into one config; return 0 when done or unchanged, 1 when it was left alone."""
    if os.path.islink(config):
        print(f"{config} is a symlink; not changing it.", file=sys.stderr)
        return 1
    try:
        with open(config, encoding="utf-8", newline="") as handle:
            text = handle.read()
    except (OSError, UnicodeError) as error:
        print(f"{config}: not changed ({error}).", file=sys.stderr)
        return 1
    updated = apply(text, values)
    if updated == text:
        return 0
    error = check(updated)
    if error:
        print(f"{config}: not changed, the title bar colors would make it invalid ({error}). "
              "Write [colors.title_bar] as its own table.", file=sys.stderr)
        return 1
    write(backup_file(config), text)
    write(config, updated)
    return 0


def main(argv):
    if len(argv) not in (1, 2):
        print("usage: titlebar_apply.py <rendered titlebar file> [<umbriel config.toml>]", file=sys.stderr)
        return 2
    with open(argv[0], encoding="utf-8") as handle:
        text = handle.read()
    if len(argv) == 2:  # the post_hook of earlier versions
        return apply_file(argv[1], rendered_values(text))
    status = 0
    for config, values in rendered_blocks(text):
        status = max(status, apply_file(config, values))  # one broken config must not stop the others
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
