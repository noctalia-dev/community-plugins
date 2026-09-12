#!/usr/bin/env bash
# edit_contacts.sh add <name> <path> | del <name> | set <old-name> <new-name> <new-path>
# Adds, removes or renames one entry in the plugin's "contacts" string_map inside
# Noctalia's app-managed settings.toml (the same file the Settings window writes).
# Invoked by the plugin's panel; the caller runs `noctalia msg config-reload` after.
set -eu

MODE="${1:-}"
NAME="${2:-}"
PATH_VALUE="${3:-}"
PATH_VALUE2="${4:-}"

case "$MODE" in
  add)
    if [ -z "$NAME" ] || [ -z "$PATH_VALUE" ]; then
      echo "usage: edit_contacts.sh add <name> <path>" >&2
      exit 1
    fi
    ;;
  del)
    if [ -z "$NAME" ]; then
      echo "usage: edit_contacts.sh del <name>" >&2
      exit 1
    fi
    ;;
  set)
    if [ -z "$NAME" ] || [ -z "$PATH_VALUE" ] || [ -z "$PATH_VALUE2" ]; then
      echo "usage: edit_contacts.sh set <old-name> <new-name> <new-path>" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: edit_contacts.sh add <name> <path> | del <name> | set <old-name> <new-name> <new-path>" >&2
    exit 1
    ;;
esac

STATE_DIR="${NOCTALIA_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}}/noctalia"
FILE="$STATE_DIR/settings.toml"
if [ ! -f "$FILE" ]; then
  echo "settings.toml not found at $FILE" >&2
  exit 1
fi

export MODE NAME PATH_VALUE PATH_VALUE2
python3 - "$FILE" <<'PY'
import os, sys

MODE = os.environ["MODE"]
NAME = os.environ["NAME"]
PATH_VALUE = os.environ.get("PATH_VALUE", "")
PATH_VALUE2 = os.environ.get("PATH_VALUE2", "")
FILE = sys.argv[1]

SECTION = '[plugin_settings."nilsonlinux/contact-sounds".contacts]'


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def key_of(line):
    s = line.strip()
    if not s or s.startswith("#") or "=" not in s:
        return None
    k = s.split("=", 1)[0].strip()
    if k.startswith('"') and k.endswith('"'):
        return k[1:-1].replace('\\"', '"')
    return k


def section_bounds(lines):
    idx = None
    for i, line in enumerate(lines):
        if line.strip() == SECTION:
            idx = i
            break
    if idx is None:
        return None, None
    end = len(lines)
    for i in range(idx + 1, len(lines)):
        if lines[i].strip().startswith("["):
            end = i
            break
    return idx, end


def indents(lines, idx, end):
    for j in range(idx + 1, end):
        if key_of(lines[j]) is not None:
            return lines[j][: len(lines[j]) - len(lines[j].lstrip())]
    return ""


def entry_line(indent, key, value):
    return indent + q(key) + " = " + q(value)


def upsert(lines, key, value):
    idx, end = section_bounds(lines)
    if idx is None:
        out = list(lines)
        if len(out) > 1 and out[-2].strip():
            out.append("")
        out.append("    " + SECTION)
        out.append(entry_line("        ", key, value))
        return out
    indent = indents(lines, idx, end)
    out = []
    replaced = False
    for j, line in enumerate(lines):
        if idx < j < end and key_of(line) == key:
            out.append(entry_line(indent, key, value))
            replaced = True
        else:
            out.append(line)
    if not replaced:
        out.insert(end, entry_line(indent, key, value))
    return out


def remove_key(lines, key):
    idx, end = section_bounds(lines)
    if idx is None:
        return lines
    out = []
    for j, line in enumerate(lines):
        if idx < j < end and key_of(line) == key:
            continue
        out.append(line)
    return out


lines = open(FILE, encoding="utf-8").read().splitlines()

if MODE == "del":
    out = remove_key(lines, NAME)
elif MODE == "set":
    out = remove_key(lines, NAME)
    out = upsert(out, PATH_VALUE, PATH_VALUE2)
else:  # add
    out = upsert(lines, NAME, PATH_VALUE)

with open(FILE, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
PY