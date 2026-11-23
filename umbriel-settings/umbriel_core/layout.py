"""Text-level layout of the config file: entry name comments, keybind placement, canonical rebuild, diff sections."""

import re

import tomlkit

from .tomlops import header_re


def add_entry_name_comments(text, sections):
    """Render custom array-entry names as comments immediately above their TOML headers.

    `sections` maps an array-of-tables path to its labels, e.g. {"window_rule": ["", "Browsers"]}.
    """
    marker = "# GUI rule name: "
    headers = {path: header_re(path, aot=True) for path in sections}
    indexes = {path: 0 for path in sections}
    output = []
    for line in text.splitlines(keepends=True):
        if line.startswith(marker):
            continue
        for path, header in headers.items():
            if header.match(line):
                index = indexes[path]
                labels = sections[path]
                if index < len(labels):
                    name = " ".join(labels[index].splitlines()).strip()
                    if name:
                        ending = "\r\n" if line.endswith("\r\n") else "\n"
                        output.append(f"{marker}{name}{ending}")
                indexes[path] += 1
                break
        output.append(line)
    return "".join(output)


def inline_window_rule_matches(doc):
    """Keep each window rule's match fields inside its [[window_rule]] block."""
    rules = doc.get("window_rule", [])
    if not isinstance(rules, list):  # hand-written as a single table; Umbriel's validation reports it
        return
    for rule in rules:
        if not isinstance(rule, dict) or "match" not in rule:
            continue
        match = rule["match"]
        if not isinstance(match, dict) or isinstance(match, tomlkit.items.InlineTable):
            continue
        try:
            if any(k is not None and k.key == "match" and k.is_dotted() for k, _ in rule.value.body):
                continue
        except AttributeError:
            pass
        inline = tomlkit.inline_table()
        for key, value in match.items():
            inline[key] = value
        rule["match"] = inline


def move_new_keybinds(text, new_keys):
    """Place newly added keybinds at the end of [keybinds], before trailing comments."""
    if not new_keys:
        return text
    lines = text.splitlines(keepends=True)
    keybind_header = header_re("keybinds")
    table_header = re.compile(r"^\s*\[\[?.+\]\]?[ \t]*(?:#.*)?\r?\n?$")
    start = next((i for i, line in enumerate(lines) if keybind_header.match(line)), None)
    if start is None:
        return text
    end = next((i for i in range(start + 1, len(lines)) if table_header.match(lines[i])), len(lines))
    section = lines[start + 1:end]
    moved = []
    for key_name in new_keys:
        serialized_key = tomlkit.key(key_name).as_string()
        pattern = re.compile(r"^\s*" + re.escape(serialized_key) + r"\s*=")
        match = next((i for i, line in enumerate(section) if pattern.match(line)), None)
        if match is not None:
            moved.append(section.pop(match))
    if not moved:
        return text
    key_assignment = re.compile(r'''^\s*(?:"(?:\\.|[^"\\])*"|'[^']*'|[A-Za-z0-9_-]+)\s*=''')
    last_binding = max((i for i, line in enumerate(section) if key_assignment.match(line)), default=-1)
    prefix = "".join(section[:last_binding + 1]).rstrip("\r\n")
    suffix = "".join(section[last_binding + 1:]).lstrip("\r\n")
    newline = "\r\n" if "\r\n" in text else "\n"
    header = "# Additional keybinds"
    has_header = any(line.strip() == header for line in section[:last_binding + 1])
    binding_block = ("" if has_header else header + newline) + "".join(
        line.rstrip("\r\n") + newline for line in moved
    )
    if prefix:
        binding_block = newline + (binding_block if has_header else newline + binding_block)
    if suffix:
        binding_block += newline + suffix
    else:
        binding_block += newline
    return "".join(lines[:start + 1]) + prefix + binding_block + "".join(lines[end:])


# ------------------------------------------------------- structure rebuild
# Canonical layout of the whole file: (banner label, top-level tables in that block).
CONFIG_LAYOUT = [
    ("includes", ["include"]),
    ("session", ["general", "environment", "events", "drm"]),
    ("outputs", ["output"]),
    ("input", ["input"]),
    ("colors", ["colors"]),
    ("appearance", ["appearance"]),
    ("layout", ["layout"]),
    ("workspaces", ["workspaces"]),
    ("overview", ["overview"]),
    ("screencast", ["screencast"]),
    ("animation", ["animation"]),
    ("effects", ["effects"]),
    ("hot corners", ["hot_corners"]),
    ("keybinds", ["keybinds"]),
    ("window rules", ["window_rule"]),
    ("layer rules", ["layer_rule"]),
    ("workspace rules", ["workspace"]),
    ("scratchpads", ["scratchpad"]),
    ("security rules", ["security_context_rule"]),
]
BANNER_RE = re.compile(r"^\s*#\s*-{5,}")
BANNER_WIDTH = 77


def banner_line(label, newline):
    """Return a section banner such as '# ------- keybinds', padded to a fixed width like the stock config."""
    return "# " + "-" * max(3, BANNER_WIDTH - 3 - len(label)) + " " + label + newline


def _scan_line(line, depth, string):
    """Carry the bracket depth and the open string (None or its quote: '"', "'", '\"\"\"', "'''") across one line
    of a TOML value; a comment ends the line, and single-line strings never continue onto the next line."""
    j = 0
    while j < len(line):
        ch = line[j]
        if string is None:
            if line.startswith('"""', j) or line.startswith("'''", j):
                string, j = line[j:j + 3], j + 2
            elif ch in "\"'":
                string = ch
            elif ch == "#":
                break
            elif ch in "[{":
                depth += 1
            elif ch in "]}":
                depth -= 1
        elif string in ('"', '"""'):
            if ch == "\\":
                j += 1
            elif line.startswith(string, j):
                string, j = None, j + len(string) - 1
        elif line.startswith(string, j):
            string, j = None, j + len(string) - 1
        j += 1
    return depth, None if string in ('"', "'") else string


def split_statements(text):
    """Split TOML text into blank/comment/header/kv statements; a kv spans every line of a multi-line value."""
    lines = text.splitlines(keepends=True)
    out, i = [], 0
    while i < len(lines):
        stripped = lines[i].strip()
        if not stripped:
            out.append(("blank", lines[i]))
        elif stripped.startswith("#"):
            out.append(("comment", lines[i]))
        elif stripped.startswith("["):
            out.append(("header", lines[i]))
        else:
            chunk, depth, string = [], 0, None
            while i < len(lines):
                line = lines[i]
                chunk.append(line)
                depth, string = _scan_line(line, depth, string)
                i += 1
                if depth <= 0 and string is None:
                    break
            i -= 1
            out.append(("kv", "".join(chunk)))
        i += 1
    return out


def header_path(line):
    """Return (path tuple, is_array_of_tables) for a '[a.b]' or '[[a.b]]' header line."""
    data = tomlkit.parse(line).unwrap()
    path = []
    while isinstance(data, dict) and len(data) == 1:
        key, data = next(iter(data.items()))
        path.append(key)
        if isinstance(data, list) and data:
            data = data[0]
    return tuple(path), line.lstrip().startswith("[[")


def tidy_lines(items):
    """Drop banner lines and outer blank lines from a comment run; collapse repeated blank lines."""
    kept = [it for it in items if not (it[0] == "comment" and BANNER_RE.match(it[1]))]
    while kept and kept[0][0] == "blank":
        kept.pop(0)
    while kept and kept[-1][0] == "blank":
        kept.pop()
    result = []
    for kind, text in kept:
        if kind == "blank" and result and result[-1][0] == "blank":
            continue
        result.append((kind, text))
    return result


def pull_banner_blocks(pending):
    """Split a comment run into (banner blocks that introduce the NEXT section, the rest that belongs to the
    next key)."""
    carried, rest, i = [], [], 0
    while i < len(pending):
        kind, text = pending[i]
        if kind == "comment" and BANNER_RE.match(text):
            while i < len(pending) and pending[i][0] == "comment":
                carried.append(pending[i])
                i += 1
            carried.append(("blank", "\n"))
            continue
        rest.append(pending[i])
        i += 1
    return carried, rest


def rebuild_config(text):
    """Return `text` rebuilt in canonical order: banners, sections grouped, every key inside its own table.

    Keys that tomlkit appended below another section's comments are pulled back into their table, and
    those comments move to the section they introduce. Raises ValueError if the result would not
    parse to exactly the same data as the input.
    """
    newline = "\r\n" if "\r\n" in text else "\n"
    stmts = split_statements(text)
    preamble, k = [], 0
    while k < len(stmts) and stmts[k][0] == "comment":
        preamble.append(stmts[k])
        k += 1
    if not (k < len(stmts) and stmts[k][0] == "blank"):
        preamble, k = [], 0                      # a comment glued to the first statement is not a file header
    root, blocks, current = [], [], None
    pending, carry = [], []
    for kind, stmt in stmts[k:]:
        if kind in ("blank", "comment"):
            pending.append((kind, stmt))
        elif kind == "kv":
            moved, rest = pull_banner_blocks(pending)
            carry += moved
            lead = []
            for item in rest:
                if item[0] == "blank" and lead and lead[-1][0] == "blank":
                    continue
                lead.append(item)
            first = current is None or not current["items"]
            if moved or first or not any(a == "comment" for a, _ in lead):
                # displaced / first keys stay glued to their table; blank-only gaps are dropped
                while lead and lead[0][0] == "blank" and (moved or first):
                    lead.pop(0)
                if moved:
                    lead = [it for it in lead if it[0] != "blank"]
            target = current["items"] if current is not None else root
            target.append((lead, stmt))
            pending = []
        else:
            path, is_aot = header_path(stmt)
            moved, rest = pull_banner_blocks(pending)
            intro = tidy_lines(carry + moved + rest)
            gap = bool(pending) and pending[-1][0] == "blank" and bool(intro) and intro[-1][1].strip() != ""
            current = {"path": path, "aot": is_aot, "header": stmt, "intro": intro, "gap": gap, "items": []}
            blocks.append(current)
            pending, carry = [], []
    leftover = tidy_lines(carry + pending)

    order = {name: (bi, ti) for bi, (_, names) in enumerate(CONFIG_LAYOUT) for ti, name in enumerate(names)}
    unknown = {}
    for blk in blocks:
        top = blk["path"][0]
        if top not in order and top not in unknown:
            unknown[top] = len(unknown)
    ranked = sorted(
        enumerate(blocks),
        key=lambda ib: (order[ib[1]["path"][0]][0], order[ib[1]["path"][0]][1], ib[0])
        if ib[1]["path"][0] in order else (len(CONFIG_LAYOUT) + unknown[ib[1]["path"][0]], 0, ib[0]),
    )

    def ensure_eol(s):
        return s if s.endswith("\n") else s + newline

    out = []
    for _, stmt in preamble:
        out.append(ensure_eol(stmt))
    if preamble:
        out.append(newline)
    for lead, stmt in root:
        out.extend(ensure_eol(b) for _, b in lead)
        out.append(ensure_eol(stmt))
    if root:
        out.append(newline)
    last_label = None
    for _, blk in ranked:
        top = blk["path"][0]
        label = next((lab for lab, names in CONFIG_LAYOUT if top in names), top.replace("_", " "))
        if label != last_label:
            if out and not out[-1].isspace():
                out.append(newline)
            out.append(banner_line(label, newline))
            last_label = label
        elif out:
            out.append(newline)
        out.extend(ensure_eol(b) for _, b in blk["intro"])
        if blk["gap"]:
            out.append(newline)
        out.append(ensure_eol(blk["header"]))
        for lead, stmt in blk["items"]:
            out.extend(ensure_eol(b) if kind != "blank" else newline for kind, b in lead)
            out.append(ensure_eol(stmt))
    if leftover:
        out.append(newline)
        out.extend(ensure_eol(b) if kind != "blank" else newline for kind, b in leftover)
    result = "".join(out)
    if tomlkit.parse(result).unwrap() != tomlkit.parse(text).unwrap():
        raise ValueError("the rebuilt file would not contain the same settings")
    return result


# ------------------------------------------------------------------ diff by section
def _section_title(line):
    """`[a.b]` or `[[a]]` when the line is a TOML table header, else None."""
    if not line.lstrip().startswith("["):
        return None
    try:
        path, is_array = header_path(line)
    except (tomlkit.exceptions.TOMLKitError, ValueError):
        return None
    if not path:
        return None
    return ("[[" if is_array else "[") + ".".join(map(str, path)) + ("]]" if is_array else "]")


def group_diff_by_section(diff, new_text):
    """Split unified-diff hunks by the TOML section containing their new lines."""
    section_by_line = {}
    section = "Top-level settings"
    for line_number, line in enumerate(new_text.splitlines(), start=1):
        section = _section_title(line) or section
        section_by_line[line_number] = section

    groups = {}
    lines = diff.splitlines(keepends=True)
    index = 0
    while index < len(lines):
        if not lines[index].startswith("@@ "):
            index += 1
            continue
        hunk = [lines[index]]
        match = re.search(r"\+(\d+)(?:,\d+)?", lines[index])
        new_start = int(match.group(1)) if match else 1
        index += 1
        while index < len(lines) and not lines[index].startswith("@@ "):
            if not lines[index].startswith(("--- ", "+++ ")):
                hunk.append(lines[index])
            index += 1

        current_section = section_by_line.get(max(1, new_start), section)
        current_line = max(1, new_start)
        section_hunks = {}
        for diff_line in hunk[1:]:
            prefix = diff_line[:1]
            content = diff_line[1:] if prefix in (" ", "+", "-") else diff_line
            if prefix in (" ", "+"):
                current_section = section_by_line.get(current_line, current_section)
                current_line += 1
            elif prefix == "-" and _section_title(content):
                current_section = "Removed " + _section_title(content)
            section_hunks.setdefault(current_section, []).append(diff_line)
        for name, section_lines in section_hunks.items():
            groups.setdefault(name, []).extend([hunk[0], *section_lines, "\n"])
    return groups
