#!/usr/bin/env python3
"""
Wallpaper Helper for Wallpaper Deck (Noctalia v5).
Scans wallpaper folders, caches Material 3 palettes via matugen,
computes dimensions, file sizes, and color-wheel hue coordinates.
Features a high-speed two-pass architecture: instantly yields all files, then refines
color palettes in the background with multi-threaded workers.
"""

import sys
import os
import json
import hashlib
import struct
import subprocess
import colorsys
import threading
from concurrent.futures import ThreadPoolExecutor
try:
    from PIL import Image
    HAS_PIL = True
except ImportError:
    Image = None
    HAS_PIL = False

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".gif"}
ALL_EXTS = IMAGE_EXTS

FALLBACK_M3 = {
    "primary": "#80a9ff",
    "secondary": "#bfc6dc",
    "tertiary": "#dfbde4",
    "primary_container": "#20468a",
    "surface_container_highest": "#33353b",
    "source_color": "#4285f4",
}

def get_ext(path):
    _, ext = os.path.splitext(path)
    return ext.lower()

def calc_hue_key(hex_color):
    try:
        h = hex_color.lstrip("#")
        if len(h) != 6:
            return 3.0
        r, g, b = [int(h[i:i+2], 16) / 255.0 for i in (0, 2, 4)]
        hue, light, sat = colorsys.rgb_to_hls(r, g, b)
        if sat < 0.12 or hex_color.lower() in ("#4285f4", "#000000", "#ffffff"):
            return 1.0 + light
        return (hue + 0.035) % 1.0
    except Exception:
        return 3.0

def fast_image_size(path):
    """Extract width and height from image header quickly."""
    try:
        with open(path, "rb") as f:
            head = f.read(32)
            if head[:8] == b"\x89PNG\r\n\x1a\n":
                return struct.unpack(">II", head[16:24])
            if head[:6] in (b"GIF87a", b"GIF89a"):
                return struct.unpack("<HH", head[6:10])
            if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
                kind = head[12:16]
                if kind == b"VP8 ":
                    w, h = struct.unpack("<HH", head[26:30])
                    return w & 0x3FFF, h & 0x3FFF
                if kind == b"VP8L":
                    bits = int.from_bytes(head[21:25], "little")
                    return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
                if kind == b"VP8X":
                    return int.from_bytes(head[24:27], "little") + 1, int.from_bytes(head[27:30], "little") + 1
            if head[:2] == b"\xff\xd8":
                f.seek(2)
                while True:
                    b = f.read(1)
                    if not b:
                        break
                    if b != b"\xff":
                        continue
                    marker = f.read(1)
                    while marker == b"\xff":
                        marker = f.read(1)
                    if not marker:
                        break
                    m = marker[0]
                    if m in (0xD9, 0xDA):
                        break
                    if m == 0x01 or 0xD0 <= m <= 0xD7:
                        continue
                    length = struct.unpack(">H", f.read(2))[0]
                    if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC):
                        f.read(1)
                        h, w = struct.unpack(">HH", f.read(4))
                        return w, h
                    f.seek(length - 2, 1)
    except Exception:
        pass
    return 0, 0

def make_thumbnails(file_path, thumb_dir):
    os.makedirs(thumb_dir, exist_ok=True)
    file_hash = hashlib.md5(file_path.encode("utf-8")).hexdigest()[:16]
    card_thumb = os.path.join(thumb_dir, f"{file_hash}_card.webp")
    screen_thumb = os.path.join(thumb_dir, f"{file_hash}_screen.webp")

    src = file_path
    if not src or not os.path.isfile(src):
        return card_thumb, screen_thumb

    try:
        need_card = not os.path.isfile(card_thumb) or os.path.getsize(card_thumb) == 0
        need_screen = not os.path.isfile(screen_thumb) or os.path.getsize(screen_thumb) == 0
        if need_card or need_screen:
            if HAS_PIL and Image is not None:
                with Image.open(src) as img:
                    if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
                        img = img.convert("RGBA")
                    else:
                        img = img.convert("RGB")
                    
                    if need_card:
                        c = img.copy()
                        c.thumbnail((420, 280), Image.Resampling.LANCZOS)
                        c.save(card_thumb, "WEBP", quality=78)

                    if need_screen:
                        s = img.copy()
                        s.thumbnail((1920, 1080), Image.Resampling.LANCZOS)
                        s.save(screen_thumb, "WEBP", quality=82)
            else:
                if need_card:
                    subprocess.run(
                        ["ffmpeg", "-y", "-i", src, "-vf", "scale=420:280:force_original_aspect_ratio=decrease", "-q:v", "78", card_thumb],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False, timeout=8
                    )
                if need_screen:
                    subprocess.run(
                        ["ffmpeg", "-y", "-i", src, "-vf", "scale=1920:1080:force_original_aspect_ratio=decrease", "-q:v", "82", screen_thumb],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False, timeout=8
                    )
    except Exception:
        pass

    return (card_thumb if os.path.isfile(card_thumb) else src,
            screen_thumb if os.path.isfile(screen_thumb) else src)

def extract_matugen_palette(image_path):
    cmd = [
        "matugen", "image", image_path,
        "--source-color-index", "0",
        "--dry-run", "-j", "hex", "-q"
    ]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=12)
        if res.returncode == 0 and res.stdout:
            data = json.loads(res.stdout)
            colors = data.get("colors", {})
            def get_col(role):
                c = colors.get(role, {})
                return (c.get("default") or c.get("dark") or {}).get("color", "")
            
            p = get_col("primary")
            s = get_col("secondary")
            t = get_col("tertiary")
            pc = get_col("primary_container")
            sch = get_col("surface_container_highest") or get_col("surface_container") or get_col("surface")
            sc = get_col("source_color") or p
            if p and s:
                return {
                    "primary": p,
                    "secondary": s,
                    "tertiary": t or s,
                    "primary_container": pc or p,
                    "surface_container_highest": sch or "#33353b",
                    "source_color": sc or p,
                }
    except Exception:
        pass
    return None

def process_single(file_path, thumb_dir, cache, dir_path=None, rel_dir=None, is_subdir=None):
    name = os.path.basename(file_path)
    ext = get_ext(file_path)
    if ext not in ALL_EXTS:
        return None

    try:
        st = os.stat(file_path)
        mtime = int(st.st_mtime)
        size = st.st_size
    except OSError:
        return None

    cached = cache.get(file_path) if cache else None
    if (cached and cached.get("mtime") == mtime and cached.get("size") == size
            and cached.get("colors") and cached.get("preview")
            and os.path.isfile(cached.get("preview", ""))
            and os.path.isfile(cached.get("thumb", ""))
            and cached.get("thumb") != file_path):
        return cached

    kind = "IMG"
    inspect_image = file_path

    w = cached.get("width", 0) if cached else 0
    h = cached.get("height", 0) if cached else 0
    if (w == 0 or h == 0) and inspect_image and os.path.isfile(inspect_image):
        w, h = fast_image_size(inspect_image)

    colors = cached.get("colors") if (cached and cached.get("colors")) else None
    if not colors and inspect_image and os.path.isfile(inspect_image):
        colors = extract_matugen_palette(inspect_image)

    if not colors:
        colors = dict(FALLBACK_M3)

    source_color = colors.get("source_color", "#4285f4")
    hue_key = calc_hue_key(source_color)
    base_name = os.path.splitext(name)[0]
    res_str = f"{w} × {h}" if (w > 0 and h > 0) else ""
    if size >= 1048576:
        size_str = f"{size / 1048576.0:.1f} MB"
    else:
        size_str = f"{int(size / 1024.0)} KB"

    card_thumb, screen_thumb = make_thumbnails(file_path, thumb_dir)

    if rel_dir is None:
        rel_dir = ""
        is_subdir = False
        if dir_path:
            try:
                rel = os.path.relpath(os.path.dirname(file_path), dir_path)
                if rel and rel != ".":
                    is_subdir = True
                    rel_dir = rel
            except Exception:
                pass
    else:
        is_subdir = bool(is_subdir)

    record = {
        "path": file_path,
        "name": name,
        "base": base_name,
        "lowerName": name.lower(),
        "ext": ext.lstrip(".").upper(),
        "kind": kind,
        "mtime": mtime,
        "size": size,
        "sizeStr": size_str,
        "width": w,
        "height": h,
        "res": res_str,
        "thumb": card_thumb,
        "preview": screen_thumb,
        "colors": colors,
        "sourceColor": source_color,
        "hueKey": hue_key,
        "isSubdir": is_subdir,
        "relDir": rel_dir,
    }
    return record

def compute_file_rel_dir(p, file_to_root, total_roots):
    root_info = file_to_root.get(p)
    if not root_info:
        return "", False
    root_path, root_name, is_primary = root_info
    try:
        rel = os.path.relpath(os.path.dirname(p), root_path)
    except Exception:
        rel = ""
    has_sub = bool(rel and rel != ".")
    if total_roots > 1:
        if is_primary:
            return (rel, True) if has_sub else ("", False)
        else:
            combined = f"{root_name}/{rel}" if has_sub else root_name
            return combined, True
    else:
        return (rel, True) if has_sub else ("", False)

def scan_directory(dir_path, cache_file, thumb_dir, max_matugen=24, deck_limit=600):
    cache = {}
    if os.path.isfile(cache_file):
        try:
            with open(cache_file, "r", encoding="utf-8") as f:
                loaded = json.load(f)
                if isinstance(loaded, dict):
                    cache = loaded
                elif isinstance(loaded, list):
                    cache = {item.get("path"): item for item in loaded if isinstance(item, dict) and item.get("path")}
        except Exception:
            cache = {}

    raw_dirs = []
    if isinstance(dir_path, str):
        if "|||" in dir_path:
            raw_dirs = [d.strip() for d in dir_path.split("|||") if d.strip()]
        else:
            raw_dirs = [dir_path]
    elif isinstance(dir_path, (list, tuple)):
        raw_dirs = list(dir_path)
    else:
        raw_dirs = [str(dir_path)]

    dir_roots = []
    seen_roots = set()
    for idx, d in enumerate(raw_dirs):
        exp = os.path.realpath(os.path.expanduser(d))
        if exp not in seen_roots and os.path.isdir(exp):
            seen_roots.add(exp)
            r_name = os.path.basename(exp.rstrip("/\\"))
            dir_roots.append((exp, r_name, idx == 0))

    all_files = []
    file_to_root = {}
    seen_files = set()

    for exp_path, r_name, is_primary in dir_roots:
        for root, dirs, files in os.walk(exp_path):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for f in sorted(files):
                if not f.startswith("."):
                    ext = get_ext(f)
                    if ext in ALL_EXTS:
                        full_p = os.path.join(root, f)
                        real_p = os.path.realpath(full_p)
                        if real_p not in seen_files:
                            seen_files.add(real_p)
                            all_files.append(full_p)
                            file_to_root[full_p] = (exp_path, r_name, is_primary)

    all_files.sort(key=lambda p: os.path.basename(p).lower())

    results = []
    need_process = []
    total_roots = len(dir_roots)

    # First pass: load cached items or mark for processing
    for p in all_files:
        cached = cache.get(p)
        try:
            st = os.stat(p)
            mtime = int(st.st_mtime)
            size = st.st_size
            if (cached and cached.get("mtime") == mtime and cached.get("size") == size
                    and cached.get("preview") and os.path.isfile(cached.get("preview", ""))
                    and cached.get("thumb") and cached.get("thumb") != p
                    and os.path.isfile(cached.get("thumb", ""))):
                # Ensure precomputed fields exist in cached records and update relDir
                if "lowerName" not in cached:
                    cached["lowerName"] = cached.get("name", "").lower()
                if "base" not in cached:
                    cached["base"] = os.path.splitext(cached.get("name", ""))[0]
                rel_d, is_sub = compute_file_rel_dir(p, file_to_root, total_roots)
                cached["isSubdir"] = is_sub
                cached["relDir"] = rel_d
                results.append(cached)
            else:
                need_process.append(p)
        except OSError:
            pass

    # Process pending items in batches with multi-threading
    if need_process:
        batch = need_process[:max_matugen] if max_matugen > 0 else need_process
        rest = need_process[max_matugen:] if max_matugen > 0 else []

        cache_lock = threading.Lock()
        def worker(p):
            rel_d, is_sub = compute_file_rel_dir(p, file_to_root, total_roots)
            root_info = file_to_root.get(p)
            r_path = root_info[0] if root_info else None
            res = process_single(p, thumb_dir, cache, r_path, rel_d, is_sub)
            if res:
                with cache_lock:
                    results.append(res)
                    cache[res["path"]] = res
            return res

        with ThreadPoolExecutor(max_workers=8) as executor:
            list(executor.map(worker, batch))

        # Fill baseline for any remaining so the user sees everything immediately
        for p in rest:
            ext = get_ext(p)
            try:
                st = os.stat(p)
                sz = st.st_size
                name_b = os.path.basename(p)
                rel_d, is_sub = compute_file_rel_dir(p, file_to_root, total_roots)
                w, h = fast_image_size(p)
                res_str = f"{w} × {h}" if (w > 0 and h > 0) else ""
                rec = {
                    "path": p,
                    "name": name_b,
                    "base": os.path.splitext(name_b)[0],
                    "lowerName": name_b.lower(),
                    "ext": ext.lstrip(".").upper(),
                    "kind": "IMG",
                    "mtime": int(st.st_mtime),
                    "size": sz,
                    "sizeStr": f"{sz / 1048576.0:.1f} MB" if sz >= 1048576 else f"{int(sz / 1024.0)} KB",
                    "width": w,
                    "height": h,
                    "res": res_str,
                    "thumb": p,
                    "preview": p,
                    "colors": dict(FALLBACK_M3),
                    "sourceColor": "#4285f4",
                    "hueKey": 3.0,
                    "isSubdir": is_sub,
                    "relDir": rel_d,
                }
                results.append(rec)
            except OSError:
                pass

        try:
            os.makedirs(os.path.dirname(cache_file), exist_ok=True)
            with open(cache_file, "w", encoding="utf-8") as f:
                json.dump(cache, f)
        except Exception:
            pass

    # Always sort alphabetically by default
    results.sort(key=lambda x: x.get("lowerName", x.get("name", "").lower()))

    # Build deck bounded by deck_limit (ensuring all favorites are retained)
    fav_set = set()
    fav_file = os.path.join(os.path.dirname(cache_file), "favorites.json")
    if os.path.isfile(fav_file):
        try:
            with open(fav_file, "r", encoding="utf-8") as f:
                fav_data = json.load(f)
                if isinstance(fav_data, dict):
                    fav_set = {k for k, v in fav_data.items() if v}
                elif isinstance(fav_data, list):
                    fav_set = set(fav_data)
        except Exception:
            pass

    if deck_limit <= 0 or len(results) <= deck_limit:
        selected_deck = results
    else:
        # Prioritize favorites first, then fill remainder
        selected_deck = []
        fav_items = []
        other_items = []
        for it in results:
            if it.get("name") in fav_set:
                fav_items.append(it)
            else:
                other_items.append(it)
        selected_deck.extend(fav_items)
        remaining_slots = max(0, deck_limit - len(fav_items))
        selected_deck.extend(other_items[:remaining_slots])
        # Re-sort deck alphabetically
        selected_deck.sort(key=lambda x: x.get("lowerName", x.get("name", "").lower()))

    # Produce a clean, lightweight deck to prevent Luau CPU budget limits
    clean_deck = []
    for it in selected_deck:
        p = it["path"]
        name_b = it.get("name", os.path.basename(p))
        rec = {
            "path": p,
            "name": name_b,
            "mtime": it.get("mtime", 0),
            "size": it.get("size", 0),
            "res": it.get("res", ""),
            "ext": it.get("ext", get_ext(p).lstrip(".").upper()),
        }
        if it.get("isSubdir"):
            rec["isSubdir"] = True
        if it.get("relDir"):
            rec["relDir"] = it["relDir"]
        if it.get("thumb") and it["thumb"] != p and os.path.isfile(it["thumb"]):
            rec["thumb"] = it["thumb"]
        if it.get("preview") and it["preview"] != p and os.path.isfile(it["preview"]):
            rec["preview"] = it["preview"]
        colors = it.get("colors")
        if colors and isinstance(colors, dict) and colors.get("primary") != "#80a9ff":
            rec["colors"] = colors
            if it.get("sourceColor"):
                rec["sourceColor"] = it["sourceColor"]
            if it.get("hueKey") is not None:
                rec["hueKey"] = it["hueKey"]
        clean_deck.append(rec)

    deck_path = os.path.join(os.path.dirname(cache_file), "deck.json")
    try:
        os.makedirs(os.path.dirname(cache_file), exist_ok=True)
        with open(deck_path, "w", encoding="utf-8") as f:
            json.dump(clean_deck, f, separators=(",", ":"))
    except Exception:
        pass

    return {
        "status": "ok",
        "total": len(results),
        "count": len(clean_deck),
        "deckFile": deck_path
    }

def run_wheel_listener(pid_file):
    import fcntl, glob, select, time, struct, signal, atexit

    def cleanup():
        try:
            if os.path.exists(pid_file):
                os.remove(pid_file)
        except Exception:
            pass

    def sig_handler(*_args):
        cleanup()
        sys.exit(0)

    signal.signal(signal.SIGTERM, sig_handler)
    signal.signal(signal.SIGINT, sig_handler)
    atexit.register(cleanup)

    EV_REL = 0x02
    REL_WHEEL = 0x08
    REL_HWHEEL = 0x06
    REL_WHEEL_HI_RES = 11

    fds = []
    pid_written = False
    try:
        for p in sorted(glob.glob("/dev/input/event*")):
            try:
                fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK)
                buf = bytearray(8)
                fcntl.ioctl(fd, 0x80084520 + EV_REL, buf)
                mask = int.from_bytes(buf, "little")
                if mask & ((1 << REL_WHEEL) | (1 << REL_HWHEEL)):
                    fds.append(fd)
                else:
                    os.close(fd)
            except Exception:
                pass

        if not fds:
            return

        try:
            os.makedirs(os.path.dirname(os.path.abspath(pid_file)), exist_ok=True)
            with open(pid_file, "w") as f:
                f.write(str(os.getpid()))
            pid_written = True
        except Exception:
            pass

        last_trigger = 0.0
        COOLDOWN = 0.06

        while True:
            if not os.path.exists(pid_file):
                break

            r, _, _ = select.select(fds, [], [], 0.5)
            for fd in r:
                try:
                    while True:
                        data = os.read(fd, 24)
                        if len(data) < 24:
                            break
                        _, _, ev_type, ev_code, ev_val = struct.unpack("QQHHi", data)
                        if ev_type == EV_REL and ev_code in (REL_WHEEL, REL_WHEEL_HI_RES):
                            now = time.time()
                            if now - last_trigger >= COOLDOWN:
                                last_trigger = now
                                if ev_val > 0:
                                    subprocess.run(["wtype", "-k", "Left"], check=False)
                                elif ev_val < 0:
                                    subprocess.run(["wtype", "-k", "Right"], check=False)
                        elif ev_type == EV_REL and ev_code == REL_HWHEEL:
                            now = time.time()
                            if now - last_trigger >= COOLDOWN:
                                last_trigger = now
                                if ev_val < 0:
                                    subprocess.run(["wtype", "-k", "Left"], check=False)
                                elif ev_val > 0:
                                    subprocess.run(["wtype", "-k", "Right"], check=False)
                except (BlockingIOError, OSError):
                    pass
    finally:
        for fd in fds:
            try:
                os.close(fd)
            except Exception:
                pass
        if pid_written:
            cleanup()

def main():
    if len(sys.argv) < 2:
        print("Usage: wallpaper_helper.py scan DIR CACHE_FILE THUMB_DIR [LIMIT]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "scan":
        dir_path = os.path.expanduser(sys.argv[2])
        cache_file = os.path.expanduser(sys.argv[3])
        thumb_dir = os.path.expanduser(sys.argv[4])
        max_matugen = int(sys.argv[5]) if len(sys.argv) > 5 else 24
        deck_limit = int(sys.argv[6]) if len(sys.argv) > 6 else 600
        summary = scan_directory(dir_path, cache_file, thumb_dir, max_matugen, deck_limit)
        print(json.dumps(summary))
    elif cmd == "single":
        file_path = os.path.expanduser(sys.argv[2])
        thumb_dir = os.path.expanduser(sys.argv[3])
        rec = process_single(file_path, thumb_dir, {})
        print(json.dumps(rec))
    elif cmd == "wheel":
        pid_file = os.path.expanduser(sys.argv[2])
        run_wheel_listener(pid_file)

if __name__ == "__main__":
    main()
