"""Small fzf frontend. Package operations remain the package managers' responsibility."""

import colorsys
import datetime
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import urllib.error
import urllib.parse
import urllib.request

HOME = Path.home()
HERE = Path(__file__).resolve()
VT_KEY = HOME / ".config/package-menu/virustotal.key"
NAME = re.compile(r"[A-Za-z0-9@._+-]+")
MAX_BATCH = 50
AUR_HELPER = "paru"


class Error(Exception):
    pass


def configure_helper(value):
    global AUR_HELPER
    value = value.strip()
    if not value or value.startswith("-") or any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise Error("Set a valid AUR helper executable (for example paru, yay or an absolute path).")
    AUR_HELPER = value


def frontend_command(*args):
    # fzf callbacks run in separate processes; retain the chosen helper there too.
    return [sys.executable, "-I", str(HERE), "--aur-helper", AUR_HELPER, *args]


def update_command():
    return [AUR_HELPER, "-Syu"]


def text(value):
    return re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(value)).strip()


def valid_name(value):
    if not NAME.fullmatch(value) or value.startswith(("-", ".")):
        raise Error("Invalid package/repository name.")
    return value


def capture(argv, timeout=20, empty_ok=False, accept_report=False):
    environment = dict(os.environ, LC_ALL="C")
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, env=environment, start_new_session=True)
    try:
        output, errors = process.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise Error("Command cancelled or timed out; no result was accepted.") from None
    if process.returncode and not (accept_report and output) and not (empty_ok and not output and not errors):
        raise Error(text(errors) or f"{argv[0]} failed ({process.returncode}).")
    return output


def parse_search(output, kind):
    records = []
    for line in output.splitlines():
        match = re.match(r"^([^/\s]+)/([^\s]+)\s+(\S+)(.*)$", line)
        if match:
            source, name, version, extra = match.groups()
            valid_name(source)
            valid_name(name)
            records.append({"id": f"{source}/{name}", "name": name, "source": source,
                            "version": version, "state": "installed" if "[installed" in extra else "",
                            "description": "", "kind": kind, "extra": text(extra)})
        elif line[:1].isspace() and records:
            records[-1]["description"] += (" " if records[-1]["description"] else "") + text(line)
    return records


def parse_info(output):
    fields, current = {}, None
    for line in output.splitlines():
        match = re.match(r"^([A-Za-z][A-Za-z ]*?)\s+: (.*)$", line)
        if match:
            current, value = match.groups()
            fields[current] = value
        elif line[:1].isspace() and current:
            fields[current] += " " + line.strip()
    return fields


def parse_installed(output):
    records = []
    for block in re.split(r"\n\s*\n", output.strip()):
        fields = parse_info(block)
        if "Name" not in fields:
            continue
        name = valid_name(fields["Name"])
        source = fields.get("Installed From", "").strip()
        if source in ("", "None"):
            source = "local/unknown"
        records.append({"id": f"installed/{name}", "name": name, "source": text(source),
                        "version": fields.get("Version", "?"), "description": fields.get("Description", ""),
                        "state": "installed", "kind": "installed", "extra": ""})
    return records


def aur_info(names):
    found = {}
    # Exact-name lookup, including split packages; never infer AUR from -bin/-git.
    for start in range(0, len(names), 100):
        batch = names[start:start + 100]
        url = "https://aur.archlinux.org/rpc/v5/info?" + urllib.parse.urlencode({"arg[]": batch}, doseq=True)
        with urllib.request.urlopen(url, timeout=12) as response:
            data = json.load(response)
        if not isinstance(data, dict) or data.get("type") != "multiinfo" or not isinstance(data.get("results"), list):
            raise Error("Invalid AUR info response")
        for item in data["results"]:
            if not isinstance(item, dict) or not isinstance(item.get("Name"), str):
                raise Error("Invalid AUR package record")
            name = valid_name(item["Name"])
            if name not in batch:
                raise Error("Unexpected AUR package record")
            found[name] = item
    return found


def installed_catalog():
    records = parse_installed(capture(["pacman", "-Qi"]))
    unresolved = [record for record in records if record["source"] == "local/unknown"]
    if not unresolved:
        return records
    # Local sync databases, in pacman repository priority order. No refresh.
    repositories = {}
    try:
        for line in capture(["pacman", "-Sl"]).splitlines():
            fields = line.split()
            if len(fields) >= 3:
                source, name, version = fields[:3]
                repositories.setdefault(valid_name(name), []).append((valid_name(source), version))
    except (Error, OSError) as error:
        # Without the repo index we cannot safely distinguish foreign packages.
        for record in unresolved:
            record["source_detail"] = "Source lookup unavailable: " + text(error)
        print("Source lookup unavailable: " + text(error), file=sys.stderr)
        return records
    foreign = []
    for record in unresolved:
        candidates = repositories.get(record["name"], [])
        if candidates:
            exact = [candidate for candidate in candidates if candidate[1] == record["version"]]
            record["source"] = (exact or candidates)[0][0]
            record["source_detail"] = ("Matching installed version in local sync database." if exact else
                                       "Currently available in local sync database (version differs).")
            record["source_detail"] += " Installation origin was not recorded; repository priority breaks ties."
        else:
            foreign.append(record)
    try:
        available = aur_info([record["name"] for record in foreign])
    except (Error, OSError, ValueError) as error:
        for record in foreign:
            record["source_detail"] = "Not in configured repositories; AUR lookup unavailable: " + text(error)
        print("AUR source lookup unavailable: " + text(error), file=sys.stderr)
    else:
        for record in foreign:
            if record["name"] in available:
                record["source"] = "aur"
                record["source_detail"] = "Exact package name found in AUR; installation origin was not recorded."
            else:
                record["source_detail"] = "No recorded origin or exact name in configured repositories/AUR."
    return records


def catalog(mode, query=""):
    if mode == "repos":
        return parse_search(capture(["pacman", "-Ss", "."]), "repo")
    if mode == "installed":
        return installed_catalog()
    if not query.strip():
        return []
    # Search is read-only. No fallback mirror or alternative package is substituted.
    output = capture([AUR_HELPER, "-Ssa", "--color", "never", "--", query], timeout=30, empty_ok=True)
    return parse_search(output, "aur")


def theme_options():
    # Read only generated color declarations, never source/evaluate a shell file.
    path = HOME / ".config/fzf/themes/noctalia.sh"
    if not path.is_file():
        return []
    return [line.rstrip('"') for line in path.read_text().splitlines()
            if re.fullmatch(r'--color=[a-z+_-]+:#[0-9a-fA-F]{6}"?', line)]


def search_options():
    # --nth applies AFTER --with-nth; field 2 there is the full package name.
    return ["--ansi", "--exact", "--no-extended", "--ignore-case", "--no-sort", "--highlight-line",
            "--delimiter=\t", "--with-nth={3}\t{2}\t{4}", "--nth=2", "--tabstop=1", "--no-hscroll"]


def source_order(record):
    source = record["source"].casefold()
    group = 2 if source == "aur" or record["kind"] == "aur" else (1 if source.startswith("cachyos") else 0)
    return group, source, record["name"].casefold()


def aur_search(query, installed):
    url = "https://aur.archlinux.org/rpc/v5/search/" + urllib.parse.quote(query, safe="") + "?by=name"
    with urllib.request.urlopen(url, timeout=12) as response:
        data = json.load(response)
    if not isinstance(data, dict):
        raise Error("Invalid AUR response")
    if data.get("type") != "search" or not isinstance(data.get("results"), list):
        raise Error(text(data.get("error", "Invalid AUR response")))
    records = []
    for item in data["results"]:
        if not isinstance(item, dict) or not isinstance(item.get("Name"), str) or not isinstance(item.get("Version"), str):
            raise Error("Invalid AUR package record")
        name = valid_name(item["Name"])
        if query.casefold() in name.casefold():
            records.append({"id": "aur/" + name, "name": name, "source": "aur",
                            "version": text(item["Version"]), "description": text(item.get("Description") or ""),
                            "state": "installed" if name in installed else "", "kind": "aur", "extra": ""})
    return records


def merged_search(database, query):
    # fzf cancels this process when another character is typed; no helper daemon.
    time.sleep(0.3)
    directory = Path(database).parent
    lookup = json.loads(Path(database).read_text())
    status = "AUR: type at least 2 characters"
    if len(query.strip()) >= 2:
        try:
            installed = set(json.loads((directory / "installed.json").read_text()))
            aur = aur_search(query, installed)
            lookup.update({record["id"]: record for record in aur})
            status = f"AUR: {len(aur)} results"
        except (Error, OSError, ValueError, KeyError) as error:
            status = "AUR unavailable (local/cached results only): " + text(error)
    # Keep prior entries available for previews and selections during reload.
    with tempfile.NamedTemporaryFile(mode="w", dir=directory, delete=False) as output:
        json.dump(lookup, output)
        temporary = Path(output.name)
    temporary.replace(database)
    base = (directory / "header.txt").read_text()
    (directory / "status.txt").write_text(status + "\n" + base)
    print(picker_rows(sorted(lookup.values(), key=source_order)), flush=True)


def colored(value, color, bold=False, dim=False):
    red, green, blue = (int(color[index:index + 2], 16) for index in (1, 3, 5))
    style = "1;" if bold else ("2;" if dim else "")
    return f"\033[{style}38;2;{red};{green};{blue}m{value}\033[0m"


def source_color(source, kind, palette):
    source = source.casefold()
    if source in ("", "local/unknown"):
        return palette.get("fg", "#cdd6f4")
    if source == "aur" or kind == "aur":
        return "#f9e2af"
    if source.startswith("cachyos"):
        return palette.get("info", "#cba6f7")
    if source.split("-", 1)[0] in ("core", "extra", "multilib"):
        return palette.get("marker", "#a6e3a1")
    # Stable across searches and Python restarts, including previously unseen repos.
    hue = int.from_bytes(hashlib.sha256(source.encode()).digest()[:4], "big") / 2**32
    return "#" + "".join(f"{round(channel * 255):02x}"
                         for channel in colorsys.hls_to_rgb(hue, 0.74, 0.72))


def picker_rows(records, show_state=True):
    palette = dict(option.removeprefix("--color=").split(":", 1) for option in theme_options())
    foreground = palette.get("fg", "#cdd6f4")
    green = palette.get("marker", "#a6e3a1")
    source_colors = {source: source_color(source, kind, palette)
                     for source, kind in {(record["source"], record["kind"]) for record in records}}
    lines = []
    for record in records:
        name = text(record["name"])
        description = text(record.get("description", ""))
        source = text(record["source"])
        label = "AUR" if source.casefold() == "aur" or record["kind"] == "aur" else source
        state = "[Installed]" if record.get("state") == "installed" else ""
        state_column = colored(f"{state:<11}", green) + " " if show_state else ""
        details = (colored(f"{record.get('version', ''):<14.14}", foreground, dim=True) + " "
                   + state_column + colored(description, foreground, dim=True))
        if record["kind"] == "menu":
            details = colored(description, foreground, dim=True)
        # Keep the complete name searchable, even when it exceeds the column width.
        lines.append(record["id"] + "\t" + colored(name, foreground, bold=True) + "\t"
                     + colored(f"{label:<16}", source_colors[record["source"]], bold=True) + "\t"
                     + " " * max(0, 26 - len(name)) + details)
    return "\n".join(lines)


def clear_console():
    if sys.stdout.isatty():
        print("\033[2J\033[3J\033[H", end="", flush=True)


def resize_preview(path, delta):
    if delta not in (-5, 5):
        raise Error("Invalid preview resize step.")
    path = Path(path)
    size = max(25, min(75, int(path.read_text()) + delta))
    path.write_text(str(size))
    return f"change-preview-window(right,{size}%,wrap)+refresh-preview"


def preview_mode(database, mode):
    if mode not in ("details", "recipe"):
        raise Error("Invalid preview mode.")
    path = Path(database).parent / "preview-mode"
    path.write_text("summary" if path.read_text() == mode else mode)
    return "refresh-preview"


def picker(records, title, query="", multi=True, keys="", preview=True, searchable=True, merged=False, show_state=True):
    clear_console()
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    with tempfile.TemporaryDirectory(prefix="package-menu-", dir=runtime) as directory:
        database = Path(directory) / "catalog.json"
        database.write_text(json.dumps({record["id"]: record for record in records}))
        header = "Tab multi · Enter confirm · Esc back · Shift+←/→ resize\nCtrl+A all · Ctrl+D clear · Alt+P preview · Alt+T Traur audit" if multi else "↑/↓ choose · Enter open · Esc exit"
        if keys:
            header += "\n" + keys
        if multi:
            header += f"\n{'SOURCE':<16} {'PACKAGE':<26} {'VERSION':<14}"
            if show_state:
                header += " STATE"
        args = ["fzf", "--layout=reverse", "--border=rounded", "--info=inline", "--no-separator", *search_options(), "--print-query",
                "--expect=alt-t", "--query=" + query,
                "--border-label= " + title + " ", "--header=" + header, *theme_options()]
        if searchable:
            args += ["--prompt=Search packages > "]
        else:
            args += ["--no-input", "--disabled", "--info=hidden", "--with-nth=2,4", "--nth=1"]
        if merged:
            (Path(directory) / "installed.json").write_text(json.dumps(capture(["pacman", "-Qq"]).splitlines()))
            (Path(directory) / "header.txt").write_text(header)
            (Path(directory) / "status.txt").write_text("AUR: type at least 2 characters\n" + header)
            command = "exec " + shlex.join(frontend_command("--search", str(database))) + " {q}"
            status = shlex.join(["cat", str(Path(directory) / "status.txt")])
            args += ["--id-nth=1", "--bind=start:reload-sync(" + command + "),change:reload-sync(" + command + ")",
                     "--bind=load:transform-header(" + status + ")"]
        if multi:
            args += [f"--multi={MAX_BATCH}", "--bind=ctrl-a:select-all,ctrl-d:deselect-all"]
        if preview:
            (Path(directory) / "preview-mode").write_text("summary")
            command = shlex.join(frontend_command("--preview", str(database))) + " {1}"
            size_file = Path(directory) / "preview-size"
            size_file.write_text("48")
            resize = shlex.join(frontend_command("--resize-preview", str(size_file)))
            mode = shlex.join(frontend_command("--preview-mode", str(database)))
            args += ["--preview=" + command, "--preview-window=right,48%,wrap", "--bind=alt-p:toggle-preview",
                     "--bind=alt-d:transform(" + mode + " details),alt-b:transform(" + mode + " recipe)",
                     "--bind=shift-left:transform(" + resize + " 5),shift-right:transform(" + resize + " -5)"]
        else:
            args += ["--preview-window=hidden"]
        selected = subprocess.run(args, input=picker_rows(records, show_state=show_state), text=True, stdout=subprocess.PIPE)
        if selected.returncode in (1, 130):
            return None
        if selected.returncode:
            raise Error("fzf could not open the package selector.")
        output = selected.stdout.splitlines()
        lookup = json.loads(database.read_text())
        chosen = [lookup[line.split("\t", 1)[0]] for line in output[2:]]
        return output[0], output[1], chosen


def preview_fields(fields):
    for label, value in fields:
        value = "  ".join(map(text, value)) if isinstance(value, list) else text(value if value is not None else "")
        print(textwrap.fill(value or "None", width=max(24, int(os.environ.get("FZF_PREVIEW_COLUMNS", "80"))),
                            initial_indent=f"{label:<16}: ", subsequent_indent=" " * 18, break_on_hyphens=False))


def preview_aur(directory, record, mode):
    name = valid_name(record["name"])
    metadata = directory / ("aur-" + name + ".json")
    try:
        if not metadata.exists():
            metadata.write_text(json.dumps(aur_info([name]).get(name)))
        item = json.loads(metadata.read_text())
        if not item:
            raise Error("Package no longer listed in AUR.")
        if mode == "recipe":
            base = valid_name(item.get("PackageBase", name))
            recipe = directory / ("recipe-" + base)
            if not recipe.exists():
                url = "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?" + urllib.parse.urlencode({"h": base})
                with urllib.request.urlopen(url, timeout=12) as response:
                    content = response.read(256 * 1024 + 1)
                if len(content) > 256 * 1024:
                    raise Error("PKGBUILD exceeds preview limit.")
                if content.lstrip().lower().startswith((b"<!doctype", b"<html")):
                    raise Error("AUR returned a web page, not a PKGBUILD.")
                recipe.write_bytes(content)
            print("Current AUR PKGBUILD · read-only · Alt+B back\n")
            content = re.sub(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]", "", recipe.read_text(errors="replace"))
            print(content)
            return
        if record["kind"] == "installed":
            if mode == "details":
                print("AUR metadata")
            fields = []
        else:
            fields = [("Version", item.get("Version", record["version"])),
                      ("Description", item.get("Description") or record.get("description", ""))]
            fields += [(label, item.get(key, [])) for label, key in (
                ("Licenses", "License"), ("Depends On", "Depends"))]
        fields += [("Maintainer", item.get("Maintainer") or "Orphaned"),
                   ("Votes", item.get("NumVotes", "?")), ("Popularity", item.get("Popularity", "?"))]
        if record["kind"] == "installed" and item.get("Version") and item["Version"] != record["version"]:
            fields.append(("AUR version", item["Version"]))
        if item.get("OutOfDate"):
            fields.append(("Status", "Flagged out-of-date"))
        if mode == "details":
            if record["kind"] != "installed":
                fields += [(label, item.get(key, [])) for label, key in (
                    ("URL", "URL"), ("Groups", "Groups"), ("Provides", "Provides"),
                    ("Optional Deps", "OptDepends"), ("Conflicts With", "Conflicts"), ("Replaces", "Replaces"))]
            fields += [(label, item.get(key, [])) for label, key in (
                ("Make Deps", "MakeDepends"), ("Check Deps", "CheckDepends"),
                ("Package Base", "PackageBase"), ("Keywords", "Keywords"))]
            fields.append(("Package URL", "https://aur.archlinux.org/packages/" + name))
            for label, key in (("Submitted", "FirstSubmitted"), ("Modified", "LastModified")):
                if item.get(key):
                    fields.append((label, datetime.datetime.fromtimestamp(item[key], datetime.timezone.utc).isoformat(timespec="minutes")))
        preview_fields(fields)
    except (Error, OSError, ValueError, TypeError, OverflowError) as error:
        if record["kind"] != "installed":
            print(text(record.get("description", "")))
        print("\nAUR preview unavailable:", text(error))


def preview(database, identifier):
    record = json.loads(Path(database).read_text()).get(identifier)
    if not record:
        raise Error("The selected package is no longer in this list.")
    print(text(record["name"]), flush=True)
    directory = Path(database).parent
    mode_file = directory / "preview-mode"
    mode = mode_file.read_text() if mode_file.exists() else "summary"
    if mode == "details" and record.get("source_detail"):
        print(text(record["source_detail"]))
    is_aur = record["source"].casefold() == "aur" or record["kind"] == "aur"
    if record["kind"] != "aur" and not (is_aur and mode == "recipe"):
        operation = "-Qi" if record["kind"] == "installed" else "-Si"
        target = record["name"] if operation == "-Qi" else record["id"]
        info = capture(["pacman", operation, "--", target])
        if mode == "details":
            print(info, flush=True)
        else:
            fields = parse_info(info)
            fields.setdefault("Version", record["version"])
            fields.setdefault("Description", record.get("description", ""))
            keys = ["Version", "Description", "Licenses", "Depends On", "Installed Size", "Packager"]
            if fields.get("Required By", "None") != "None":
                keys.append("Required By")
            preview_fields((key, fields[key]) for key in keys if key in fields
                           and not (is_aur and key == "Packager" and fields[key] == "Unknown Packager"))
            sys.stdout.flush()
    if is_aur:
        preview_aur(directory, record, mode)
    print("\nAlt+D " + ("compact view" if mode == "details" else "full details")
          + (" · Alt+B " + ("back" if mode == "recipe" else "PKGBUILD") if is_aur else ""))


def validate_selection(records):
    if not records:
        raise Error("No packages selected.")
    if len(records) > MAX_BATCH:
        raise Error(f"Select at most {MAX_BATCH} packages at a time; narrow the search first.")
    names = [valid_name(record["name"]) for record in records]
    if len(set(names)) != len(names):
        raise Error("Select only one source/version of each package.")
    return names


def transaction_command(action, records):
    names = validate_selection(records)
    if action == "install":
        kinds = {record["kind"] for record in records}
        if kinds == {"repo"}:
            targets = [valid_name(record["source"]) + "/" + name for record, name in zip(records, names)]
            return ["sudo", "pacman", "-S", "--needed", "--", *targets]
        if kinds == {"aur"}:
            return [AUR_HELPER, "-S", "--needed", "--aur", "--", *names]
        raise Error("Install one source category at a time.")
    if any(record["kind"] != "installed" for record in records):
        raise Error("Choose installed packages for this action.")
    if action == "remove":
        return ["sudo", "pacman", "-Rns", "--", *names]
    if action == "downgrade":
        # No cross-repository substitution; includes helper caches explicitly.
        args = ["sudo", "downgrade", "--cached-only", "--ignore=never"]
        # Explicit --pacman-cache replaces the tool's defaults, so retain all
        # configured system caches before adding the user's helper caches.
        caches = [Path(line) for line in capture(["pacman-conf", "CacheDir"]).splitlines() if line]
        for cache in [*caches, HOME / ".cache/paru/clone", HOME / ".cache/yay"]:
            if cache.is_dir():
                args += ["--pacman-cache=" + str(cache)]
        return [*args, *names]
    raise Error("Unknown package operation.")


def transaction_commands(action, records):
    validate_selection(records)
    if action == "install" and {record["kind"] for record in records} == {"repo", "aur"}:
        return [transaction_command(action, [record for record in records if record["kind"] == kind])
                for kind in ("repo", "aur")]
    return [transaction_command(action, records)]


def confirm(message):
    return input(message + " [y/N] ").strip().lower() == "y"


def perform(action, records):
    commands = transaction_commands(action, records)
    print("\n" + action.upper())
    for record in records:
        print(f"  {record['name']}   [{record['source']}]   {record['version']}")
    if len(commands) > 1:
        print(f"Repository packages first, then AUR using your existing {text(AUR_HELPER)}/makepkg configuration.")
    if action == "remove":
        print("Pacman will also show any unused dependencies selected for removal.")
    elif action == "downgrade":
        print("Local cache only. No Arch archive fallback and no automatic IgnorePkg changes.")
        print("A downgrade can break dependencies; review pacman's transaction.")
    if confirm("Continue to the package manager?"):
        for command in commands:
            code = subprocess.call(command)
            if code:
                raise Error(f"Package operation stopped (exit {code}). No fallback was attempted.")


def audit(records):
    for record in records:
        if record["kind"] != "aur" and record["source"].casefold() != "aur":
            print("\nSkipping non-AUR package:", record["name"])
            continue
        print("\nTraur:", record["name"])
        try:
            output = capture(["traur", "scan", valid_name(record["name"]), "--json"], timeout=90, accept_report=True)
            report = json.loads(output)
            if not isinstance(report, dict) or report.get("status") != "complete" or not isinstance(report.get("tier"), str) or not isinstance(report.get("signals"), list):
                raise Error("Incomplete or invalid Traur report.")
            print("Result:", text(report["tier"]), "—", text(report["status"]))
            for finding in report.get("signals", []):
                if isinstance(finding, dict) and finding.get("role") not in ("Fact", "Provenance"):
                    print(" ", text(finding.get("description", "")))
        except (Error, OSError, ValueError, KeyError) as error:
            print("NO VALID AUDIT RESULT:", text(error))
    print("\nManual report only. Build-time protection depends on your helper/makepkg setup.")


def file_digest(value):
    value = value.strip()
    if re.fullmatch(r"[a-fA-F0-9]{64}", value):
        return value.lower()
    path = Path(value).expanduser()
    if not path.is_file():
        raise Error("Enter a regular file path or a SHA-256 digest.")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def save_vt_key(key):
    key = key.strip()
    if not 20 <= len(key) <= 200 or any(character.isspace() for character in key):
        raise Error("Invalid API key format.")
    VT_KEY.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=VT_KEY.parent, delete=False) as temporary:
        temporary.write(key)
        temporary_path = Path(temporary.name)
    temporary_path.replace(VT_KEY)  # tempfile is owner-only (0600).


def vt_lookup(digest, key):
    if not re.fullmatch(r"[a-f0-9]{64}", digest):
        raise Error("Invalid SHA-256.")
    request = urllib.request.Request("https://www.virustotal.com/api/v3/files/" + digest,
                                     headers={"x-apikey": key, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)["data"]["attributes"]
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        if error.code == 429:
            raise Error("VirusTotal rate limit reached. Try later; no verdict is available.") from None
        raise Error(f"VirusTotal request failed (HTTP {error.code}); no verdict is available.") from None
    except (urllib.error.URLError, TimeoutError, ValueError, KeyError):
        raise Error("Could not read a valid VirusTotal report; no verdict is available.") from None


def virustotal():
    print("\nVIRUSTOTAL — existing reports only; files are never uploaded.")
    value = input("File path or SHA-256 (empty = back): ").strip()
    if not value:
        return
    digest = file_digest(value)
    link = "https://www.virustotal.com/gui/file/" + digest
    print("SHA-256:", digest)
    key = os.environ.get("VT_API_KEY", "").strip()
    if not key and VT_KEY.is_file():
        if VT_KEY.stat().st_mode & 0o077:
            raise Error("VT key file is not private (expected permissions 0600).")
        key = VT_KEY.read_text().strip()
    if not key and confirm("Add a VT API key for results in this terminal? (otherwise use browser)"):
        key = getpass.getpass("VT API key (hidden, stored owner-only): ").strip()
        save_vt_key(key)
    if key:
        attributes = vt_lookup(digest, key)
        if attributes is None:
            print("UNKNOWN: no existing report. This does NOT mean the file is safe.")
        else:
            stats = attributes.get("last_analysis_stats", {})
            if not stats:
                print("UNKNOWN: report contains no engine results.")
            else:
                print("Malicious:", stats.get("malicious", 0), " Suspicious:", stats.get("suspicious", 0),
                      " Undetected:", stats.get("undetected", 0))
                stamp = attributes.get("last_analysis_date")
                if stamp:
                    print("Last analysis:", datetime.datetime.fromtimestamp(stamp).astimezone().isoformat(timespec="minutes"))
                print("No detections is NOT a safety guarantee. This is the existing report, not a new scan.")
    print(link)
    if confirm("Open the report in your browser?"):
        subprocess.Popen(["xdg-open", link], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def pause():
    input("\nEnter to return to Packages…")
    clear_console()


def browse(action):
    mode, query = ("repos" if action == "install" else "installed"), ""
    while True:
        print("Loading " + mode + " packages…", flush=True)
        records = sorted(catalog(mode, query), key=source_order)
        title = {"install": "Find & install", "remove": "Installed / uninstall", "downgrade": "Downgrade (cache only)"}[action]
        hints = "Finish selections before changing the search" if action == "install" else ""
        selected = picker(records, title + (" — repos + AUR" if action == "install" else " — installed"),
                          query, keys=hints, merged=action == "install", show_state=action == "install")
        if selected is None:
            return
        query, key, chosen = selected
        if not chosen:
            continue
        if key == "alt-t":
            audit(chosen)
        elif key == "":
            perform(action, chosen)
        pause()


def main():
    choices = [
        ("install", "Find & install", "Repositories + AUR; alphabetical groups by source"),
        ("remove", "Installed / uninstall", "List installed packages and select several to remove"),
        ("downgrade", "Downgrade", "Select previous versions from local caches"),
        ("vt", "VirusTotal", "Check a file/SHA-256; no upload"),
        ("update", "Update system", f"Normal {text(AUR_HELPER)} update using your existing configuration"),
        ("exit", "Exit", ""),
    ]
    records = [{"id": key, "name": name, "source": "", "description": description, "kind": "menu"}
               for key, name, description in choices]
    while True:
        try:
            selected = picker(records, "Packages", multi=False, preview=False, searchable=False)
            if selected is None or not selected[2] or selected[2][0]["id"] == "exit":
                return
            action = selected[2][0]["id"]
            if action in ("install", "remove", "downgrade"):
                browse(action)
            elif action == "vt":
                virustotal()
                pause()
            elif action == "update" and confirm(f"Run the normal full system update with {text(AUR_HELPER)}?"):
                subprocess.call(update_command())
                pause()
        except (Error, OSError) as error:
            print("\nSTOP:", text(error))
            print("No automatic retry, alternative package source or security bypass was used.")
            pause()
        except (KeyboardInterrupt, EOFError):
            return


def run(argv):
    if argv[:1] == ["--aur-helper"]:
        if len(argv) < 2:
            raise Error("--aur-helper requires an executable.")
        configure_helper(argv[1])
        argv = argv[2:]
    if len(argv) == 3 and argv[0] == "--preview":
        preview(argv[1], argv[2])
    elif len(argv) == 3 and argv[0] == "--preview-mode":
        print(preview_mode(argv[1], argv[2]))
    elif len(argv) == 3 and argv[0] == "--search":
        merged_search(argv[1], argv[2])
    elif len(argv) == 3 and argv[0] == "--resize-preview":
        print(resize_preview(argv[1], int(argv[2])))
    elif len(argv) >= 2 and argv[0] == "--list":
        print(json.dumps(catalog(argv[1], " ".join(argv[2:])), ensure_ascii=True))
    elif not argv:
        main()
    else:
        raise Error("Usage: package-menu [--aur-helper EXECUTABLE] [--list repos|installed|aur [query]]")


if __name__ == "__main__":
    try:
        run(sys.argv[1:])
    except (Error, OSError) as error:
        print(text(error), file=sys.stderr)
        raise SystemExit(1)
