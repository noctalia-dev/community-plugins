"""Read and update XDG default applications (mimeapps.list)."""

import mimetypes
import os
import re
import shutil
from pathlib import Path

from .backups import replace_checked
from .paths import xdg_config_home, xdg_data_dirs, xdg_data_home

ROLES = {
    "Web browser": ["text/html", "application/xhtml+xml", "x-scheme-handler/http", "x-scheme-handler/https"],
    "Email client": ["x-scheme-handler/mailto"],
    "File manager": ["inode/directory"],
    "Text editor": ["text/plain"],
    "Image viewer": ["image/jpeg", "image/png", "image/gif", "image/webp", "image/svg+xml", "image/bmp", "image/tiff"],
    "PDF viewer": ["application/pdf"],
    "Audio player": ["audio/mpeg", "audio/ogg", "audio/flac", "audio/wav"],
    "Video player": ["video/mp4", "video/webm", "video/x-matroska", "video/ogg"],
}
ROLE_MIMES = {mime for mimes in ROLES.values() for mime in mimes}
HEADER = re.compile(r"^\s*\[([^\]]+)\]\s*(?:[#;].*)?$")
ENTRY = re.compile(r"^\s*([^#;=\s][^=]*?)\s*=\s*(.*?)\s*$")
MIME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*$")
EXTENSION = re.compile(r"^\.[A-Za-z0-9][A-Za-z0-9._+-]*$")


def config_path():
    return Path(xdg_config_home()) / "mimeapps.list"


def defaults(text):
    result = {}
    section = None
    for line in text.splitlines():
        header = HEADER.fullmatch(line)
        if header:
            section = header.group(1)
        elif section == "Default Applications":
            entry = ENTRY.fullmatch(line)
            if entry:
                result[entry.group(1).strip()] = [
                    item.strip() for item in entry.group(2).split(";") if item.strip()
                ]
    return result


def locale_keys(environ=None):
    """`Name[...]` suffixes to try for the message locale, most specific first (de_DE@euro → de_DE, de)."""
    environ = os.environ if environ is None else environ
    value = next((environ.get(name) for name in ("LC_ALL", "LC_MESSAGES", "LANG") if environ.get(name)), "")
    value = value.split(".", 1)[0].split("@", 1)[0]
    if not value or value in ("C", "POSIX"):
        return []
    return [value, value.split("_", 1)[0]] if "_" in value else [value]


def shown_here(entry, desktops):
    """Apply a desktop entry's OnlyShowIn/NotShowIn to the current desktops (XDG_CURRENT_DESKTOP)."""
    only = {item for item in entry.get("onlyshowin", "").split(";") if item}
    hidden = {item for item in entry.get("notshowin", "").split(";") if item}
    if only and not only & desktops:
        return False
    return not hidden & desktops


# Keys installed_apps reads (lower-cased, like the configparser it replaced), plus Name[<locale>].
DESKTOP_KEYS = {"type", "hidden", "nodisplay", "onlyshowin", "notshowin", "tryexec", "name"}


def desktop_entry(path, wanted):
    """The `wanted` keys of a file's [Desktop Entry] group, or None when it has none or the group is malformed.

    Only that group is read (translations and actions are skipped), which keeps scanning hundreds of files fast.
    """
    try:
        text = Path(path).read_bytes().decode("utf-8")
    except (OSError, UnicodeError):
        return None
    entry, inside = None, False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped[0] in "#;":
            continue
        if stripped[0] == "[":
            if inside:
                break
            inside = stripped == "[Desktop Entry]"
            if inside:
                entry = {}
            continue
        if not inside:
            continue
        key, sep, value = stripped.partition("=")
        if not sep:
            return None
        key = key.strip().lower()
        if key in wanted:
            entry[key] = value.strip()
    return entry


FIELD_CODE = re.compile(r"%(.)")


def exec_command(path):
    """A desktop file's Exec command without its field codes (%U, %f, …; %% stays a %), or None."""
    entry = desktop_entry(path, {"exec"})
    command = FIELD_CODE.sub(lambda match: "%" if match.group(1) == "%" else "", (entry or {}).get("exec", ""))
    return " ".join(command.split()) or None


def application_roots():
    return [Path(root) / "applications" for root in (xdg_data_home(), *xdg_data_dirs())]


def app_path(app_id):
    """The desktop file an installed app ID names (the first root wins; `kde-foo.desktop` may be `kde/foo.desktop`)."""
    if not app_id.endswith(".desktop") or "/" in app_id or app_id.startswith("."):
        return None
    for root in application_roots():
        if (root / app_id).is_file():
            return root / app_id
        for directory, _subdirs, filenames in os.walk(root):
            for filename in filenames:
                path = Path(directory) / filename
                if filename.endswith(".desktop") and str(path.relative_to(root)).replace(os.sep, "-") == app_id:
                    return path
    return None


def entry_name(entry, languages):
    return next((entry[f"name[{key.lower()}]"] for key in languages if entry.get(f"name[{key.lower()}]")),
                None) or entry.get("name")


def app_names(app_ids):
    """Names of desktop files that installed_apps() leaves out (NoDisplay, e.g. the userapp-*.desktop files
    browsers and mail clients write when they make themselves the default); unknown IDs are skipped."""
    languages = locale_keys()
    wanted = DESKTOP_KEYS | {f"name[{key.lower()}]" for key in languages}
    names = {}
    for app_id in app_ids:
        if not app_id.endswith(".desktop") or "/" in app_id:
            continue
        for root in application_roots():
            entry = desktop_entry(root / app_id, wanted)
            if entry is not None:
                name = entry_name(entry, languages)
                if name:
                    names[app_id] = name
                break
    return names


def installed_apps():
    roots = application_roots()
    languages = locale_keys()
    wanted = DESKTOP_KEYS | {f"name[{key.lower()}]" for key in languages}
    desktops = {item for item in os.environ.get("XDG_CURRENT_DESKTOP", "").split(":") if item}
    apps, seen = [], set()
    for root in roots:
        for directory, subdirs, filenames in os.walk(root):
            subdirs.sort()
            for filename in sorted(filenames):
                if not filename.endswith(".desktop"):
                    continue
                path = Path(directory) / filename
                app_id = str(path.relative_to(root)).replace(os.sep, "-")
                if app_id in seen:
                    continue
                seen.add(app_id)
                entry = desktop_entry(path, wanted)
                if entry is None:
                    continue  # one broken desktop entry must not hide every other app
                if (entry.get("type", "Application") != "Application"
                        or entry.get("hidden", "").lower() == "true"
                        or entry.get("nodisplay", "").lower() == "true"
                        or not shown_here(entry, desktops)):
                    continue
                executable = entry.get("tryexec", "")
                if executable and not shutil.which(executable):
                    continue
                apps.append({"id": app_id, "name": entry_name(entry, languages) or app_id[:-8]})
    return sorted(apps, key=lambda app: (app["name"].casefold(), app["id"].casefold()))


def snapshot(text, revision, apps):
    current = defaults(text)
    roles = {}
    for role, mimes in ROLES.items():
        values = [current.get(mime, [""])[0] if current.get(mime) else "" for mime in mimes]
        roles[role] = values[0] if all(value == values[0] for value in values) else "<multiple>"
    others = {mime: values[0] if values else "" for mime, values in current.items() if mime not in ROLE_MIMES}
    return {"revision": revision, "roles": roles, "mimes": others, "apps": apps,
            "extensions": {mime: mime_extensions(mime) for mime in others},
            "role_mimes": sorted(ROLE_MIMES)}


def mime_extensions(mime):
    """Known extensions of a MIME type as one string ('.docx .dotx'), so file types can be found by extension."""
    return " ".join(sorted(set(mimetypes.guess_all_extensions(mime, strict=False))))


def validate_changes(changes):
    if not isinstance(changes, list) or not changes:
        raise ValueError("Invalid default application changes.")
    updates = {}
    seen = set()
    role_mimes = {mime.casefold() for mime in ROLE_MIMES}
    for change in changes:
        if not isinstance(change, dict) or set(change) != {"kind", "key", "value"}:
            raise ValueError("Invalid default application change.")
        kind, key, app = change["kind"], change["key"], change["value"]
        if not isinstance(key, str):
            raise ValueError("Invalid application role or MIME type.")
        if not isinstance(app, str) or any(char in app for char in ";\r\n\0"):
            raise ValueError(f"{key}: invalid application ID.")
        if kind == "role" and key in ROLES:
            mimes = ROLES[key]
        elif kind == "mime" and MIME.fullmatch(key) and key.casefold() not in role_mimes:
            mimes = [key]
        else:
            raise ValueError(f"Invalid application role or MIME type: {key}")
        for mime in mimes:
            if mime.casefold() in seen:
                raise ValueError(f"Duplicate MIME type: {mime}")
            seen.add(mime.casefold())
            updates[mime] = app
    return updates


def update_text(text, updates):
    present = set(defaults(text))
    additions = [f"{mime}={app};\n" for mime, app in updates.items() if app and mime not in present]
    output, seen = [], set()
    section = None
    found = False
    inserted = False

    def append_additions():
        if additions and output and not output[-1].endswith(("\n", "\r")):
            output[-1] += "\n"
        output.extend(additions)

    for line in text.splitlines(keepends=True):
        content = line.rstrip("\r\n")
        header = HEADER.fullmatch(content)
        if header:
            if section == "Default Applications" and not inserted:
                append_additions()
                inserted = True
            section = header.group(1)
            found = found or section == "Default Applications"
            output.append(line)
            continue
        entry = ENTRY.fullmatch(content) if section == "Default Applications" else None
        mime = entry.group(1).strip() if entry else None
        if mime not in updates:
            output.append(line)
        elif mime not in seen:
            seen.add(mime)
            app = updates[mime]
            if app:
                fallback = [item.strip() for item in entry.group(2).split(";")
                            if item.strip() and item.strip() != app]
                output.append(f"{mime}={';'.join([app, *fallback])};\n")
    if found and section == "Default Applications" and not inserted:
        append_additions()
    elif not found and additions:
        if output and not output[-1].endswith(("\n", "\r")):
            output[-1] += "\n"
        output.append("[Default Applications]\n")
        output.extend(additions)
    return "".join(output)


def save(path, backup_dir, expected_revision, changes):
    """Write the changes and return the new revision; the UI re-reads the file afterwards."""
    updates = validate_changes(changes)
    return replace_checked(path, backup_dir, expected_revision, lambda text: update_text(text, updates),
                           "Default applications")


def extension_mime(extension):
    """Return the MIME type for a file extension such as '.pdf'; raise ValueError when unknown."""
    extension = extension.strip().lower()
    if not extension.startswith("."):
        extension = "." + extension
    if not EXTENSION.fullmatch(extension):
        raise ValueError("Enter a file extension such as .pdf.")
    mime, _ = mimetypes.guess_type("file" + extension, strict=False)
    if not mime:
        raise ValueError(f"No MIME type is known for {extension}.")
    return mime
