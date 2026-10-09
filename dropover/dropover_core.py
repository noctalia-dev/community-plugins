#!/usr/bin/env python3
import sys
import os
import json
import urllib.parse
import subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

def get_shelf_file():
    if os.environ.get("DROPOVER_SHELF_FILE"):
        return os.environ.get("DROPOVER_SHELF_FILE")
    state_home = os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state"))
    standard_file = os.path.join(state_home, "noctalia", "plugins", "data", "pyrider3", "dropover", "shelf.json")
    old_file = os.path.expanduser("~/.config/noctalia/plugins/dropover/shelf.json")
    if not os.path.exists(standard_file) and os.path.exists(old_file):
        try:
            os.makedirs(os.path.dirname(standard_file), exist_ok=True)
            import shutil
            shutil.copy2(old_file, standard_file)
        except Exception:
            pass
    return standard_file

SHELF_FILE = get_shelf_file()

def load_shelf():
    if not os.path.exists(SHELF_FILE):
        return []
    try:
        with open(SHELF_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            if isinstance(data, list):
                return data
            return []
    except Exception:
        return []

def save_shelf(items):
    os.makedirs(os.path.dirname(SHELF_FILE), exist_ok=True)
    with open(SHELF_FILE, "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=2)

def add_files(paths):
    items = load_shelf()
    added = 0
    for p in paths:
        p = os.path.abspath(os.path.expanduser(p))
        if os.path.exists(p) and p not in items:
            items.append(p)
            added += 1
    if added > 0:
        save_shelf(items)
    return added

def remove_file(path):
    items = load_shelf()
    path = os.path.abspath(os.path.expanduser(path))
    if path in items:
        items.remove(path)
        save_shelf(items)
        return True
    return False

def clear_shelf():
    save_shelf([])

def copy_to_clipboard(paths):
    if not paths:
        return
    uris = []
    for p in paths:
        p = os.path.abspath(os.path.expanduser(p))
        if os.path.exists(p):
            uris.append(f"file://{p}")
    if uris:
        payload = "\r\n".join(uris) + "\r\n"
        proc = subprocess.Popen(["wl-copy", "-t", "text/uri-list"], stdin=subprocess.PIPE)
        proc.communicate(input=payload.encode("utf-8"))

def add_from_clipboard():
    try:
        res = subprocess.run(["wl-paste", "-t", "text/uri-list"], capture_output=True, text=True, timeout=2)
        if res.returncode == 0 and res.stdout:
            lines = res.stdout.strip().splitlines()
            paths = []
            for line in lines:
                line = line.strip()
                if line.startswith("file://"):
                    p = urllib.parse.unquote(line[7:])
                    paths.append(p)
            return add_files(paths)
    except Exception as e:
        sys.stderr.write(f"Clipboard error: {e}\n")
    return 0

def format_size(bytes_size):
    if bytes_size < 1024:
        return f"{bytes_size} B"
    elif bytes_size < 1024 * 1024:
        return f"{bytes_size / 1024:.1f} KB"
    elif bytes_size < 1024 * 1024 * 1024:
        return f"{bytes_size / (1024 * 1024):.1f} MB"
    else:
        return f"{bytes_size / (1024 * 1024 * 1024):.2f} GB"

def get_glyph_for_ext(ext):
    ext = ext.lower().lstrip(".")
    if ext in ["png", "jpg", "jpeg", "webp", "gif", "bmp", "svg"]:
        return "photo"
    elif ext in ["mp4", "mkv", "webm", "avi", "mov"]:
        return "video"
    elif ext in ["mp3", "flac", "wav", "ogg", "m4a", "aac"]:
        return "music"
    elif ext in ["zip", "tar", "gz", "bz2", "xz", "7z", "rar", "zst"]:
        return "file-zip"
    elif ext in ["py", "sh", "lua", "luau", "js", "ts", "rs", "c", "cpp", "h", "html", "css", "json", "toml", "kdl"]:
        return "code"
    elif ext in ["pdf", "doc", "docx", "txt", "md", "csv", "xlsx"]:
        return "file-text"
    else:
        return "file"

def list_items():
    items = load_shelf()
    result = []
    for p in items:
        exists = os.path.exists(p)
        name = os.path.basename(p)
        size_str = ""
        is_dir = False
        ext = ""
        if exists:
            is_dir = os.path.isdir(p)
            try:
                if is_dir:
                    size_str = "文件夹"
                    glyph = "folder"
                else:
                    size_bytes = os.path.getsize(p)
                    size_str = format_size(size_bytes)
                    _, ext = os.path.splitext(p)
                    glyph = get_glyph_for_ext(ext)
            except Exception:
                size_str = "未知"
                glyph = "file"
        else:
            size_str = "文件已不存在"
            glyph = "alert-circle"

        result.append({
            "path": p,
            "name": name,
            "size": size_str,
            "exists": exists,
            "glyph": glyph,
            "is_dir": is_dir
        })
    return result

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "list":
        print(json.dumps(list_items(), ensure_ascii=False))
    elif cmd == "add":
        count = add_files(sys.argv[2:])
        print(count)
    elif cmd == "remove":
        if len(sys.argv) > 2:
            ok = remove_file(sys.argv[2])
            print("ok" if ok else "not found")
    elif cmd == "clear":
        clear_shelf()
        print("cleared")
    elif cmd == "copy-one":
        if len(sys.argv) > 2:
            copy_to_clipboard([sys.argv[2]])
            print("copied")
    elif cmd == "copy-all":
        items = load_shelf()
        copy_to_clipboard(items)
        print(f"copied {len(items)}")
    elif cmd == "from-clipboard":
        count = add_from_clipboard()
        print(count)
    elif cmd == "pick":
        try:
            res = subprocess.run(["zenity", "--file-selection", "--multiple", "--separator=|", "--title=选择存入 Dropover 的文件"], capture_output=True, text=True)
            if res.returncode == 0 and res.stdout.strip():
                paths = res.stdout.strip().split("|")
                added = add_files(paths)
                print(added)
        except Exception as e:
            sys.stderr.write(f"Zenity error: {e}\n")
