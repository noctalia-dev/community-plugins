#!/usr/bin/env bash
# edit_contacts.sh add <name> <path>
#                  | del <name>
#                  | set <old-name> <new-name> <new-path>
#                  | sound <name> <path>
#                  | kind <name> contact|group|app
#                  | image <name> <image-path-or-empty>
#                  | fsound <name> <basename-or-empty>
#                  | folderadd <folder-path>
#
# Manages the plugin's tables inside Noctalia's app-managed settings.toml:
#   contacts        name -> sound file OR folder of sounds
#   contact_kinds   name -> "contact" | "group" | "app"
#   contact_images  name -> photo / icon path (optional)
#   folder_sounds   name -> chosen sound filename inside a folder entry
#   sound_folders   path -> "" (registry of known sound folders, so the panel
#                           can offer them when adding new entries)
# The file is created when missing, merged (never leaving a duplicate
# declaration), validated with tomllib before and after editing, and only then
# written. An unparseable file is backed up and left untouched. Invoked by the
# plugin's panel; the caller runs `noctalia msg config-reload` after.
set -eu

MODE="${1:-}"
NAME="${2:-}"
V2="${3:-}"
V3="${4:-}"

case "$MODE" in
  add)
    if [ -z "$NAME" ] || [ -z "$V2" ]; then
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
    if [ -z "$NAME" ] || [ -z "$V2" ] || [ -z "$V3" ]; then
      echo "usage: edit_contacts.sh set <old-name> <new-name> <new-path>" >&2
      exit 1
    fi
    ;;
  sound|image)
    if [ -z "$NAME" ]; then
      echo "usage: edit_contacts.sh $MODE <name> <value>" >&2
      exit 1
    fi
    ;;
  kind)
    case "$V2" in
      contact|group|app) ;;
      *)
        echo "usage: edit_contacts.sh kind <name> contact|group|app" >&2
        exit 1
        ;;
    esac
    ;;
  fsound)
    if [ -z "$NAME" ]; then
      echo "usage: edit_contacts.sh fsound <name> <basename-or-empty>" >&2
      exit 1
    fi
    ;;
  folderadd)
    if [ -z "$NAME" ]; then
      echo "usage: edit_contacts.sh folderadd <folder-path>" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: edit_contacts.sh add <name> <path> | del <name> | set <old-name> <new-name> <new-path> | sound <name> <path> | kind <name> contact|group|app | image <name> <path-or-empty> | fsound <name> <basename-or-empty> | folderadd <folder-path>" >&2
    exit 1
    ;;
esac

STATE_DIR="${NOCTALIA_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}}/noctalia"
FILE="$STATE_DIR/settings.toml"
mkdir -p "$STATE_DIR"
if [ ! -f "$FILE" ]; then
  touch "$FILE"
fi

export MODE NAME V2 V3
python3 - "$FILE" <<'PY'
import os, sys, tomllib, time, shutil

MODE = os.environ["MODE"]
NAME = os.environ["NAME"]
V2 = os.environ.get("V2", "")
V3 = os.environ.get("V3", "")
FILE = sys.argv[1]

PLUGIN = "nilsonlinux/contact-sounds"
PARENT = '[plugin_settings."%s"]' % PLUGIN
TABLES = ["contacts", "contact_kinds", "contact_images", "folder_sounds", "sound_folders"]
DROP_FROM_CONTACTS = [t for t in TABLES if t != "sound_folders"]
KINDS = ("contact", "group", "app")


def section_name(t):
    return '[plugin_settings."%s".%s]' % (PLUGIN, t)


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def key_of(line):
    s = line.strip()
    if not s or s.startswith("#") or "=" not in s:
        return None
    k = s.split("=", 1)[0].strip()
    if k.startswith('"') and k.endswith('"'):
        return k[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    return k


def section_bounds(target):
    for i, line in enumerate(lines):
        if line.strip() == target:
            end = len(lines)
            for j in range(i + 1, len(lines)):
                if lines[j].strip().startswith("["):
                    end = j
                    break
            return i, end
    return None, None


def indent_of(line):
    return line[: len(line) - len(line.lstrip())]


def entry_line(indent, key, value):
    return indent + q(key) + " = " + q(value)


# --- read and validate the current content; never edit a broken file ------
with open(FILE, "rb") as fh:
    try:
        data = tomllib.load(fh)
    except tomllib.TOMLDecodeError as err:
        backup = FILE + ".broken-" + time.strftime("%Y%m%d%H%M%S")
        shutil.copy2(FILE, backup)
        print("settings.toml is not valid TOML (%s); backup saved to %s; nothing changed"
              % (err, backup), file=sys.stderr)
        sys.exit(1)

cfg = data.get("plugin_settings", {}).get(PLUGIN, {})
managed = {}
for t in TABLES:
    raw = cfg.get(t)
    if isinstance(raw, dict):
        managed[t] = dict(raw)
    else:
        managed[t] = {}

# ---- apply the requested edit on the in-memory tables --------------------
if MODE == "add":
    managed["contacts"][NAME] = V2
elif MODE == "sound":
    managed["contacts"][NAME] = V2
elif MODE == "del":
    for t in TABLES:
        managed[t].pop(NAME, None)
elif MODE == "set":
    new_name, new_path = V2, V3
    for t in TABLES:
        if NAME == new_name:
            continue
        if NAME in managed[t]:
            managed[t][new_name] = managed[t].pop(NAME)
    managed["contacts"][new_name] = new_path
elif MODE == "kind":
    if V2 in KINDS:
        managed["contact_kinds"][NAME] = V2
elif MODE == "image":
    if V2.strip() == "":
        managed["contact_images"].pop(NAME, None)
    else:
        managed["contact_images"][NAME] = V2
elif MODE == "fsound":
    if V2.strip() == "":
        managed["folder_sounds"].pop(NAME, None)
    else:
        managed["folder_sounds"][NAME] = V2
elif MODE == "folderadd":
    expanded = os.path.expanduser(NAME)
    if os.path.isdir(expanded):
        managed["sound_folders"][expanded] = ""

# ---- drop stale in-memory entries for deleted/renamed contacts ----------
for t in DROP_FROM_CONTACTS:
    for key in list(managed[t]):
        if key not in managed["contacts"]:
            managed[t].pop(key, None)

# ---- rebuild the file ---------------------------------------------------
with open(FILE, encoding="utf-8") as fh:
    lines = fh.read().splitlines()

p_start, _p_end = section_bounds(PARENT)

# Where the next real (top-level) section after the plugin realm starts.
# A managed subsection header is a continuation of this realm, not its end.
realm_end = len(lines)
if p_start is not None:
    for k in range(p_start + 1, len(lines)):
        s = lines[k].strip()
        if s.startswith("["):
            if s in [section_name(t) for t in TABLES]:
                continue
            realm_end = k
            break
tail = (lines[realm_end:] if p_start is not None else [])

if MODE == "del" and p_start is None:
    # Nothing was ever configured for the plugin.
    sys.exit(0)


def build_block():
    block = []
    for t in TABLES:
        tab = managed[t]
        if not tab:
            continue
        if block and block[-1] != "":
            block.append("")
        block.append("    " + section_name(t))
        for k, v in sorted(tab.items()):
            block.append("    " + q(k) + " = " + q(v))
    block.append("")
    return block


if p_start is not None:
    # Locate each managed table's current declaration so it can be removed.
    locs = {}   # table -> {start, end, indent} for subsections, or {idx} for inline
    for t in TABLES:
        s, e = section_bounds(section_name(t))
        if s is not None:
            indent = "    "
            for j in range(s + 1, e):
                if key_of(lines[j]) is not None:
                    indent = indent_of(lines[j])
                    break
            locs[t] = {"start": s, "end": e, "indent": indent or "    "}
        else:
            for j in range(p_start + 1, _p_end):
                if key_of(lines[j]) == t:
                    locs[t] = {"idx": j}
                    break

    def is_dropped(i):
        if i < p_start:
            return False
        for t, loc in locs.items():
            if "start" in loc:
                if loc["start"] <= i < loc["end"]:
                    return True
            elif i == loc["idx"]:
                return True
        return False

    kept, have_unmanaged = [], False
    for i in range(p_start, realm_end):
        if is_dropped(i):
            continue
        kept.append(lines[i])
        if i > p_start and lines[i].strip() != "":
            have_unmanaged = True
    while len(kept) > 1 and kept[-1].strip() == "":
        kept.pop()
    if kept and kept[-1].strip() != "":
        kept.append("")

    block = build_block() if (managed["contacts"] or any(managed[t] for t in TABLES[1:])) else []
    if not block and not have_unmanaged:
        # The realm holds nothing left (all managed tables empty, no other keys).
        out = lines[:p_start] + tail
    else:
        middle = kept + block
        out = lines[:p_start] + middle + tail
else:
    out = lines[:]
    if out and out[-1].strip():
        out.append("")
    out.append(PARENT)
    for t in TABLES:
        tab = managed[t]
        if not tab:
            continue
        out.append("    " + section_name(t))
        for k, v in sorted(tab.items()):
            out.append("    " + q(k) + " = " + q(v))
    out.append("")

candidate = "\n".join(out) + "\n"
try:
    tomllib.loads(candidate)
except tomllib.TOMLDecodeError as err:
    print("refusing to write invalid settings.toml (%s); nothing changed" % err, file=sys.stderr)
    sys.exit(1)

with open(FILE, "w", encoding="utf-8") as fh:
    fh.write(candidate)
PY