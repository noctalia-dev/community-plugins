#!/usr/bin/env python3
import sys, os, json, urllib.request, urllib.parse

LRCLIB = "https://lrclib.net/api/search"


def norm(s):
    return "".join(ch for ch in (s or "") if ch.isalnum() or "\u4e00" <= ch <= "\u9fff").lower()


def http_get(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": "lyrics-plugin/1.0",
        "Accept": "application/json",
    })
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.read().decode("utf-8", "ignore")


def main():
    raw = sys.argv[1] if len(sys.argv) > 1 else ""
    title, artist, album = "test", "", ""
    if raw and os.path.isfile(raw):
        try:
            with open(raw, encoding="utf-8") as f:
                lines = [l.strip() for l in f.read().splitlines()]
            title = lines[0] if lines else "test"
            artist = lines[1] if len(lines) > 1 else ""
            album = lines[2] if len(lines) > 2 else ""
        except Exception as e:
            out = {"type": "none", "lines": [], "lrc": "", "diag": [f"query_file_read_err={e!r}"]}
            print(json.dumps(out, ensure_ascii=False))
            return
    else:
        title = raw or "test"

    out = {"type": "none", "lines": [], "lrc": "", "diag": []}
    try:
        q = urllib.parse.urlencode({"track_name": title, "artist_name": artist or title})
        s = json.loads(http_get(LRCLIB + "?" + q))
        if not s:
            out["diag"].append("lrclib: no results")
            print(json.dumps(out, ensure_ascii=False))
            return

        nart = norm(artist)
        nalb = norm(album)
        ntitle = norm(title)
        best = None
        for c in s:
            cn = norm(c.get("trackName", ""))
            ca = norm(c.get("artistName", ""))
            if ntitle and cn != ntitle and ntitle not in cn and cn not in ntitle:
                continue
            if nart and ca and (nart in ca or ca in nart):
                best = c
                break
            if nalb and norm(c.get("albumName", "")) == nalb:
                best = c
                break
            if best is None:
                best = c
        if best is None:
            best = s[0]

        lrc = best.get("syncedLyrics") or best.get("plainLyrics") or ""
        if not lrc:
            out["diag"].append("lrclib: empty lyrics")
            print(json.dumps(out, ensure_ascii=False))
            return
        out["lrc"] = lrc
        out["type"] = "lrc"
        out["diag"].append(f"lrclib: {best.get('trackName')} / {best.get('artistName')} synced={bool(best.get('syncedLyrics'))}")
        print(json.dumps(out, ensure_ascii=False))
    except Exception as e:
        out["diag"].append(f"lrclib ERR: {e!r}")
        print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
