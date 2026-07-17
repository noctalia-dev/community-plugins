#!/usr/bin/env python3
# Decode NetEase KRC ("klyric") dynamic lyrics into per-character timings.
# Reads the klyric field (base64 of "krc1" + zlib stream) from argv[1],
# writes JSON: {"type":"krc","lines":[{"time":ms,"text":"...","chars":[ms,...]}]}
import sys, json, base64, zlib, re

def find_zlib(buf):
    for i in range(len(buf) - 1):
        if buf[i] == 0x78 and buf[i + 1] in (0x01, 0x9c, 0xda):
            try:
                return zlib.decompress(buf[i:])
            except Exception:
                continue
    return None

def decode_krc(raw):
    if isinstance(raw, str) and re.search(r"^\[\d+,\d+\]", raw, re.MULTILINE):
        return raw
    data = None
    if isinstance(raw, str):
        try:
            data = base64.b64decode(raw)
        except Exception:
            data = raw.encode("latin-1")
    else:
        data = raw
    if data[:4] == b"krc1":
        data = data[4:]
    dec = find_zlib(data)
    if dec is None:
        return None
    try:
        return dec.decode("utf-8")
    except Exception:
        return dec.decode("utf-8", "ignore")

LINE_RE = re.compile(r"^\[(\d+),(\d+)\](.*)$")
PREFIX_SYL_RE = re.compile(r"(?:<|\()(\d+),(\d+)(?:,\d+)?(?:>|\))([^<(]*)")
SUFFIX_SYL_RE = re.compile(r"(.*?)<(\d+),(\d+)(?:,\d+)?>")

def parse_krc(text):
    out = []
    for line in text.splitlines():
        m = LINE_RE.match(line)
        if not m:
            continue
        start = int(m.group(1))
        dur = int(m.group(2))
        body = m.group(3)
        # NetEase has shipped both `(offset,duration,0)word` and
        # `word<offset,duration>` variants of its word-synced format.
        prefixed = PREFIX_SYL_RE.findall(body) if re.match(r"^[<(]\d+,", body) else []
        if prefixed:
            syl = [(word, int(offset), int(duration))
                   for offset, duration, word in prefixed]
        else:
            syl = [(word, int(offset), int(duration))
                   for word, offset, duration in SUFFIX_SYL_RE.findall(body)]
        if not syl and body.strip() != "":
            syl = [(body, 0, dur)]
        chars = []
        full = ""
        for (word, so, sd) in syl:
            n = len(word)
            if n == 0:
                continue
            for j in range(n):
                chars.append(start + so + (j * sd) // n)
                full += word[j]
        if full.strip() != "":
            out.append({"time": start, "duration": dur, "text": full, "chars": chars})
    return out

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"type": "none"}))
        return
    try:
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            raw = f.read()
    except Exception:
        print(json.dumps({"type": "none"}))
        return
    text = decode_krc(raw)
    if text is None:
        print(json.dumps({"type": "none"}))
        return
    print(json.dumps({"type": "krc", "lines": parse_krc(text)}, ensure_ascii=False))

if __name__ == "__main__":
    main()
