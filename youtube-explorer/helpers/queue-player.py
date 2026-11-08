"""Control the plugin's dedicated mpv queue through its private JSON IPC socket."""

import fcntl
import hashlib
import json
import math
import os
import re
import socket
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path


class Player:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(3)
        try:
            self.socket.connect(str(path))
        except OSError:
            self.socket.close()
            raise
        self.stream = self.socket.makefile("rb")
        self.serial = 0

    def close(self):
        self.stream.close()
        self.socket.close()

    def command(self, *command):
        self.serial += 1
        self.socket.sendall((json.dumps({"command": command, "request_id": self.serial}) + "\n").encode())
        while True:
            line = self.stream.readline()
            if not line:
                raise RuntimeError("Queue player disconnected")
            result = json.loads(line)
            if result.get("request_id") == self.serial:
                if result.get("error") != "success":
                    raise RuntimeError(result.get("error", "mpv command failed"))
                return result.get("data")

    def get(self, name):
        return self.command("get_property", name)


def socket_path(queue_path):
    digest = hashlib.sha256(str(queue_path.resolve()).encode()).hexdigest()[:16]
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp")
    directory = runtime / f"noctalia-youtube-{os.getuid()}-{digest}"
    directory.mkdir(mode=0o700, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise RuntimeError("Queue control directory must be private")
    return directory / "player.sock"


def read_items(path):
    saved = json.loads(path.read_text())
    if not isinstance(saved, dict):
        raise TypeError("Playback queue must be an object")
    if saved.get("version") != 1:
        raise ValueError("Invalid playback queue")
    items = saved.get("items")
    # Noctalia encodes an empty Luau table as an empty JSON object.
    if items == {}:
        items = []
    if not isinstance(items, list):
        raise TypeError("Queued items must be a list")
    urls = []
    for item in items:
        if not isinstance(item, dict):
            raise TypeError("Queued video must be an object")
        if "autoplay" in item and not isinstance(item["autoplay"], bool):
            raise TypeError("Queued autoplay flag must be a boolean")
        video_id = item.get("id")
        if not isinstance(video_id, str):
            raise TypeError("Queued video ID must be a string")
        if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
            raise ValueError("Invalid queued video ID")
        url = "https://www.youtube.com/watch?v=" + video_id
        if url in urls:
            raise ValueError("Duplicate queued video")
        urls.append(url)
    return items


def read_queue(path):
    return [video_url(item["id"]) for item in read_items(path)]


def video_url(video_id):
    return "https://www.youtube.com/watch?v=" + video_id


def save_items(path, items):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".part." + uuid.uuid4().hex)
    try:
        with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
            json.dump({"version": 1, "items": items}, stream)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def current_url(player):
    if player is None or player.get("idle-active") or player.get("eof-reached"):
        return None
    return next((entry["filename"] for entry in player.get("playlist")
                 if entry.get("current")), None)


def validate_item(item):
    if not isinstance(item, dict):
        raise TypeError("Queued video must be an object")
    if not all(isinstance(item.get(key), str) for key in ("id", "title", "subtitle")):
        raise TypeError("Queued video ID, title and subtitle must be strings")
    if not re.fullmatch(r"[A-Za-z0-9_-]{11}", item["id"]):
        raise ValueError("Invalid queued video metadata")
    channel = item.get("channelId")
    if channel is not None:
        if not isinstance(channel, str):
            raise TypeError("Queued channel ID must be a string")
        if not re.fullmatch(r"UC[A-Za-z0-9_-]{22}", channel):
            raise ValueError("Invalid queued channel")
    for key in ("titleKind", "subtitleKind", "author", "durationText"):
        if key in item and not isinstance(item[key], str):
            raise TypeError("Queued presentation fields must be strings")
    if "isLive" in item and not isinstance(item["isLive"], bool):
        raise TypeError("Queued live flag must be a boolean")
    return {key: item[key] for key in ("id", "title", "subtitle", "channelId",
            "titleKind", "subtitleKind", "author", "durationText", "isLive") if key in item}


def notify_queue_changed():
    try:
        subprocess.Popen(
            ["noctalia", "msg", "plugin", "nullflake/youtube-explorer:queue-events", "all",
             "queue-changed", uuid.uuid4().hex],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        pass  # The saved queue remains authoritative when the shell is not running.


def connect(path):
    try:
        return Player(path)
    except (FileNotFoundError, ConnectionRefusedError):
        return None


def autoplay_state(player):
    data = player.get("user-data") or {}
    return data.get("youtube-explorer", {"enabled": False, "seen": []})


def save_autoplay(player, state):
    player.command("set_property", "user-data/youtube-explorer", state)


class RetryableMixError(RuntimeError):
    pass


class NoRecommendationsError(ValueError):
    pass


class MixUnavailableError(ValueError):
    pass


def current_mix_request(path, pid, ticket):
    player = None
    try:
        player = connect(path)
        if player is None or player.get("pid") != pid:
            return False
        state = autoplay_state(player)
        return state["enabled"] and state.get("pending") == ticket
    except (OSError, RuntimeError):
        return False
    finally:
        if player is not None:
            player.close()


def fetch_mix(path, is_current, seed, seen, count):
    # Separate from the queue lock: playback and manual edits must stay responsive.
    # Obsolete waiters leave without starting another yt-dlp process.
    with path.with_suffix(".mix.lock").open("a") as network_lock:
        while True:
            if not is_current():
                return None
            try:
                fcntl.flock(network_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                time.sleep(0.1)
        time.sleep(0.25)  # Coalesce a burst of navigation/refresh actions.
        for attempt in range(2):
            if not is_current():
                return None
            try:
                return mix_candidates(seed, seen, count, is_current=is_current)
            except (RetryableMixError, subprocess.TimeoutExpired):
                if attempt:
                    raise
                time.sleep(2)
    return None


def recommendation_response(seed, *, related=False, timeout: float = 25):
    plugin_dir = Path(__file__).resolve().parents[1]
    target = "ytexplorer-related:" + seed if related else video_url(seed) + "&list=RD" + seed
    response = subprocess.run([
        "yt-dlp", "--ignore-config", "--no-cache-dir", "--force-ipv4", "--yes-playlist",
        "--no-plugin-dirs", "--plugin-dirs", str(plugin_dir),
        "--flat-playlist", "--dump-single-json", "--playlist-end", "21",
        "--socket-timeout", "5", "--retries", "0", "--extractor-retries", "0", "--", target,
    ], capture_output=True, text=True, timeout=timeout, check=False,
       env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
    if response.returncode:
        detail = " ".join(response.stderr.split())
        transient = re.search(
            r"record_layer_failure|bad record mac|unexpected_eof|connection (?:reset|aborted|refused)|"
            r"timed? out|temporary failure|failed to resolve|name or service not known|"
            r"nodename nor servname provided|network is unreachable|remote end closed|http error 50[234]",
            detail, re.IGNORECASE)
        if transient and "certificate_verify_failed" not in detail.lower():
            raise RetryableMixError(detail[-240:] or "yt-dlp failed")
        if not related and re.search(
                r"playlist (?:does not exist|is not available|is unavailable)|unable to recognize (?:playlist|tab page)",
                detail, re.IGNORECASE):
            raise MixUnavailableError("No Mix playlist for this video")
        raise RuntimeError(detail[-240:] or "yt-dlp failed")
    data = json.loads(response.stdout)
    if not isinstance(data, dict):
        raise TypeError("Recommendation response must be an object")
    if not isinstance(data.get("entries"), list):
        if not related and data.get("id") == seed and data.get('_type') in (None, 'video', 'url'):
            raise MixUnavailableError("Mix returned only the source video")
        raise TypeError("Recommendation entries must be a list")
    if not related and not any(isinstance(entry, dict) and entry.get('id') != seed for entry in data['entries']):
        raise MixUnavailableError("No Mix playlist entries for this video")
    return data['entries']


def mix_candidates(seed, seen, count=5, *, is_current=None):
    deadline = time.monotonic() + 25
    related = False
    try:
        entries = recommendation_response(seed)
    except MixUnavailableError:
        if is_current is not None and not is_current():
            return None
        related = True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired('YouTube recommendations', 25)
        entries = recommendation_response(seed, related=True, timeout=remaining)
    excluded, items = set(seen) | {seed}, []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        identifier = entry.get("id")
        if (not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9_-]{11}", identifier)
                or identifier in excluded or entry.get("availability") in ("private", "premium_only")):
            continue
        excluded.add(identifier)
        title = entry.get("title")
        author = entry.get("channel") or entry.get("uploader")
        item = {"id": identifier, "title": title if isinstance(title, str) else identifier,
                "titleKind": "original", "subtitleKind": "original",
                "subtitle": author if isinstance(author, str) else ("YouTube" if related else "YouTube Mix"),
                "queueToken": uuid.uuid4().hex, "autoplay": True}
        channel = entry.get("channel_id")
        if isinstance(channel, str) and re.fullmatch(r"UC[A-Za-z0-9_-]{22}", channel):
            item["channelId"] = channel
        items.append(item)
        if len(items) == count:
            break
    if not items:
        raise NoRecommendationsError("No unseen recommendations returned")
    return items


def refill_autoplay(lock, path, queue_path, player, seed, anchor_token=None, refresh=False, anchor_id=None):
    state = autoplay_state(player)
    anchor_id = anchor_id or seed
    seen = state["seen"]
    if seed not in seen:
        seen.append(seed)
    excluded = seen + [item["id"] for item in read_items(queue_path)] if refresh else seen
    ticket = uuid.uuid4().hex
    state["pending"] = ticket
    save_autoplay(player, state)
    pid = player.get("pid")
    player.close()
    # Network IO must not hold the queue lock or block manual queue edits.
    fcntl.flock(lock, fcntl.LOCK_UN)
    error, error_kind = None, "unavailable"
    try:
        candidates = fetch_mix(path, lambda: current_mix_request(path, pid, ticket),
                               seed, excluded, state.get("count", 5))
    except (OSError, TypeError, ValueError, RuntimeError, subprocess.SubprocessError) as exception:
        candidates, error = [], str(exception)
        if isinstance(exception, (RetryableMixError, subprocess.TimeoutExpired)):
            error_kind = "network"
        elif isinstance(exception, NoRecommendationsError):
            error_kind = "empty"
    finally:
        fcntl.flock(lock, fcntl.LOCK_EX)
    player = connect(path)
    if player is None:
        return
    try:
        current = autoplay_state(player)
        if player.get("pid") != pid or not current["enabled"] or current.get("pending") != ticket:
            return
        current["pending"] = None
        save_autoplay(player, current)
        if candidates is None:
            return
        # A preload may finish while its anchor is playing or after it ends.
        # Manual queue edits invalidate the pending ticket before we get here.
        items = read_items(queue_path)
        if items:
            anchors = items if refresh else items[-1:]
            if anchor_token is None or not any(
                    item["id"] == anchor_id and item.get("queueToken") == anchor_token for item in anchors):
                return
        elif anchor_token is None and not player.get("idle-active"):
            return
        if error:
            print("YouTube Mix: " + error, file=sys.stderr)
            try:
                subprocess.Popen(["noctalia", "msg", "plugin", "nullflake/youtube-explorer:queue-events",
                                  "all", "autoplay-error", error_kind],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
            except OSError:
                pass
            return
        queued = {item["id"] for item in items}
        items.extend(item for item in candidates if item["id"] not in queued)
        save_items(queue_path, items)
        synchronize(player, items)
        notify_queue_changed()
    finally:
        player.close()


def apply_options(player, options):
    player.command("apply-profile", "youtube-explorer")
    player.command("set_property", "options/vid", "auto")
    script_options = []
    for option in options:
        if "=" not in option or option.startswith("--profile="):
            continue
        name, value = option.removeprefix("--").split("=", 1)
        if name == "script-opts-append":
            script_options.append(value)
            continue
        if name in ("ytdl-format", "vid", "force-window"):
            player.command("set_property", "options/" + name, value)
    # Script options are supplied when the dedicated player starts; resetting the
    # playback profile must retain them for later files and repeated Play queue.
    if script_options:
        player.command("set_property", "script-opts", "youtube-resume-enabled=yes," + ",".join(script_options))


def append_item(player, item, start_time=None):
    url = video_url(item["id"])
    if start_time is not None:
        return player.command("loadfile", url, "append", -1,
                              {"start": str(start_time), "resume-playback": "no"})
    title = item.get("title")
    if not isinstance(title, str) or not title.strip():
        return player.command("loadfile", url, "append")
    # A titled M3U entry exposes playlist/N/title before the media is opened.
    # Keep untrusted titles on one line so they cannot inject playlist entries.
    title = " ".join(re.sub(r"[\x00-\x1f\x7f]", " ", title).split())
    return player.command("loadlist", "memory://#EXTM3U\n#EXTINF:-1," + title + "\n" + url + "\n", "append")


def synchronize(player, items, *, start_id=None, start_time=None, auto_start=True):
    data = player.get("user-data") or {}
    played = set(data.get("youtube-explorer-played", []))
    mapped = data.get("youtube-explorer-entries", {})
    playlist = player.get("playlist")
    native = {entry["id"]: entry for entry in playlist}
    active = {}
    for item in items:
        entry_id = mapped.get(item["queueToken"])
        if entry_id in native and native[entry_id]["filename"] == video_url(item["id"]):
            active[item["queueToken"]] = entry_id
    history = [entry["id"] for entry in playlist
               if entry["id"] in played and entry["id"] not in active.values()]
    keep = set(history) | set(active.values())
    # Remove from the end so earlier indices remain stable.
    for index in range(len(playlist) - 1, -1, -1):
        if playlist[index]["id"] not in keep:
            player.command("playlist-remove", index)
    added = []
    at_end = not player.get("idle-active") and player.get("eof-reached")
    for item in items:
        token = item["queueToken"]
        if token not in active:
            result = append_item(player, item, start_time if item["id"] == start_id else None)
            entry_id = result["playlist_entry_id"]
            active[token] = entry_id
            added.append(entry_id)
    player.command("set_property", "user-data/youtube-explorer-entries", active)
    desired = history + [active[item["queueToken"]] for item in items]
    playlist = player.get("playlist")
    # Move later entries backwards; mpv retains the current entry and its position
    # within the file when its playlist index changes.
    for index, entry_id in enumerate(desired):
        if playlist[index]["id"] != entry_id:
            old_index = next(
                i for i in range(index + 1, len(playlist))
                if playlist[i]["id"] == entry_id
            )
            player.command("playlist-move", old_index, index)
            playlist.insert(index, playlist.pop(old_index))
    next_index = None
    if auto_start and added and player.get("idle-active"):
        next_index = desired.index(added[0])
    elif auto_start and added and at_end and player.get("eof-reached"):
        current = player.get("playlist-pos")
        if current + 1 < len(desired):
            next_index = current + 1
    if next_index is not None:
        player.command("set_property", "playlist-pos", next_index)
        player.command("set_property", "pause", False)
    return {item["id"]: desired.index(active[item["queueToken"]]) for item in items}


def main():
    action, filename, *options = sys.argv[1:]
    if action not in ("play", "sync", "toggle", "clear", "refresh", "started", "prepare", "complete", "failed", "close"):
        raise ValueError("Unknown queue action")
    queue_path = Path(filename)
    start_id = None
    start_time = None
    item = None
    completed_token = None
    completed_entry = None
    closing_pid = None
    autoplay = False
    autoplay_count = 5
    playback_options = []
    for option in options:
        if option.startswith("--queue-autoplay="):
            value = option.split("=", 1)[1]
            if value not in ("yes", "no"):
                raise ValueError("Invalid autoplay option")
            autoplay = value == "yes"
        elif option.startswith("--queue-autoplay-count="):
            autoplay_count = int(option.split("=", 1)[1])
            if not 1 <= autoplay_count <= 10:
                raise ValueError("Invalid autoplay count")
        elif option.startswith("--queue-item="):
            item = validate_item(json.loads(option.split("=", 1)[1]))
        elif option.startswith("--queue-token="):
            completed_token = option.split("=", 1)[1]
        elif option.startswith("--queue-entry="):
            completed_entry = int(option.split("=", 1)[1])
        elif option.startswith("--queue-pid="):
            closing_pid = int(option.split("=", 1)[1])
        elif option.startswith("--queue-start="):
            start_id = option.split("=", 1)[1]
        elif option.startswith("--queue-start-time="):
            start_time = float(option.split("=", 1)[1])
            if not math.isfinite(start_time) or start_time < 0:
                raise ValueError("Invalid playback start time")
        else:
            playback_options.append(option)
    options = playback_options
    path = socket_path(queue_path)
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        items = read_items(queue_path) if queue_path.exists() else []
        if action == "close":
            if closing_pid is None or closing_pid <= 0:
                raise ValueError("Missing closing player identity")
            player = None
            try:
                player = connect(path)
                # A delayed shutdown must not clear a newly started player's queue.
                if player is not None and player.get("pid") != closing_pid:
                    return
            except (OSError, RuntimeError):
                pass  # The old player may already have closed its IPC connection.
            finally:
                if player is not None:
                    player.close()
            if items:
                save_items(queue_path, [])
                notify_queue_changed()
            return
        if action in ("started", "prepare"):
            if not start_id or not completed_token or closing_pid is None:
                raise ValueError("Missing preload player identity")
            player = connect(path)
            if player is None:
                return
            try:
                if player.get("pid") != closing_pid or current_url(player) != video_url(start_id):
                    return
                index = next((i for i, entry in enumerate(items)
                              if entry["id"] == start_id and entry.get("queueToken") == completed_token), None)
                if index is None:
                    return
                if index:
                    items = items[index:]
                    save_items(queue_path, items)
                    state = autoplay_state(player)
                    state["pending"] = None
                    save_autoplay(player, state)
                    synchronize(player, items, auto_start=False)
                    notify_queue_changed()
                state = autoplay_state(player)
                if start_id not in state["seen"]:
                    state["seen"].append(start_id)
                # Manual queue entries are interludes. Only a newly started
                # recommendation advances the Mix source; rebinds and replays do not.
                if action == "started" and items[0].get("autoplay") is True and state.get("seed") != start_id:
                    state["seed"] = start_id
                    state["pending"] = None
                state.setdefault("seed", start_id)
                save_autoplay(player, state)
                if len(items) != 1 or not state["enabled"] or state.get("pending"):
                    return
                active = player
                player = None
                refill_autoplay(lock, path, queue_path, active, state["seed"], completed_token,
                                anchor_id=start_id)
            finally:
                if player is not None:
                    player.close()
            return
        if action in ("complete", "failed"):
            if not start_id or not completed_token or completed_entry is None:
                raise ValueError("Missing completed video identity")
            remaining = [entry for entry in items if not (
                entry["id"] == start_id and entry.get("queueToken") == completed_token)]
            if remaining == items:
                return
            save_items(queue_path, remaining)
            notify_queue_changed()
            if action == "failed":
                try:
                    subprocess.Popen(["noctalia", "msg", "plugin", "nullflake/youtube-explorer:queue-events",
                                      "all", "playback-error", start_id], stdin=subprocess.DEVNULL,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                except OSError:
                    pass
            # Queue storage is authoritative even if mpv is already closing.
            player = None
            try:
                player = connect(path)
                if player is not None:
                    state = autoplay_state(player)
                    if start_id not in state["seen"]:
                        state["seen"].append(start_id)
                    if action == "failed" and not remaining:
                        # Do not endlessly fetch more videos when playback itself is failing.
                        state["enabled"], state["pending"] = False, None
                    save_autoplay(player, state)
                    if (not remaining and state["enabled"] and not state.get("pending")
                            and player.get("idle-active")):
                        active = player
                        player = None
                        refill_autoplay(lock, path, queue_path, active, state.get("seed", start_id))
            except (OSError, RuntimeError):
                pass
            finally:
                if player is not None:
                    player.close()
            return
        player = connect(path)
        clear_entry = None
        if action == "toggle":
            if item is None:
                raise ValueError("Missing queued video")
            if any(entry["id"] == item["id"] for entry in items):
                items = [entry for entry in items if entry["id"] != item["id"]]
            else:
                current = current_url(player)
                # A manual choice replaces pending recommendations, preserving
                # the playing entry and the order of all manual selections.
                items = [entry for entry in items if entry.get("autoplay") is not True
                         or video_url(entry["id"]) == current]
                items.append(item)
        elif action in ("clear", "refresh"):
            current = current_url(player)
            if action == "refresh" and (not autoplay or not current):
                if player is not None:
                    player.close()
                raise RuntimeError("Refreshing suggestions requires Mix and an actively loaded video")
            items = [entry for entry in items if video_url(entry["id"]) == current
                     or (action == "refresh" and entry.get("autoplay") is not True)]
            if player is not None and current:
                native = next((entry for entry in player.get("playlist") if entry.get("current")), None)
                identifier = re.fullmatch(r"https://www.youtube.com/watch\?v=([A-Za-z0-9_-]{11})", current)
                if native is not None and identifier:
                    current_item = next((entry for entry in items if video_url(entry["id"]) == current), None) or {
                        "id": identifier[1], "title": native.get("title") or identifier[1],
                        "subtitle": "YouTube",
                    }
                    mapped = (player.get("user-data") or {}).get("youtube-explorer-entries", {})
                    if mapped.get(current_item.get("queueToken")) != native["id"]:
                        current_item = dict(current_item, queueToken=uuid.uuid4().hex)
                        clear_entry = native
                    items = [current_item] + [entry for entry in items if entry["id"] != current_item["id"]]
        elif action == "play" and item is not None:
            existing = next((entry for entry in items if entry["id"] == item["id"]), None)
            if existing is None:
                items.insert(0, item)
            else:
                existing.update(item)
                existing.pop("autoplay", None)
            items = [entry for entry in items if entry.get("autoplay") is not True]
            start_id = item["id"]
        if action == "play" and items:
            current = current_url(player)
            selected = video_url(start_id or items[0]["id"])
            if current and current != selected:
                items = [entry for entry in items if video_url(entry["id"]) != current]
        for entry in items:
            if action == "play" or not entry.get("queueToken"):
                # Play rebuilds the whole playlist; an earlier end-file must not consume its new entries.
                entry["queueToken"] = uuid.uuid4().hex
        urls = [video_url(entry["id"]) for entry in items]
        if action == "play" and not urls:
            raise ValueError("Playback queue is empty")
        start_index = 0
        if start_id is not None:
            start_url = "https://www.youtube.com/watch?v=" + start_id
            if start_url not in urls:
                raise ValueError("Selected video is no longer in the playback queue")
            start_index = urls.index(start_url)
        process = None
        try:
            save_items(queue_path, items)
            if action == "play":
                options = [*options,
                    "--script=" + str(Path(__file__).resolve().parents[1] / "mpv" / "queue-playback.lua"),
                    "--script-opts-append=queue-playback-queue_path=" + str(queue_path.resolve()),
                    "--script-opts-append=queue-playback-helper=" + str(Path(__file__).resolve()),
                    "--script-opts-append=queue-playback-python=" + sys.executable,
                    "--script-opts-append=youtube-resume-queue_path=" + str(queue_path.resolve())]
            if player is None and action == "play":
                path.unlink(missing_ok=True)
                process = subprocess.Popen(
                    ["mpv", *options, "--idle=yes", "--keep-open=no", "--force-window=yes",
                     "--input-ipc-server=" + str(path)],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
                deadline = time.monotonic() + 6
                while player is None:
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Could not start the queue player")
                    time.sleep(0.05)
                    player = connect(path)
            if player is None:
                return  # Editing a saved queue must not start playback.
            state = autoplay_state(player)
            state["pending"] = None
            if action == "play":
                state["count"] = autoplay_count
                state["enabled"] = autoplay
                selected_id = start_id or items[0]["id"]
                state["seed"] = selected_id
                if selected_id not in state["seen"]:
                    state["seen"].append(selected_id)
                save_autoplay(player, state)
                apply_options(player, options)
                player.command("set_property", "keep-open", False)
                positions = synchronize(player, items, start_id=start_id, start_time=start_time, auto_start=False)
                player.command("set_property", "playlist-pos", positions[items[start_index]["id"]])
                player.command("set_property", "pause", False)
            else:
                if action == "clear":
                    # Suppress refills until an explicit play request applies
                    # the saved Mix preference again. Pending fetches are invalidated above.
                    state["enabled"] = False
                elif action == "refresh":
                    state["enabled"], state["count"] = True, autoplay_count
                    state.setdefault("seed", items[0]["id"])
                    # Block automatic started events until this explicit fetch owns a ticket.
                    state["pending"] = uuid.uuid4().hex
                save_autoplay(player, state)
                if clear_entry is not None:
                    mapped = (player.get("user-data") or {}).get("youtube-explorer-entries", {})
                    mapped[items[0]["queueToken"]] = clear_entry["id"]
                    player.command("set_property", "user-data/youtube-explorer-entries", mapped)
                synchronize(player, items)
                if action in ("clear", "refresh") and items:
                    player.command("script-message", "youtube-explorer-queue-cleared")
                if action == "refresh":
                    active, player = player, None
                    refill_autoplay(lock, path, queue_path, active, state["seed"],
                                    items[0]["queueToken"], refresh=True, anchor_id=items[0]["id"])
        except Exception:
            if process is not None and process.poll() is None:
                process.terminate()
            raise
        finally:
            if player is not None:
                player.close()


if __name__ == "__main__":
    try:
        main()
    except (OSError, TypeError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
