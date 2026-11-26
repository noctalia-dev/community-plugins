#!/usr/bin/env python3
"""Headless audio and library backend for the Flexa Noctalia plugin.

Owns a headless `mpv` process via its JSON IPC socket, scans the configured
music directory, caches metadata/cover artwork, performs search/filtering/paging
in Python so Luau UI callbacks remain well within strict CPU budgets, and
streams small ASCII-safe JSON notifications on stdout for `service.luau`.
"""

import hashlib
import json
import os
import random
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

AUDIO_EXTS = {
    ".mp3",
    ".flac",
    ".ogg",
    ".opus",
    ".m4a",
    ".wav",
    ".aac",
    ".wma",
    ".alac",
    ".aiff",
    ".wv",
    ".ape",
}

COVER_NAMES = (
    "cover.jpg",
    "cover.jpeg",
    "cover.png",
    "cover.webp",
    "folder.jpg",
    "folder.jpeg",
    "folder.png",
    "album.jpg",
    "album.png",
    "front.jpg",
    "front.png",
    "artwork.jpg",
    "artwork.png",
)

PAGE_SIZE = 25

FFPROBE = shutil.which("ffprobe")
FFMPEG = shutil.which("ffmpeg")
MPV = shutil.which("mpv") or "mpv"


_emit_lock = threading.Lock()


def emit(obj: dict) -> None:
    """Write a single ASCII-safe JSON line to stdout for Noctalia's runStream reader."""
    line = json.dumps(obj, ensure_ascii=True, separators=(",", ":")) + "\n"
    try:
        with _emit_lock:
            sys.stdout.write(line)
            sys.stdout.flush()
    except BrokenPipeError:
        os._exit(0)


def parse_filename(stem: str, folder_name: str) -> tuple[str, str]:
    """Best-effort Artist - Title extraction from a filename."""
    cleaned = re.sub(r"^\d{1,3}[\s._-]+", "", stem).strip() or stem
    if " - " in cleaned:
        left, right = cleaned.split(" - ", 1)
        left, right = left.strip(), right.strip()
        if left and right:
            return right, left
    return cleaned, (folder_name or "Unknown Artist")


def find_folder_cover(dirpath: Path) -> str:
    """Look for a cover image file in the track's folder."""
    try:
        entries = {e.name.lower(): str(e) for e in dirpath.iterdir() if e.is_file()}
    except OSError:
        return ""
    for candidate in COVER_NAMES:
        if candidate in entries:
            return entries[candidate]
    return ""


def probe_track(path: str, covers_dir: Path, extract_art: bool) -> dict:
    """Read audio tags/duration via ffprobe and extract embedded cover art."""
    meta: dict = {}
    if FFPROBE:
        try:
            proc = subprocess.run(
                [
                    FFPROBE,
                    "-v",
                    "quiet",
                    "-print_format",
                    "json",
                    "-show_format",
                    "-show_streams",
                    path,
                ],
                capture_output=True,
                text=True,
                timeout=4,
            )
            if proc.returncode == 0 and proc.stdout:
                data = json.loads(proc.stdout)
                fmt = data.get("format") or {}
                tags = fmt.get("tags") or {}
                lower_tags = {str(k).lower(): str(v).strip() for k, v in tags.items() if v}
                if lower_tags.get("title"):
                    meta["title"] = lower_tags["title"]
                if lower_tags.get("artist") or lower_tags.get("album_artist"):
                    meta["artist"] = lower_tags.get("artist") or lower_tags.get("album_artist")
                if lower_tags.get("album"):
                    meta["album"] = lower_tags["album"]
                dur = fmt.get("duration")
                if dur is not None:
                    try:
                        meta["duration"] = float(dur)
                    except (TypeError, ValueError):
                        pass

                has_attached_pic = any(
                    (s.get("disposition") or {}).get("attached_pic") == 1
                    for s in (data.get("streams") or [])
                )
                if extract_art and has_attached_pic and FFMPEG:
                    digest = hashlib.sha1(path.encode("utf-8", errors="replace")).hexdigest()[:20]
                    cover_file = covers_dir / f"{digest}.jpg"
                    if not cover_file.exists():
                        subprocess.run(
                            [
                                FFMPEG,
                                "-y",
                                "-v",
                                "quiet",
                                "-i",
                                path,
                                "-an",
                                "-vframes",
                                "1",
                                "-vf",
                                "scale=256:256:force_original_aspect_ratio=increase,crop=256:256",
                                str(cover_file),
                            ],
                            capture_output=True,
                            timeout=5,
                        )
                    if cover_file.exists() and cover_file.stat().st_size > 0:
                        meta["coverPath"] = str(cover_file)
        except Exception:
            pass
    return meta


class FlexaBackend:
    """Manages mpv playback, music library scanning, paging, queue, and persistence."""

    def __init__(self, data_dir: Path) -> None:
        self.data_dir = data_dir
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.covers_dir = self.data_dir / "covers"
        self.covers_dir.mkdir(parents=True, exist_ok=True)

        pid = os.getpid()
        self._cleanup_stale_sockets()
        self.mpv_sock_path = self.data_dir / f"mpv.{pid}.sock"
        self.cmd_sock_path = self.data_dir / f"cmd.{pid}.sock"
        self.startup_cfg_path = self.data_dir / "startup_config.json"
        self.meta_cache_path = self.data_dir / "meta_cache.json"
        self.session_path = self.data_dir / "session.json"
        self.view_path = self.data_dir / "view.json"

        self.lock = threading.RLock()
        self.running = True
        self.mpv_proc: subprocess.Popen | None = None
        self.mpv_sock: socket.socket | None = None
        self.req_id = 1

        self.music_dir = ""
        self.recursive = True
        self.extract_artwork = True
        self.remember_session = True
        self.default_volume = 80

        self.tracks: list[dict] = []
        self.track_by_id: dict[str, dict] = {}
        self.folders: list[tuple[str, int]] = []
        self.favorites: list[str] = []
        self.favorite_set: set[str] = set()

        self.queue: list[str] = []
        self.queue_index = -1
        self.shuffle = False
        self.repeat = "off"  # "off" | "all" | "one"

        self.current_track_id = ""
        self.playing = False
        self.paused = False
        self.pos = 0.0
        self.duration = 0.0
        self.volume = 80
        self.mute = False

        # View filter / pagination state owned in Python for O(1) Luau UI renders.
        self.view_tab = "all"  # "all" | "folders" | "queue" | "favorites"
        self.view_folder = ""
        self.view_query = ""
        self.view_offset = 0
        self.scanning = False
        self.lib_error: str | None = None

        self.meta_cache: dict[str, dict] = self._load_json(self.meta_cache_path, {})
        self.scan_token = 0
        self.last_pos_emit = 0.0
        self._load_session()

    def _load_json(self, path: Path, default):
        try:
            if path.exists():
                return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            pass
        return default

    def _save_json(self, path: Path, data) -> None:
        try:
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
            tmp.replace(path)
        except Exception:
            pass

    def _load_session(self) -> None:
        sess = self._load_json(self.session_path, {})
        favs = sess.get("favorites")
        if isinstance(favs, list):
            self.favorites = [str(x) for x in favs if isinstance(x, str)]
            self.favorite_set = set(self.favorites)
        if isinstance(sess.get("volume"), (int, float)):
            self.volume = max(0, min(100, int(sess["volume"])))
        if isinstance(sess.get("mute"), bool):
            self.mute = sess["mute"]
        if isinstance(sess.get("shuffle"), bool):
            self.shuffle = sess["shuffle"]
        if sess.get("repeat") in ("off", "all", "one"):
            self.repeat = sess["repeat"]
        if isinstance(sess.get("lastTrackId"), str):
            self.current_track_id = sess["lastTrackId"]

    def _save_session(self) -> None:
        with self.lock:
            payload = {
                "favorites": self.favorites,
                "volume": self.volume,
                "mute": self.mute,
                "shuffle": self.shuffle,
                "repeat": self.repeat,
                "lastTrackId": self.current_track_id,
            }
        self._save_json(self.session_path, payload)

    def _cleanup_stale_sockets(self) -> None:
        """Remove leftover cmd/mpv sockets belonging to dead backend PIDs."""
        for sock_file in self.data_dir.glob("*.sock"):
            m = re.match(r"^(?:cmd|mpv)\.(\d+)\.sock$", sock_file.name)
            if m:
                old_pid = int(m.group(1))
                try:
                    os.kill(old_pid, 0)
                    continue
                except ProcessLookupError:
                    pass
                except PermissionError:
                    continue
            elif sock_file.name not in ("cmd.sock", "mpv.sock"):
                continue
            try:
                sock_file.unlink(missing_ok=True)
            except Exception:
                pass

    def start(self) -> None:
        """Start mpv, command socket server, and emit ready notification."""
        self._start_mpv()
        ready_ev = threading.Event()
        threading.Thread(target=self._serve_cmd_socket, args=(ready_ev,), daemon=True).start()
        ready_ev.wait(timeout=2.0)
        emit({"type": "ready", "sock": str(self.cmd_sock_path)})
        cfg = self._load_json(self.startup_cfg_path, None)
        if isinstance(cfg, dict) and "dir" in cfg:
            self.scan(
                str(cfg.get("dir", "")),
                bool(cfg.get("recursive", True)),
                bool(cfg.get("extractArtwork", True)),
                int(cfg.get("defaultVolume", 80)),
                bool(cfg.get("remember", True)),
            )
        else:
            self.emit_view()
            self.emit_state()

    def stop(self) -> None:
        """Cleanly terminate mpv and remove IPC sockets."""
        self.running = False
        try:
            if self.mpv_sock:
                self.mpv_sock.close()
        except Exception:
            pass
        if self.mpv_proc and self.mpv_proc.poll() is None:
            try:
                self.mpv_proc.terminate()
                self.mpv_proc.wait(timeout=2)
            except Exception:
                try:
                    self.mpv_proc.kill()
                except Exception:
                    pass
        for sock_file in (self.mpv_sock_path, self.cmd_sock_path):
            try:
                sock_file.unlink(missing_ok=True)
            except Exception:
                pass

    def _start_mpv(self) -> None:
        self.mpv_sock_path.unlink(missing_ok=True)
        cmd = [
            MPV,
            "--no-video",
            "--idle=yes",
            "--really-quiet",
            "--no-terminal",
            "--audio-display=no",
            f"--volume={self.volume}",
            f"--mute={'yes' if self.mute else 'no'}",
            f"--input-ipc-server={self.mpv_sock_path}",
        ]
        self.mpv_proc = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        deadline = time.monotonic() + 5.0
        sock = None
        while time.monotonic() < deadline and self.running:
            if self.mpv_sock_path.exists():
                candidate = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                try:
                    candidate.connect(str(self.mpv_sock_path))
                    sock = candidate
                    break
                except OSError:
                    candidate.close()
            time.sleep(0.04)
        if sock is None:
            raise RuntimeError("Timed out waiting for mpv IPC socket")
        self.mpv_sock = sock

        for idx, prop in enumerate(
            ("time-pos", "duration", "pause", "volume", "mute", "metadata", "idle-active"),
            start=1,
        ):
            self._mpv_send(["observe_property", idx, prop])

        threading.Thread(target=self._read_mpv_events, daemon=True).start()

    def _mpv_send(self, command: list) -> None:
        with self.lock:
            if not self.mpv_sock:
                return
            self.req_id += 1
            msg = json.dumps({"command": command, "request_id": self.req_id}) + "\n"
            try:
                self.mpv_sock.sendall(msg.encode("utf-8"))
            except OSError:
                pass

    def _read_mpv_events(self) -> None:
        assert self.mpv_sock is not None
        buf = b""
        while self.running:
            try:
                chunk = self.mpv_sock.recv(4096)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    raw, buf = buf.split(b"\n", 1)
                    if not raw.strip():
                        continue
                    try:
                        msg = json.loads(raw.decode("utf-8", errors="replace"))
                    except Exception:
                        continue
                    self._handle_mpv_message(msg)
            except OSError:
                break
        if self.running:
            time.sleep(0.3)
            if self.running:
                self._start_mpv()

    def _handle_mpv_message(self, msg: dict) -> None:
        ev = msg.get("event")
        if ev == "property-change":
            name = msg.get("name")
            data = msg.get("data")
            state_changed = False
            meta_updated = False
            now = time.monotonic()
            with self.lock:
                if name == "time-pos":
                    val = float(data) if isinstance(data, (int, float)) else 0.0
                    self.pos = max(0.0, val)
                    if now - self.last_pos_emit >= 0.45:
                        self.last_pos_emit = now
                        state_changed = True
                elif name == "duration":
                    self.duration = float(data) if isinstance(data, (int, float)) else 0.0
                    state_changed = True
                elif name == "pause":
                    self.paused = bool(data)
                    state_changed = True
                elif name == "volume" and isinstance(data, (int, float)):
                    self.volume = max(0, min(100, int(round(data))))
                    state_changed = True
                elif name == "mute":
                    self.mute = bool(data)
                    state_changed = True
                elif name == "idle-active":
                    if data is True:
                        self.playing = False
                        self.paused = False
                        self.pos = 0.0
                    elif data is False:
                        self.playing = True
                    state_changed = True
                elif name == "metadata" and isinstance(data, dict):
                    cleaned = {str(k).lower(): str(v).strip() for k, v in data.items() if v}
                    if self.current_track_id in self.track_by_id:
                        t = self.track_by_id[self.current_track_id]
                        if cleaned.get("title"):
                            t["title"] = cleaned["title"]
                        if cleaned.get("artist") or cleaned.get("album_artist"):
                            t["artist"] = cleaned.get("artist") or cleaned.get("album_artist")
                        if cleaned.get("album"):
                            t["album"] = cleaned["album"]
                    state_changed = True
                    meta_updated = True
            if state_changed:
                self.emit_state()
            if meta_updated:
                self.emit_view()
        elif ev == "end-file":
            reason = msg.get("reason")
            if reason == "eof":
                self._on_track_finished()

    def _on_track_finished(self) -> None:
        with self.lock:
            if self.repeat == "one" and self.current_track_id:
                tid = self.current_track_id
            else:
                tid = self._pick_next_id(auto_advance=True)
        if tid:
            self.play_track(tid)
        else:
            with self.lock:
                self.playing = False
                self.paused = False
                self.pos = 0.0
            self.emit_state()

    def _pick_next_id(self, auto_advance: bool = False) -> str:
        if not self.queue:
            if not self.tracks:
                return ""
            self.queue = [t["id"] for t in self.tracks]
            self.queue_index = 0 if self.current_track_id not in self.queue else self.queue.index(self.current_track_id)

        if self.shuffle and len(self.queue) > 1:
            choices = [tid for tid in self.queue if tid != self.current_track_id]
            picked = random.choice(choices)
            self.queue_index = self.queue.index(picked)
            return picked

        next_idx = self.queue_index + 1
        if next_idx >= len(self.queue):
            if self.repeat == "all" or not auto_advance:
                next_idx = 0
            else:
                return ""
        self.queue_index = next_idx
        return self.queue[next_idx]

    def _pick_prev_id(self) -> str:
        if not self.queue:
            return ""
        prev_idx = self.queue_index - 1
        if prev_idx < 0:
            prev_idx = len(self.queue) - 1
        self.queue_index = prev_idx
        return self.queue[prev_idx]

    def _matches(self, track: dict, q: str) -> bool:
        if not q:
            return True
        hay = (
            f"{track.get('title', '')} {track.get('artist', '')} "
            f"{track.get('album', '')} {track.get('folder', '')}"
        ).lower()
        return q in hay

    def _filtered_track_ids(self, tab: str, folder: str, query: str) -> list[str]:
        q = query.strip().lower()
        out: list[str] = []
        if tab == "queue":
            for tid in self.queue:
                t = self.track_by_id.get(tid)
                if t and self._matches(t, q):
                    out.append(tid)
            return out
        for t in self.tracks:
            if tab == "favorites" and t["id"] not in self.favorite_set:
                continue
            if tab == "folders" and folder and t["folder"] != folder:
                continue
            if self._matches(t, q):
                out.append(t["id"])
        return out

    def _compact_track(self, t: dict, queue_idx: int | None = None) -> dict:
        row = {
            "id": t["id"],
            "title": t["title"],
            "artist": t["artist"],
            "ext": t["ext"],
            "folder": t["folder"],
            "duration": t.get("duration") or 0.0,
            "liked": t["id"] in self.favorite_set,
        }
        if queue_idx is not None:
            row["queueIdx"] = queue_idx
        return row

    def emit_state(self) -> None:
        with self.lock:
            t = self.track_by_id.get(self.current_track_id)
            payload = {
                "type": "state",
                "playing": self.playing,
                "paused": self.paused,
                "trackId": self.current_track_id,
                "title": t["title"] if t else "",
                "artist": t["artist"] if t else "",
                "album": t.get("album", "") if t else "",
                "ext": t.get("ext", "") if t else "",
                "folder": t.get("folder", "") if t else "",
                "coverPath": t.get("coverPath", "") if t else "",
                "liked": self.current_track_id in self.favorite_set,
                "pos": round(self.pos, 2),
                "duration": round(self.duration or (t.get("duration", 0.0) if t else 0.0), 2),
                "volume": self.volume,
                "mute": self.mute,
                "shuffle": self.shuffle,
                "repeatMode": self.repeat,
                "queueIndex": self.queue_index,
                "queueTotal": len(self.queue),
            }
        emit(payload)

    def emit_view(self) -> None:
        with self.lock:
            tab = self.view_tab
            folder = self.view_folder
            q = self.view_query.strip().lower()
            offset = max(0, self.view_offset)

            items: list[dict] = []
            matched = 0

            if tab == "folders" and not folder:
                matched_folders = [
                    {"name": fname, "count": cnt}
                    for fname, cnt in self.folders
                    if not q or q in fname.lower()
                ]
                matched = len(matched_folders)
                if offset >= matched and matched > 0:
                    offset = ((matched - 1) // PAGE_SIZE) * PAGE_SIZE
                    self.view_offset = offset
                items = matched_folders[offset : offset + PAGE_SIZE]
            elif tab == "queue":
                matched_rows: list[tuple[int, dict]] = []
                for idx, tid in enumerate(self.queue):
                    t = self.track_by_id.get(tid)
                    if t and self._matches(t, q):
                        matched_rows.append((idx, t))
                matched = len(matched_rows)
                if offset >= matched and matched > 0:
                    offset = ((matched - 1) // PAGE_SIZE) * PAGE_SIZE
                    self.view_offset = offset
                items = [self._compact_track(t, qi) for qi, t in matched_rows[offset : offset + PAGE_SIZE]]
            else:
                matched_tracks: list[dict] = []
                for t in self.tracks:
                    if tab == "favorites" and t["id"] not in self.favorite_set:
                        continue
                    if tab == "folders" and folder and t["folder"] != folder:
                        continue
                    if self._matches(t, q):
                        matched_tracks.append(t)
                matched = len(matched_tracks)
                if offset >= matched and matched > 0:
                    offset = ((matched - 1) // PAGE_SIZE) * PAGE_SIZE
                    self.view_offset = offset
                items = [self._compact_track(t) for t in matched_tracks[offset : offset + PAGE_SIZE]]

            payload = {
                "dir": self.music_dir,
                "scanning": self.scanning,
                "error": self.lib_error,
                "total": len(self.tracks),
                "matched": matched,
                "queueTotal": len(self.queue),
                "favTotal": len(self.favorites),
                "tab": tab,
                "folder": folder,
                "query": self.view_query,
                "offset": offset,
                "pageSize": PAGE_SIZE,
                "items": items,
            }
        self._save_json(self.view_path, payload)
        emit(
            {
                "type": "view",
                "path": str(self.view_path),
                "scanning": payload["scanning"],
                "error": payload["error"],
                "total": payload["total"],
            }
        )

    def scan(self, music_dir: str, recursive: bool, extract_artwork: bool, default_vol: int, remember: bool) -> None:
        with self.lock:
            self.scan_token += 1
            token = self.scan_token
            self.music_dir = os.path.expanduser(music_dir.strip()) if music_dir else ""
            self.recursive = recursive
            self.extract_artwork = extract_artwork
            self.default_volume = max(0, min(100, int(default_vol)))
            self.remember_session = remember
            if not remember:
                self.volume = self.default_volume
                self._mpv_send(["set_property", "volume", self.volume])

        if not self.music_dir:
            with self.lock:
                self.tracks = []
                self.track_by_id = {}
                self.folders = []
                self.scanning = False
                self.lib_error = "no_dir"
            self.emit_view()
            return

        root = Path(self.music_dir)
        if not root.is_dir():
            with self.lock:
                self.tracks = []
                self.track_by_id = {}
                self.folders = []
                self.scanning = False
                self.lib_error = "missing_dir"
            self.emit_view()
            return

        with self.lock:
            self.scanning = True
            self.lib_error = None
        self.emit_view()

        found_files: list[Path] = []
        folder_covers: dict[str, str] = {}
        try:
            if recursive:
                for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
                    dirnames.sort(key=str.lower)
                    dp = Path(dirpath)
                    for fname in sorted(filenames, key=str.lower):
                        fp = dp / fname
                        if fp.suffix.lower() in AUDIO_EXTS:
                            found_files.append(fp)
            else:
                for entry in sorted(root.iterdir(), key=lambda p: p.name.lower()):
                    if entry.is_file() and entry.suffix.lower() in AUDIO_EXTS:
                        found_files.append(entry)
        except OSError as exc:
            with self.lock:
                self.scanning = False
                self.lib_error = str(exc)
            self.emit_view()
            return

        tracks: list[dict] = []
        by_id: dict[str, dict] = {}
        folder_counts: dict[str, int] = {}
        needs_probe: list[dict] = []

        for fp in found_files:
            try:
                st = fp.stat()
            except OSError:
                continue
            rel = str(fp.relative_to(root))
            folder_rel = str(fp.parent.relative_to(root))
            if folder_rel == ".":
                folder_rel = "Root"
            folder_counts[folder_rel] = folder_counts.get(folder_rel, 0) + 1

            parent_str = str(fp.parent)
            if parent_str not in folder_covers:
                folder_covers[parent_str] = find_folder_cover(fp.parent)

            tid = hashlib.sha1(rel.encode("utf-8", errors="replace")).hexdigest()[:16]
            cached = self.meta_cache.get(rel)
            if (
                isinstance(cached, dict)
                and cached.get("mtime") == int(st.st_mtime)
                and cached.get("size") == int(st.st_size)
            ):
                cover = cached.get("coverPath") or folder_covers[parent_str]
                if cover and not os.path.exists(cover):
                    cover = folder_covers[parent_str]
                track = {
                    "id": tid,
                    "path": str(fp),
                    "rel": rel,
                    "folder": folder_rel,
                    "ext": fp.suffix.lstrip(".").upper(),
                    "title": cached.get("title") or fp.stem,
                    "artist": cached.get("artist") or folder_rel,
                    "album": cached.get("album") or "",
                    "duration": cached.get("duration") or 0.0,
                    "coverPath": cover,
                }
            else:
                title, artist = parse_filename(fp.stem, "" if folder_rel == "Root" else fp.parent.name)
                track = {
                    "id": tid,
                    "path": str(fp),
                    "rel": rel,
                    "folder": folder_rel,
                    "ext": fp.suffix.lstrip(".").upper(),
                    "title": title,
                    "artist": artist,
                    "album": "" if folder_rel == "Root" else fp.parent.name,
                    "duration": 0.0,
                    "coverPath": folder_covers[parent_str],
                    "_mtime": int(st.st_mtime),
                    "_size": int(st.st_size),
                }
                needs_probe.append(track)

            tracks.append(track)
            by_id[tid] = track

        with self.lock:
            if token != self.scan_token:
                return
            self.tracks = tracks
            self.track_by_id = by_id
            self.folders = sorted(folder_counts.items(), key=lambda kv: kv[0].lower())
            self.scanning = False
            self.lib_error = None
            if not self.queue:
                self.queue = [t["id"] for t in tracks]
                if self.remember_session and self.current_track_id in by_id:
                    self.queue_index = self.queue.index(self.current_track_id)
                elif self.queue:
                    self.queue_index = 0
                    self.current_track_id = self.queue[0]
                else:
                    self.queue_index = -1
                    self.current_track_id = ""
            else:
                self.queue = [qid for qid in self.queue if qid in by_id]
                if self.current_track_id in self.queue:
                    self.queue_index = self.queue.index(self.current_track_id)
                else:
                    self.queue_index = 0 if self.queue else -1

        self.emit_view()
        self.emit_state()

        if needs_probe and (FFPROBE or FFMPEG):
            threading.Thread(
                target=self._enrich_tracks,
                args=(token, needs_probe),
                daemon=True,
            ).start()

    def _enrich_tracks(self, token: int, pending: list[dict]) -> None:
        changed = False
        for idx, track in enumerate(pending, start=1):
            if not self.running or token != self.scan_token:
                return
            info = probe_track(track["path"], self.covers_dir, self.extract_artwork)
            with self.lock:
                if token != self.scan_token:
                    return
                if info.get("title"):
                    track["title"] = info["title"]
                if info.get("artist"):
                    track["artist"] = info["artist"]
                if info.get("album"):
                    track["album"] = info["album"]
                if info.get("duration"):
                    track["duration"] = info["duration"]
                if info.get("coverPath"):
                    track["coverPath"] = info["coverPath"]

                self.meta_cache[track["rel"]] = {
                    "mtime": track.pop("_mtime", 0),
                    "size": track.pop("_size", 0),
                    "title": track["title"],
                    "artist": track["artist"],
                    "album": track["album"],
                    "duration": track["duration"],
                    "coverPath": track["coverPath"],
                }
                changed = True
                is_current = track["id"] == self.current_track_id

            if is_current:
                self.emit_state()
            if idx % 100 == 0 and changed:
                self._save_json(self.meta_cache_path, self.meta_cache)
                self.emit_view()
                changed = False

        if changed and token == self.scan_token:
            self._save_json(self.meta_cache_path, self.meta_cache)
            self.emit_view()

    def play_track(self, track_id: str, new_queue: list[str] | None = None) -> None:
        with self.lock:
            track = self.track_by_id.get(track_id)
            if not track:
                return
            if new_queue is not None:
                valid = [qid for qid in new_queue if qid in self.track_by_id]
                if valid:
                    self.queue = valid
            if track_id not in self.queue:
                self.queue.append(track_id)
            self.queue_index = self.queue.index(track_id)
            self.current_track_id = track_id
            self.playing = True
            self.paused = False
            self.pos = 0.0
            self.duration = track.get("duration") or 0.0

        if (FFPROBE or FFMPEG) and track.get("_mtime") is not None:
            info = probe_track(track["path"], self.covers_dir, self.extract_artwork)
            with self.lock:
                for key in ("title", "artist", "album", "duration", "coverPath"):
                    if info.get(key):
                        track[key] = info[key]

        self._mpv_send(["loadfile", track["path"], "replace"])
        self._mpv_send(["set_property", "pause", False])
        self._save_session()
        if new_queue is not None:
            self.emit_view()
        self.emit_state()

    def handle_command(self, cmd: dict) -> None:
        action = cmd.get("action")
        if action == "scan":
            self.scan(
                str(cmd.get("dir", "")),
                bool(cmd.get("recursive", True)),
                bool(cmd.get("extractArtwork", True)),
                int(cmd.get("defaultVolume", 80)),
                bool(cmd.get("remember", True)),
            )
        elif action == "view":
            with self.lock:
                tab = cmd.get("tab")
                if tab in ("all", "folders", "queue", "favorites"):
                    self.view_tab = tab
                if "folder" in cmd:
                    self.view_folder = str(cmd.get("folder") or "")
                if "query" in cmd:
                    self.view_query = str(cmd.get("query") or "")
                if "offset" in cmd:
                    self.view_offset = max(0, int(cmd.get("offset") or 0))
            self.emit_view()
        elif action == "play":
            tid = str(cmd.get("trackId", ""))
            use_view = bool(cmd.get("fromView", True))
            with self.lock:
                q = (
                    self._filtered_track_ids(self.view_tab, self.view_folder, self.view_query)
                    if (use_view and self.view_tab != "queue")
                    else None
                )
            self.play_track(tid, q)
        elif action == "play-folder":
            folder = str(cmd.get("folder") or self.view_folder or "")
            with self.lock:
                q = self._filtered_track_ids("folders", folder, self.view_query)
                first = q[0] if q else ""
            if first:
                self.play_track(first, q)
        elif action == "play-pause":
            with self.lock:
                has_active = self.playing
                cur = self.current_track_id
            if has_active:
                self._mpv_send(["cycle", "pause"])
            elif cur:
                self.play_track(cur)
            elif self.tracks:
                self.play_track(self.tracks[0]["id"])
        elif action == "next":
            with self.lock:
                tid = self._pick_next_id(auto_advance=False)
            if tid:
                self.play_track(tid)
        elif action == "prev":
            with self.lock:
                pos = self.pos
                cur = self.current_track_id
            if pos > 4.0 and cur:
                self._mpv_send(["seek", 0, "absolute"])
            else:
                with self.lock:
                    tid = self._pick_prev_id()
                if tid:
                    self.play_track(tid)
        elif action == "seek":
            sec = float(cmd.get("seconds", 0))
            self._mpv_send(["seek", max(0.0, sec), "absolute"])
            with self.lock:
                self.pos = max(0.0, sec)
            self.emit_state()
        elif action == "volume":
            vol = max(0, min(100, int(round(float(cmd.get("value", 80))))))
            self._mpv_send(["set_property", "volume", vol])
            with self.lock:
                self.volume = vol
            self._save_session()
            self.emit_state()
        elif action == "volume-delta":
            delta = int(cmd.get("delta", 0))
            with self.lock:
                vol = max(0, min(100, self.volume + delta))
                self.volume = vol
            self._mpv_send(["set_property", "volume", vol])
            self._save_session()
            self.emit_state()
        elif action == "mute-toggle":
            self._mpv_send(["cycle", "mute"])
        elif action == "shuffle-toggle":
            with self.lock:
                self.shuffle = not self.shuffle
            self._save_session()
            self.emit_state()
        elif action == "repeat-cycle":
            with self.lock:
                order = ("off", "all", "one")
                self.repeat = order[(order.index(self.repeat) + 1) % len(order)]
            self._save_session()
            self.emit_state()
        elif action == "queue-add":
            tid = str(cmd.get("trackId", ""))
            with self.lock:
                if tid in self.track_by_id:
                    self.queue.append(tid)
            self.emit_view()
            self.emit_state()
        elif action == "queue-remove":
            idx = int(cmd.get("index", -1))
            with self.lock:
                if 0 <= idx < len(self.queue):
                    self.queue.pop(idx)
                    if idx < self.queue_index:
                        self.queue_index -= 1
                    elif idx == self.queue_index:
                        self.queue_index = min(self.queue_index, len(self.queue) - 1)
            self.emit_view()
            self.emit_state()
        elif action == "queue-clear":
            with self.lock:
                if self.playing and self.current_track_id:
                    self.queue = [self.current_track_id]
                    self.queue_index = 0
                else:
                    self.queue = []
                    self.queue_index = -1
            self.emit_view()
            self.emit_state()
        elif action == "favorite-toggle":
            tid = str(cmd.get("trackId", ""))
            with self.lock:
                if tid in self.favorite_set:
                    self.favorite_set.remove(tid)
                    self.favorites = [f for f in self.favorites if f != tid]
                elif tid in self.track_by_id:
                    self.favorite_set.add(tid)
                    self.favorites.append(tid)
            self._save_session()
            self.emit_view()
            self.emit_state()
        elif action == "shuffle-play":
            with self.lock:
                pool = self._filtered_track_ids(
                    self.view_tab if self.view_tab != "queue" else "all",
                    self.view_folder,
                    self.view_query,
                )
                if not pool:
                    pool = [t["id"] for t in self.tracks]
                if pool:
                    self.shuffle = True
                    shuffled = list(pool)
                    random.shuffle(shuffled)
                    first = shuffled[0]
                else:
                    shuffled = []
                    first = ""
            if first:
                self.play_track(first, shuffled)

    def _serve_cmd_socket(self, ready_ev: threading.Event | None = None) -> None:
        self.cmd_sock_path.unlink(missing_ok=True)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(self.cmd_sock_path))
        os.chmod(self.cmd_sock_path, 0o600)
        srv.listen(16)
        srv.settimeout(0.5)
        if ready_ev is not None:
            ready_ev.set()
        while self.running:
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            try:
                data = b""
                while True:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                for line in data.decode("utf-8", errors="replace").splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        cmd = json.loads(line)
                        if isinstance(cmd, dict):
                            self.handle_command(cmd)
                    except Exception:
                        pass
            finally:
                conn.close()
        srv.close()


def send_cmd(target: Path, payload: str) -> int:
    if target.is_dir():
        candidates = sorted(target.glob("cmd.*.sock"), key=lambda p: p.stat().st_mtime, reverse=True)
        sock_path = candidates[0] if candidates else (target / "cmd.sock")
    else:
        sock_path = target

    deadline = time.monotonic() + 1.5
    while not sock_path.exists() and time.monotonic() < deadline:
        if target.is_dir():
            candidates = sorted(target.glob("cmd.*.sock"), key=lambda p: p.stat().st_mtime, reverse=True)
            if candidates:
                sock_path = candidates[0]
                break
        time.sleep(0.03)
    if not sock_path.exists():
        return 1
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(str(sock_path))
        sock.sendall(payload.encode("utf-8") + b"\n")
        return 0
    except OSError:
        return 1
    finally:
        sock.close()


def main() -> int:
    if len(sys.argv) < 3:
        return 2
    mode = sys.argv[1]
    data_dir = Path(sys.argv[2])

    if mode == "cmd":
        if len(sys.argv) < 4:
            return 2
        return send_cmd(data_dir, sys.argv[3])

    if mode == "serve":
        backend = FlexaBackend(data_dir)

        def handle_signal(_signum, _frame):
            backend.stop()
            sys.exit(0)

        signal.signal(signal.SIGTERM, handle_signal)
        signal.signal(signal.SIGINT, handle_signal)

        backend.start()
        try:
            while backend.running:
                time.sleep(0.5)
                if backend.mpv_proc and backend.mpv_proc.poll() is not None:
                    backend._start_mpv()
        finally:
            backend.stop()
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
