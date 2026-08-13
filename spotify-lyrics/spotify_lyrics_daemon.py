import os
import time
import json
import hashlib
import subprocess
import threading
import urllib.request
import syncedlyrics
from pathlib import Path

# Config
CACHE_DIR = Path.home() / ".cache" / "noctalia" / "lyrics"
CACHE_DIR.mkdir(parents=True, exist_ok=True)
CURRENT_STATE_FILE = CACHE_DIR / "current.json"

ART_CACHE_DIR = CACHE_DIR / "art"
ART_CACHE_DIR.mkdir(parents=True, exist_ok=True)

class SpotifyLyricsDaemon:
    def __init__(self):
        self.lyrics_cache = {}  # song_key -> list of lines
        self.fetching_keys = set()  # Tracks keys currently fetching in the background
        self.art_cache = {}     # art_url -> local file path
        self.art_fetching = set()  # URLs currently being downloaded

    def clean_filename(self, name):
        return "".join(c for c in name if c.isalnum() or c in (" ", "_", "-")).strip()

    def get_parsed_lyrics(self, title, artist):
        song_key = f"{artist} - {title}"
        if song_key in self.lyrics_cache:
            return self.lyrics_cache[song_key]
        
        # Check local disk cache first
        safe_name = self.clean_filename(song_key)
        lrc_file = CACHE_DIR / f"{safe_name}.lrc"
        
        if lrc_file.exists():
            parsed = self.load_lrc_file(lrc_file)
            self.lyrics_cache[song_key] = parsed
            return parsed
        
        # Fetch from syncedlyrics asynchronously to prevent daemon thread lag
        if song_key not in self.fetching_keys:
            self.fetching_keys.add(song_key)
            threading.Thread(
                target=self._async_fetch_lyrics, 
                args=(song_key, lrc_file), 
                daemon=True
            ).start()
        
        return []

    def _async_fetch_lyrics(self, song_key, lrc_file):
        try:
            print(f"[Daemon] Fetching lyrics in background for: {song_key}...")
            lrc_text = syncedlyrics.search(song_key, providers=["NetEase", "Lrclib"])
            if lrc_text:
                with open(lrc_file, "w", encoding="utf-8") as f:
                    f.write(lrc_text)
                
                parsed = self.parse_lrc_text(lrc_text)
                self.lyrics_cache[song_key] = parsed
                print(f"[Daemon] Fetch completed for: {song_key}")
            else:
                print(f"[Daemon] No lyrics found online for: {song_key}")
        except Exception as e:
            print(f"[Daemon] Error fetching lyrics for {song_key}: {e}")
        finally:
            self.fetching_keys.discard(song_key)

    def parse_lrc_text(self, lrc_text):
        parsed = []
        for line in lrc_text.splitlines():
            # Format: [mm:ss.xx] Text
            if line.startswith("[") and "]" in line:
                parts = line.split("]", 1)
                time_part = parts[0].replace("[", "").strip()
                text = parts[1].strip()
                
                try:
                    # mm:ss.xx or mm:ss
                    if "." in time_part:
                        min_sec, hund = time_part.split(".")
                        hund_val = int(hund) * 10 if len(hund) == 2 else int(hund)
                    else:
                        min_sec = time_part
                        hund_val = 0
                    
                    minutes, seconds = min_sec.split(":")
                    time_ms = ((int(minutes) * 60) + int(seconds)) * 1000 + hund_val
                    parsed.append({"time_ms": time_ms, "text": text})
                except Exception:
                    pass
        return parsed

    def load_lrc_file(self, lrc_file):
        try:
            with open(lrc_file, "r", encoding="utf-8") as f:
                return self.parse_lrc_text(f.read())
        except Exception as e:
            print(f"[Daemon] Error reading LRC file: {e}")
        return []

    def get_album_art_path(self, art_url):
        """Download album art from URL and return local cached file path."""
        if not art_url or art_url == "":
            return ""
        
        # Check in-memory cache
        if art_url in self.art_cache:
            path = self.art_cache[art_url]
            if os.path.exists(path):
                return path
        
        # Derive a stable filename from the URL hash
        url_hash = hashlib.md5(art_url.encode()).hexdigest()
        ext = ".jpg"  # Spotify art is always JPEG
        local_path = str(ART_CACHE_DIR / f"{url_hash}{ext}")
        
        # If already downloaded on disk, cache and return
        if os.path.exists(local_path):
            self.art_cache[art_url] = local_path
            return local_path
        
        # Download in background to avoid blocking the main loop
        if art_url not in self.art_fetching:
            self.art_fetching.add(art_url)
            threading.Thread(
                target=self._download_art,
                args=(art_url, local_path),
                daemon=True
            ).start()
        
        return ""  # Not yet available
    
    def _download_art(self, url, local_path):
        try:
            tmp_path = local_path + ".tmp"
            urllib.request.urlretrieve(url, tmp_path)
            os.replace(tmp_path, local_path)
            self.art_cache[url] = local_path
            print(f"[Daemon] Downloaded album art: {url[:60]}...")
        except Exception as e:
            print(f"[Daemon] Error downloading album art: {e}")
            # Clean up partial download
            try:
                os.remove(local_path + ".tmp")
            except OSError:
                pass
        finally:
            self.art_fetching.discard(url)

    def get_player_status(self):
        try:
            # Query active players
            players = subprocess.check_output(["playerctl", "-l"], stderr=subprocess.DEVNULL).decode("utf-8").strip().splitlines()
            if not players:
                return None
            
            # Prioritize Spotify
            player_name = "spotify" if "spotify" in players else players[0]
            
            # Query all metadata in ONE execution using custom delimiters to eliminate subprocess latency
            output = subprocess.check_output([
                "playerctl", "-p", player_name, "metadata", 
                "--format", "{{status}}|||{{position}}|||{{title}}|||{{artist}}|||{{mpris:artUrl}}"
            ], stderr=subprocess.DEVNULL).decode("utf-8").strip()
            
            parts = output.split("|||")
            if len(parts) >= 4:
                status, pos_us, title, artist = parts[0], parts[1], parts[2], parts[3]
                art_url = parts[4] if len(parts) >= 5 else ""
                
                # Position is in microseconds (us), convert to milliseconds (ms)
                position_ms = int(int(pos_us) / 1000)
                
                return {
                    "status": status,
                    "position_ms": position_ms,
                    "title": title,
                    "artist": artist,
                    "art_url": art_url
                }
        except Exception:
            pass
        return None

    def run(self):
        print("[Daemon] Starting Universal lyrics cache daemon...")
        
        while True:
            player = self.get_player_status()
            
            if not player or not player["title"]:
                # Write empty/inactive state
                empty_state = {"status": "Stopped"}
                tmp_file = CURRENT_STATE_FILE.with_suffix('.tmp')
                with open(tmp_file, "w", encoding="utf-8") as f:
                    json.dump(empty_state, f)
                tmp_file.replace(CURRENT_STATE_FILE)
                time.sleep(1.0)
                continue
            
            title = player["title"]
            artist = player["artist"]
            
            lyrics_lines = self.get_parsed_lyrics(title, artist)
            
            # Find active line
            active_idx = -1
            pos_ms = player["position_ms"]
            
            for i, line in enumerate(lyrics_lines):
                if pos_ms >= line["time_ms"]:
                    active_idx = i
                else:
                    break
            
            # Get surrounding lines
            prev_prev = lyrics_lines[active_idx - 2]["text"] if active_idx >= 2 else ""
            prev = lyrics_lines[active_idx - 1]["text"] if active_idx >= 1 else ""
            current = lyrics_lines[active_idx]["text"] if active_idx >= 0 else "..."
            next_line = lyrics_lines[active_idx + 1]["text"] if active_idx >= 0 and active_idx + 1 < len(lyrics_lines) else ""
            next_next = lyrics_lines[active_idx + 2]["text"] if active_idx >= 0 and active_idx + 2 < len(lyrics_lines) else ""
            
            # Resolve album art to a local file path
            art_path = self.get_album_art_path(player.get("art_url", ""))
            
            state = {
                "status": player["status"],
                "title": title,
                "artist": artist,
                "prev_prev": prev_prev,
                "prev": prev,
                "current": current,
                "next": next_line,
                "next_next": next_next,
                "art_path": art_path
            }
            
            # Save state
            tmp_file = CURRENT_STATE_FILE.with_suffix('.tmp')
            with open(tmp_file, "w", encoding="utf-8") as f:
                json.dump(state, f)
            tmp_file.replace(CURRENT_STATE_FILE)
            
            # Update more frequently if playing to maintain tight sync
            if player["status"] == "Playing":
                time.sleep(0.3)  # Reduce polling frequency to prevent massive OS subprocess leak
            else:
                time.sleep(1.0)

if __name__ == "__main__":
    daemon = SpotifyLyricsDaemon()
    daemon.run()
