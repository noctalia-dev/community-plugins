#!/usr/bin/env python3
"""Standalone, standard-library lyric source adapter for the Noctalia plugin."""

import base64
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

try:
    import ssl  # noqa: F401
    SSL_AVAILABLE = True
except ImportError:
    SSL_AVAILABLE = False

from music_sources import CatalogueClient, decode_lyric, direct_song


USER_AGENT = "Noctalia-Lyrics/1.0"
TIME_TAG = re.compile(r"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]")
KRC_LINE = re.compile(r"^\[(\d+),(\d+)\](.*)$")
PREFIX_WORD = re.compile(r"(?:<|\()(\d+),(\d+)(?:,\d+)?(?:>|\))([^<(]*)")
SUFFIX_WORD = re.compile(r"(.*?)<(\d+),(\d+)(?:,\d+)?>")
QRC_SUFFIX_WORD = re.compile(r"(.*?)[(](\d+),(\d+)[)]")
ENHANCED_WORD = re.compile(r"<(?:(\d+):)?(\d{1,2}(?:[.:]\d{1,3})?)>([^<]*)")
META_TAG = re.compile(r"^\[(ar|al|ti|by|re|ve|length|offset):", re.I)
CREDIT_LINE = re.compile(r"^(词|曲|作词|作曲|编曲|制作人|lyricist|composer|arranger)\s*[:：]", re.I)

# Credit / production metadata labels. Lines that are only credits or production
# notes must never be displayed as lyrics, in any language or lyric format.
META_LABELS = (
    # Chinese
    "作词", "作詞", "作曲", "编曲", "編曲", "制作人", "製作人", "监制", "監製",
    "出品人", "出品方", "出品", "发行方", "發行方", "发行", "發行", "词曲", "詞曲",
    "和声", "和聲", "合声", "合音", "吉他", "贝斯", "貝斯", "鼓手", "鼓", "键盘", "鍵盤",
    "弦乐", "弦樂", "钢琴", "鋼琴", "录音师", "錄音師", "录音室", "錄音室",
    "录音", "錄音", "混音师", "混音師", "混音", "母带", "母帶", "制作", "製作",
    "配唱", "人声", "人聲", "乐器", "樂器", "演奏", "演唱", "监唱", "監唱",
    "统筹", "統籌", "企划", "企劃", "策划", "策劃", "文案", "设计", "設計",
    "封面", "摄影", "攝影", "导演", "導演", "后期", "後期", "字幕", "校对", "校對",
    "版权", "版權", "版权管理方", "版權管理方", "词版权管理方", "詞版權管理方",
    "曲版权管理方", "曲版權管理方", "录音版权", "錄音版權", "母带版权", "母帶版權",
    "词曲版权", "詞曲版權", "录音作品", "錄音作品", "录音作品及MV版权", "錄音作品及MV版權",
    "联合出品", "聯合出品",
    "制作公司", "製作公司", "唱片公司", "出版公司", "出版", "批准文号", "批准文號",
    "音乐出品", "音樂出品", "版权所有", "版權所有", "未经许可", "未經許可",
    "出品监制", "出品監製", "总监制", "總監製", "总策划", "總策劃", "总导演", "總導演",
    "制作统筹", "製作統籌", "音乐总监", "音樂總監", "艺术总监", "藝術總監",
    "出品公司", "发行公司", "發行公司", "联合发行", "聯合發行",
    "母带工程师", "母帶工程師", "混音工程师", "混音工程師", "录音工程师", "錄音工程師",
    "制作助理", "製作助理", "录音助理", "錄音助理", "混音助理",
    "词作者", "詞作者", "曲作者", "编曲人", "編曲人", "作词作曲", "作詞作曲",
    "歌词制作", "歌詞製作", "歌词提供", "歌詞提供", "歌词翻译", "歌詞翻譯",
    "翻译", "翻譯", "上传", "上傳", "贡献", "貢獻",
    # Japanese
    "作詞", "作曲", "編曲", "プロデュース", "プロデューサー", "ミックス", "マスタリング",
    "レコーディング", "コーラス", "演奏", "ギター", "ベース", "ドラム", "ピアノ", "ストリングス",
    # Korean
    "작사", "작곡", "편곡", "프로듀서", "믹싱", "마스터링", "레코딩", "보컬",
    "기타", "베이스", "드럼", "피아노",
)

META_LABELS_LATIN = (
    "lyrics", "lyric", "words", "music", "composed", "composer", "written", "writer",
    "produced", "producer", "arranged", "arranger", "mixed", "mixer", "mastered",
    "mastering", "recorded", "recording", "engineered", "vocals", "vocal", "guitars",
    "guitar", "bass", "drums", "drum", "piano", "keys", "keyboards", "strings",
    "synthesizer", "synth", "programming", "executive producer", "co-producer",
    "label", "publisher", "published", "copyright", "performed", "sung", "artwork",
    "design", "photography", "director", "video director", "recording engineer",
    "mixing engineer", "mastering engineer", "vocal producer", "background vocals",
    "string arrangement", "orchestration", "op", "sp",
    "lyricist", "lyricists", "songwriter", "songwriters", "songwriting",
    "composer", "composers", "arranger", "arrangers", "producer", "producers",
    "chorus", "orchestra", "management", "booking", "legal", "art direction",
    "illustration", "stylist", "subtitles", "translated", "romanized", "romanization",
    # French, German, Spanish, Portuguese
    "paroles", "musique", "composé", "composée", "écrit", "écrite", "produit",
    "producteur", "arrangé", "mixé", "masterisé", "interprète", "éditeur",
    "text", "musik", "komponiert", "geschrieben", "produziert", "gemixt",
    "gemastert", "gesang", "gitarre", "schlagzeug", "klavier", "verlag",
    "letra", "música", "compuesto", "escrito", "producido", "arreglado", "mezclado",
    "masterizado", "voz", "guitarra", "bajo", "batería", "editorial", "composto",
    "produzido", "arranjado", "mixado", "violão", "baixo", "bateria",
)


def _label_pattern(labels):
    unique = sorted({label for label in labels if label}, key=len, reverse=True)
    return "|".join(re.escape(label) for label in unique)


META_CJK_PATTERN = _label_pattern(META_LABELS)
META_LATIN_PATTERN = _label_pattern(META_LABELS_LATIN)
METADATA_LINE = re.compile(
    r"^\s*(?:"
    r"(?:" + META_CJK_PATTERN + r")\s*(?:[:：]|\s+by\s+|$)"
    r"|(?:" + META_CJK_PATTERN + r")(?:工程师|工程師|工程|编写|編寫|助理|老师|老師|团队|團隊|公司|工作室|厂牌|廠牌|制作|製作)\s*[:：]"
    r"|(?:" + META_LATIN_PATTERN + r")\b\s*(?:[:：]|\s+by\s+|$)"
    r"|(?:词|曲|歌)\s*[:：]"
    r"|(?:©|℗|\(c\)|\(p\))\s*\d{0,4}"
    r"|(?:courtesy of|under license(?: from)?|all rights reserved)\b"
    r"|(?:lyrics?|words?|music)\s*(?:&|and)\s*(?:lyrics?|words?|music)\s+by\b"
    r"|(?:written|composed|produced|arranged)\b(?:\s*(?:&|and|,)\s*(?:written|composed|produced|arranged))*\s+by\b"
    r"|(?:provided to youtube by|auto-generated by youtube|released by|distributed by|licensed to|under exclusive license to)\b"
    r")",
    re.I,
)
INSTRUMENTAL_LINE = re.compile(
    r"^(?:(?:纯音乐|純音樂)(?:[，,、\s]*(?:请欣赏|請欣賞))?|"
    r"请欣赏|請欣賞|暂无歌词|暫無歌詞|无歌词|無歌詞|"
    r"instrumental(?:\s+music)?|this (?:song|track) is (?:an )?instrumental|"
    r"此歌曲为没有填词的纯音乐|此歌曲為沒有填詞的純音樂)"
    r"[\s，,。.!！~～·…]*$",
    re.I,
)
DECORATIVE_LINE = re.compile(r"^[\s♪♫♬~～\-—…·.。,，、!！?？;；:：'\"“”‘’()（）\[\]【】]*$")


def empty(source, *diag):
    return {"type": "none", "source": source, "lines": [], "diag": list(diag)}


def ssl_missing(source):
    return empty(source, "python3: missing ssl module (_ssl); install full python3, not python3-minimal")


def clean_text(value):
    if value is None:
        return ""
    return html.unescape(str(value)).replace("\ufeff", "").strip()


def number(value, default=0):
    try:
        return int(float(value))
    except (TypeError, ValueError, OverflowError):
        return default


def is_metadata_line(text):
    """True for credit/production lines that must not be shown as lyrics."""
    value = clean_text(text)
    if not value:
        return False
    if DECORATIVE_LINE.match(value) or INSTRUMENTAL_LINE.match(value):
        return True
    return METADATA_LINE.match(value) is not None


def normalize(value):
    return "".join(c.lower() for c in clean_text(value) if c.isalnum())


def timestamp_ms(minutes, seconds):
    seconds = str(seconds).replace(":", ".")
    return int(round(number(minutes) * 60000 + float(seconds) * 1000))


def duration_ms(value):
    value = number(value, 0)
    if value <= 0:
        return 0
    # Track duration is commonly milliseconds, but MPRIS callers may send microseconds.
    return value // 1000 if value > 10_000_000 else value


def line(time=-1, duration=0, text="", translation="", romanization="", chars=None):
    visible = html.unescape(str(text or "")).replace("\ufeff", "")
    timings = [number(item) for item in (chars or [])]
    if len(timings) == len(visible):
        leading = len(visible) - len(visible.lstrip())
        timings = timings[leading:len(visible.rstrip())]
    else:
        # Word timings that do not align with the text cannot drive karaoke;
        # drop them so the widget falls back to line-by-line highlighting.
        timings = []
    if timings and (timings[0] < 0 or any(later < earlier for earlier, later in zip(timings, timings[1:]))):
        timings = []
    return {
        "time": number(time, -1),
        "duration": max(0, number(duration)),
        "text": clean_text(text),
        "translation": clean_text(translation),
        "romanization": clean_text(romanization),
        "chars": timings,
    }


def line_has_word_timing(item):
    """True when a line carries complete, monotonically increasing word timings."""
    if not isinstance(item, dict):
        return False
    chars = item.get("chars")
    text = item.get("text") or ""
    if not isinstance(chars, list) or len(chars) < 2 or len(chars) != len(text):
        return False
    previous = -1
    for value in chars:
        if not isinstance(value, (int, float)) or value < 0 or value < previous:
            return False
        previous = value
    return chars[-1] > chars[0]


def lyrics_quality(lines):
    timed = [item for item in lines if item.get("time", -1) >= 0]
    word_lines = [item for item in timed if line_has_word_timing(item)]
    coverage = round(len(word_lines) / len(timed), 3) if timed else 0.0
    word_synced = len(word_lines) >= 3 and coverage >= 0.6
    if not word_synced and len(word_lines) >= 2 and coverage >= 0.8:
        word_synced = True
    if timed and word_synced:
        sync = "word"
    elif timed:
        sync = "line"
    else:
        sync = "plain"
    return {
        "sync": sync,
        "word_lines": len(word_lines),
        "timed_lines": len(timed),
        "total_lines": len(lines),
        "coverage": coverage,
        "has_translation": any(clean_text(item.get("translation")) for item in lines),
        "has_romanization": any(clean_text(item.get("romanization")) for item in lines),
    }


def splayer_transmitted_lines(data, word_timed=None):
    if not isinstance(data, dict):
        return []

    def parse_lines(source_lines):
        if not isinstance(source_lines, list):
            return []
        result = []
        for line_index, source_line in enumerate(source_lines):
            if not isinstance(source_line, dict):
                continue
            start = number(source_line.get("startTime"), -1)
            end = number(source_line.get("endTime"), start)
            words = source_line.get("words") if isinstance(source_line.get("words"), list) else []
            text_parts, roman_parts, chars, word_timings = [], [], [], []
            for word in words:
                if not isinstance(word, dict):
                    continue
                text = html.unescape(str(word.get("word", ""))).replace("\ufeff", "")
                if not text:
                    continue
                word_start = number(word.get("startTime"), start)
                word_end = number(word.get("endTime"), word_start)
                text_parts.append(text)
                roman_word = clean_text(word.get("romanWord", word.get("romanization", "")))
                if roman_word:
                    roman_parts.append(roman_word)
                chars.extend(word_start + index * max(0, word_end - word_start) // max(1, len(text))
                             for index in range(len(text)))
                word_timings.append({"text": text, "start": word_start, "end": word_end,
                                     "romanization": roman_word})
            text = "".join(text_parts) or source_line.get("text", source_line.get("lyric", ""))
            # A single word spanning the line is how line-level (LRC) lyrics are
            # represented. Do not synthesize character timings from it.
            if word_timed is False or (word_timed is not True and len(word_timings) < 2):
                chars = []
            item = line(start, max(0, end - start), text,
                        source_line.get("translatedLyric", source_line.get("translation", "")),
                        source_line.get("romanLyric", source_line.get("romanization", ""))
                        or " ".join(roman_parts), chars)
            item["words"] = word_timings
            item["is_background"] = source_line.get(
                "isBG", source_line.get("isBg", source_line.get("isBackground"))) is True
            item["is_duet"] = source_line.get("isDuet") is True
            next_line = source_lines[line_index + 1] if line_index + 1 < len(source_lines) else None
            next_start = number(next_line.get("startTime"), -1) if isinstance(next_line, dict) else -1
            if len(word_timings) == 1 and end - start >= 7000 and abs(next_start - end) <= 50:
                word = word_timings[0]
                if abs(word["start"] - start) <= 50 and abs(word["end"] - end) <= 50:
                    item["duration_inferred"] = True
                    item["chars"] = []
            if item["text"] or item["translation"] or item["romanization"]:
                result.append(item)
        return finalize(result, number(data.get("duration"), 0))

    for key in ("yrcData", "lrcData"):
        parsed = parse_lines(data.get(key))
        if parsed:
            return parsed
    return []


def finalize(lines, total_duration=0):
    cleaned = []
    for item in lines or []:
        if not isinstance(item, dict):
            continue
        normalized = line(
            item.get("time", item.get("start", item.get("startTimeMs", -1))),
            item.get("duration", item.get("durationMs", 0)),
            item.get("text", item.get("words", item.get("lyric", ""))),
            item.get("translation", item.get("translated", "")),
            item.get("romanization", item.get("romanized", item.get("romaji", ""))),
            item.get("chars", item.get("charTimes", [])),
        )
        if isinstance(item.get("words"), list):
            normalized["words"] = item["words"]
        if item.get("is_background") is True:
            normalized["is_background"] = True
        if item.get("is_duet") is True:
            normalized["is_duet"] = True
        if item.get("duration_inferred") is True:
            normalized["duration_inferred"] = True
        if normalized["text"] and is_metadata_line(normalized["text"]):
            continue
        if normalized["text"] or normalized["translation"] or normalized["romanization"]:
            cleaned.append(normalized)
    cleaned.sort(key=lambda item: (item["time"] < 0, item["time"] if item["time"] >= 0 else 0))
    for index, item in enumerate(cleaned):
        if item["duration"] > 0 or item["time"] < 0:
            continue
        next_time = next(
            (other["time"] for other in cleaned[index + 1:] if other["time"] > item["time"]),
            total_duration if total_duration > item["time"] else 0,
        )
        if next_time:
            item["duration"] = max(0, next_time - item["time"])
            item["duration_inferred"] = True
    return cleaned


def merge_timed(primary, secondary, field, tolerance=500):
    if not primary or not secondary:
        return primary
    untimed = [item for item in secondary if item.get("time", -1) < 0]
    timed = [item for item in secondary if item.get("time", -1) >= 0]
    primary_timed = [item for item in primary if item.get("time", -1) >= 0]
    # Providers often ship the translation layer for the same lyric lines with a
    # slightly different timestamp offset. When both sides have exactly the same
    # number of timed lines, pair them by order; nearest-time matching would
    # drop most lines once the drift exceeds the tolerance.
    if timed and len(timed) == len(primary_timed):
        aligned = all(
            abs(target.get("time", 0) - candidate.get("time", 0)) <= 5000
            for target, candidate in zip(primary_timed, timed)
        )
        if aligned:
            for target, candidate in zip(primary_timed, timed):
                value = candidate.get("text", "")
                if value and not target.get(field):
                    target[field] = value
            for index, target in enumerate(primary):
                if target.get("time", -1) < 0 and index < len(untimed):
                    value = untimed[index].get("text", "")
                    if value and not target.get(field):
                        target[field] = value
            return primary
    for index, target in enumerate(primary):
        value = ""
        if target.get("time", -1) >= 0 and timed:
            candidate = min(timed, key=lambda item: abs(item["time"] - target["time"]))
            if abs(candidate["time"] - target["time"]) <= tolerance:
                value = candidate.get("text", "")
        elif index < len(untimed):
            value = untimed[index].get("text", "")
        if value and not target.get(field):
            target[field] = value
    return primary


def dedupe_timed_lines(lines):
    """Keep one Musixmatch subtitle entry per timestamp."""
    result = []
    seen_times = set()
    for item in lines or []:
        text = clean_text(item.get("text", ""))
        if not text:
            continue
        timestamp = item.get("time", -1)
        if timestamp in seen_times:
            continue
        seen_times.add(timestamp)
        item = dict(item)
        item["text"] = text
        result.append(item)
    return result


def parse_plain(text):
    return [
        line(-1, text=value)
        for value in str(text or "").splitlines()
        if clean_text(value) and not META_TAG.match(value.strip()) and not is_metadata_line(value)
    ]


def parse_lrc(text):
    text = str(text or "").replace("\r\n", "\n").replace("\r", "\n")
    offset = 0
    match = re.search(r"\[offset:([+-]?\d+)\]", text, re.I)
    if match:
        offset = number(match.group(1))
    result = []
    for raw in text.splitlines():
        raw = raw.strip()
        if not raw or META_TAG.match(raw):
            continue
        krc = KRC_LINE.match(raw)
        if krc:
            start, duration, body = number(krc.group(1)), number(krc.group(2)), krc.group(3)
            words = PREFIX_WORD.findall(body) if re.match(r"^[<(]\d+,", body) else []
            absolute_word_times = body.startswith("(")
            if words:
                pieces = [(word, number(word_offset), number(word_duration))
                          for word_offset, word_duration, word in words]
            else:
                suffix_words = SUFFIX_WORD.findall(body)
                if not suffix_words:
                    suffix_words = QRC_SUFFIX_WORD.findall(body)
                    absolute_word_times = bool(suffix_words)
                pieces = [(word, number(word_offset), number(word_duration))
                          for word, word_offset, word_duration in suffix_words]
            if pieces:
                content, chars = "", []
                for word, word_offset, word_duration in pieces:
                    word = html.unescape(word)
                    for index, character in enumerate(word):
                        content += character
                        word_start = word_offset if absolute_word_times else start + word_offset
                        chars.append(word_start + offset + (index * word_duration // max(1, len(word))))
                if clean_text(content):
                    if not is_metadata_line(content):
                        result.append(line(start + offset, duration, content, chars=chars))
                    continue
            if clean_text(body) and not is_metadata_line(body):
                result.append(line(start + offset, duration, body))
            continue
        tags = list(TIME_TAG.finditer(raw))
        if not tags:
            continue
        body = TIME_TAG.sub("", raw).strip()
        enhanced = list(ENHANCED_WORD.finditer(body))
        visible = clean_text(ENHANCED_WORD.sub(lambda item: item.group(3), body)) if enhanced else clean_text(body)
        if not visible:
            continue
        for tag in tags:
            start = timestamp_ms(tag.group(1), tag.group(2)) + offset
            if is_metadata_line(visible) or (start <= 1000 and " - " in visible):
                continue
            chars = []
            if enhanced:
                for word in enhanced:
                    word_time = timestamp_ms(word.group(1) or tag.group(1), word.group(2)) + offset
                    chars.extend([word_time] * len(word.group(3)))
            result.append(line(start, text=visible, chars=chars))
    return finalize(result)


def parse_time_expression(value):
    value = clean_text(value)
    if not value:
        return -1
    if value.endswith("ms"):
        return number(value[:-2], -1)
    if value.endswith("s"):
        try:
            return int(float(value[:-1]) * 1000)
        except ValueError:
            return -1
    parts = value.split(":")
    try:
        if len(parts) == 3:
            return int((float(parts[0]) * 3600 + float(parts[1]) * 60 + float(parts[2])) * 1000)
        if len(parts) == 2:
            return int((float(parts[0]) * 60 + float(parts[1])) * 1000)
        return int(float(value) * 1000)
    except ValueError:
        return -1


def ttml_char_times(node, fallback_time):
    """Build one timestamp per visible character, including text between spans."""
    timeline = []

    def visit(element, inherited):
        if element.text:
            timeline.append((element.text, inherited))
        for child in element:
            name = child.tag.rsplit("}", 1)[-1]
            child_time = inherited
            if name == "span":
                parsed = parse_time_expression(child.attrib.get("begin", ""))
                if parsed >= 0:
                    child_time = parsed
            visit(child, child_time)
            if child.tail:
                timeline.append((child.tail, inherited))

    visit(node, fallback_time if fallback_time >= 0 else 0)
    if not timeline:
        return []
    raw = "".join(chunk for chunk, _ in timeline)
    times = []
    for chunk, timestamp in timeline:
        times.extend([timestamp] * len(chunk))
    if len(times) != len(raw):
        return []
    leading = len(raw) - len(raw.lstrip())
    visible = raw.strip()
    return times[leading:leading + len(visible)]


def parse_ttml(text):
    try:
        root = ET.fromstring(text)
    except (ET.ParseError, TypeError):
        return []
    result = []
    for node in root.iter():
        if node.tag.rsplit("}", 1)[-1] != "p":
            continue
        start = parse_time_expression(node.attrib.get("begin", ""))
        end = parse_time_expression(node.attrib.get("end", ""))
        content = clean_text("".join(node.itertext()))
        if not content:
            continue
        chars = ttml_char_times(node, start)
        role = " ".join(str(value) for key, value in node.attrib.items() if "role" in key.lower()).lower()
        item = line(start, max(0, end - start) if end >= start >= 0 else 0, content, chars=chars)
        if "translation" in role:
            item["_kind"] = "translation"
        elif "roman" in role:
            item["_kind"] = "romanization"
        result.append(item)
    primary = [item for item in result if not item.get("_kind")]
    translations = [item for item in result if item.get("_kind") == "translation"]
    romanizations = [item for item in result if item.get("_kind") == "romanization"]
    if not primary:
        primary = translations or romanizations
    merge_timed(primary, translations, "translation")
    merge_timed(primary, romanizations, "romanization")
    for item in primary:
        item.pop("_kind", None)
    return finalize(primary)


def qrc_content(text):
    text = str(text or "").strip()
    if not text.startswith("<"):
        return text
    try:
        root = ET.fromstring(text)
        for node in root.iter():
            for key, value in node.attrib.items():
                if key.rsplit("}", 1)[-1].lower() == "lyriccontent":
                    return value
    except ET.ParseError:
        pass
    match = re.search(r'LyricContent\s*=\s*"([\s\S]*?)"\s*/?>', text, re.I)
    return html.unescape(match.group(1)) if match else text


def first_value(data, names):
    if isinstance(data, dict):
        for name in names:
            if name in data and data[name] not in (None, "", [], {}):
                return data[name]
        for value in data.values():
            found = first_value(value, names)
            if found not in (None, "", [], {}):
                return found
    elif isinstance(data, list):
        for value in data:
            found = first_value(value, names)
            if found not in (None, "", [], {}):
                return found
    return None


def parse_json_lines(value):
    if isinstance(value, str):
        stripped = value.strip()
        if stripped.startswith("<") and ("<tt" in stripped[:300] or "<p" in stripped[:300]):
            return parse_ttml(stripped)
        if "[" in stripped and (TIME_TAG.search(stripped) or KRC_LINE.search(stripped)):
            return parse_lrc(stripped)
        return parse_plain(stripped)
    if isinstance(value, dict):
        direct = first_value(value, ("lines", "lyricLines", "lyricsLines", "sentences"))
        if direct is not None and direct is not value:
            parsed = parse_json_lines(direct)
            if parsed:
                return parsed
        lyric = first_value(value, ("syncedLyrics", "synced_lyrics", "subtitle_body", "ttml", "lyric", "lyrics", "lrc", "content"))
        if lyric is not None and lyric is not value:
            return parse_json_lines(lyric)
        return []
    if not isinstance(value, list):
        return []
    result = []
    for item in value:
        if isinstance(item, str):
            result.append(line(-1, text=item))
            continue
        if not isinstance(item, dict):
            continue
        start = first_value(item, ("time", "start", "startTime", "startTimeMs", "start_time", "begin", "timestamp"))
        duration = first_value(item, ("duration", "durationMs", "duration_ms"))
        end = first_value(item, ("end", "endTime", "endTimeMs", "end_time"))
        text = first_value(item, ("text", "words", "lyric", "content", "line"))
        translation = first_value(item, ("translation", "translated", "translatedLyric"))
        romanization = first_value(item, ("romanization", "romanized", "romaji", "transliteration"))
        if isinstance(start, str) and (":" in start or start.endswith(("s", "ms"))):
            start = parse_time_expression(start)
        start = number(start, -1)
        duration = number(duration, 0)
        if not duration and end is not None:
            if isinstance(end, str) and (":" in end or end.endswith(("s", "ms"))):
                end = parse_time_expression(end)
            duration = max(0, number(end) - start)
        chars = first_value(item, ("chars", "charTimes", "syllables", "wordsTiming")) or []
        char_times = []
        if isinstance(chars, list):
            for char in chars:
                if isinstance(char, dict):
                    char_times.append(number(first_value(char, ("time", "start", "startTimeMs"))))
                elif isinstance(char, (int, float, str)):
                    char_times.append(number(char))
        result.append(line(start, duration, text, translation, romanization, char_times))
    return finalize(result)


def parse_payload(payload):
    if isinstance(payload, bytes):
        payload = payload.decode("utf-8", "replace")
    if isinstance(payload, str):
        stripped = payload.strip().lstrip("\ufeff")
        if stripped.startswith("<"):
            parsed = parse_ttml(stripped)
            if parsed:
                return parsed
        try:
            payload = json.loads(stripped)
        except (ValueError, TypeError):
            return parse_lrc(stripped) or parse_plain(stripped)
    return parse_json_lines(payload)


DEFAULT_FORMAT_PRIORITY = (
    "yrc", "qrc", "krc", "ttml", "richsync", "syllables",
    "enhanced_lrc", "lrc", "plain",
)

# Formats each source can actually produce. The global priority chain is
# intersected with this list so a source never tries a format it cannot decode.
SOURCE_FORMATS = {
    "netease": ("yrc", "krc", "lrc", "plain"),
    "netease_public": ("yrc", "krc", "lrc", "plain"),
    "qq": ("qrc", "lrc", "plain"),
    "qqmusic": ("qrc", "lrc", "plain"),
    "kugou": ("krc", "lrc", "plain"),
    "splayer": ("yrc", "lrc", "plain"),
    "splayer_next": ("yrc", "lrc", "plain"),
    "splayer-next": ("yrc", "lrc", "plain"),
    "apple": ("ttml", "plain"),
    "apple_music": ("ttml", "plain"),
    "spotify": ("syllables", "lrc", "plain"),
    "musixmatch": ("richsync", "lrc", "plain"),
    "lrclib": ("enhanced_lrc", "lrc", "plain"),
    "qishui": ("ttml", "enhanced_lrc", "lrc", "plain"),
    "custom": ("ttml", "enhanced_lrc", "lrc", "plain"),
    "external": ("ttml", "enhanced_lrc", "lrc", "plain"),
}


def format_chain(options):
    raw = options.get("format_priority") if isinstance(options, dict) else None
    chain = []
    if isinstance(raw, (list, tuple)):
        for item in raw:
            name = clean_text(item).lower()
            if name and name not in chain:
                chain.append(name)
    return chain or list(DEFAULT_FORMAT_PRIORITY)


def source_format_order(source, options=None):
    options = options if isinstance(options, dict) else {}
    available = list(SOURCE_FORMATS.get(source, ("lrc", "plain")))
    chosen = None
    override = options.get("source_format_priority")
    if isinstance(override, dict):
        value = override.get(source)
        if isinstance(value, (list, tuple)):
            chosen = [clean_text(item).lower() for item in value if clean_text(item)]
    if not chosen:
        chosen = format_chain(options)
    ordered = []
    for name in chosen:
        if name in available and name not in ordered:
            ordered.append(name)
    for name in available:
        if name not in ordered:
            ordered.append(name)
    return ordered


def parse_lyric_text(text):
    raw = str(text or "")
    if not raw.strip():
        return [], "plain"
    lines = parse_lrc(raw)
    if lines:
        if any(KRC_LINE.match(item.strip()) for item in raw.splitlines() if item.strip()):
            return lines, "krc"
        if any(item.get("chars") for item in lines):
            return lines, "enhanced_lrc"
        return lines, "lrc"
    plain = parse_plain(raw)
    return (plain, "plain") if plain else ([], "plain")


def parse_payload_with_format(payload):
    if isinstance(payload, bytes):
        payload = payload.decode("utf-8", "replace")
    if isinstance(payload, str):
        stripped = payload.strip().lstrip("\ufeff")
        if stripped.startswith("<"):
            parsed = parse_ttml(stripped)
            if parsed:
                return parsed, "ttml"
        try:
            payload = json.loads(stripped)
        except (ValueError, TypeError):
            return parse_lyric_text(stripped)
    if isinstance(payload, dict):
        lyric_data = first_value(payload, ("ttml", "syllableLyrics", "syncedLyrics"))
        if isinstance(lyric_data, str) and lyric_data.strip().startswith("<"):
            parsed = parse_ttml(lyric_data)
            if parsed:
                return parsed, "ttml"
    lines = parse_json_lines(payload)
    if not lines:
        return [], "plain"
    if any(line_has_word_timing(item) for item in lines):
        return lines, "syllables"
    return lines, "lrc"


def request_data(url, headers=None, data=None, method=None, timeout=15):
    safe_headers = {"User-Agent": USER_AGENT, "Accept": "application/json, text/plain, application/xml, text/xml"}
    safe_headers.update(headers or {})
    body = None
    if data is not None:
        body = data if isinstance(data, bytes) else urllib.parse.urlencode(data).encode("utf-8")
    request = urllib.request.Request(url, data=body, headers=safe_headers, method=method)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read(2_000_001)
        if len(body) > 2_000_000:
            raise ValueError("source response exceeds size limit")
        return body, response.headers.get_content_charset() or "utf-8"


def request_json(url, headers=None, data=None, method=None, timeout=15):
    body, charset = request_data(url, headers, data, method, timeout)
    text = body.decode(charset, "replace").strip().lstrip("\ufeff")
    wrapped = re.fullmatch(r"[A-Za-z_$][\w.$]*\s*\(([\s\S]*)\)\s*;?", text)
    if wrapped:
        text = wrapped.group(1)
    return json.loads(text)


def query_url(base, params):
    return base + ("&" if "?" in base else "?") + urllib.parse.urlencode(params)


def best_match(items, track, title_key, artist_key, album_key=None):
    if not items:
        return None
    wanted_title, wanted_artist, wanted_album = map(normalize, (
        track.get("title"), track.get("artist"), track.get("album")
    ))
    best, best_score = None, -1
    for item in items:
        title = normalize(title_key(item))
        artist = normalize(artist_key(item))
        album = normalize(album_key(item)) if album_key else ""
        score = 0
        if wanted_title and title:
            title_score = 6 if title == wanted_title else 3 if wanted_title in title or title in wanted_title else 0
            if title_score == 0:
                continue
            score += title_score
        if wanted_artist and artist:
            score += 4 if artist == wanted_artist else 2 if wanted_artist in artist or artist in wanted_artist else 0
        if wanted_album and album:
            score += 2 if album == wanted_album else 1 if wanted_album in album or album in wanted_album else 0
        if score > best_score:
            best, best_score = item, score
    return best if best_score >= 3 else None


def lrclib_candidates(items, track):
    wanted_title, wanted_artist, wanted_album = map(normalize, (
        track.get("title"), track.get("artist"), track.get("album")
    ))
    wanted_duration = duration_ms(track.get("duration")) / 1000
    ranked = []
    seen_ids = set()
    for index, item in enumerate(items if isinstance(items, list) else []):
        if not isinstance(item, dict):
            continue
        candidate_id = clean_text(item.get("id"))
        if not candidate_id or candidate_id in seen_ids:
            continue
        synced = bool(clean_text(item.get("syncedLyrics")))
        plain = bool(clean_text(item.get("plainLyrics")))
        if not synced and not plain:
            continue

        title = normalize(item.get("trackName"))
        artist = normalize(item.get("artistName"))
        album = normalize(item.get("albumName"))
        if wanted_title and not title:
            continue
        identity_score = 0
        if wanted_title and title:
            title_score = 6 if title == wanted_title else 3 if wanted_title in title or title in wanted_title else 0
            if title_score == 0:
                continue
            identity_score += title_score
        if wanted_artist and artist:
            artist_score = 4 if artist == wanted_artist else 2 if wanted_artist in artist or artist in wanted_artist else 0
            if artist_score == 0:
                continue
            identity_score += artist_score
        if wanted_album and album:
            identity_score += 2 if album == wanted_album else 1 if wanted_album in album or album in wanted_album else 0

        candidate_duration = number(item.get("duration"), 0)
        duration_bucket = 5
        duration_difference = float("inf")
        if wanted_duration > 0 and candidate_duration > 0:
            duration_difference = abs(wanted_duration - candidate_duration)
            if duration_difference <= 2:
                duration_bucket = 0
            elif duration_difference <= 5:
                duration_bucket = 1
            elif duration_difference <= 10:
                duration_bucket = 2
            elif duration_difference <= 20:
                duration_bucket = 3
            else:
                duration_bucket = 4

        if identity_score >= 3:
            seen_ids.add(candidate_id)
            # Duration closeness wins over album identity: a version that is
            # several seconds longer than the playing track will not stay in
            # sync even when its album name matches exactly.
            ranked.append((
                duration_bucket,
                -int(synced),
                -identity_score,
                duration_difference,
                index,
                item,
            ))

    ranked.sort(key=lambda entry: entry[:-1])
    return [entry[-1] for entry in ranked]


def lrclib_candidate_metadata(item):
    return {
        "id": clean_text(item.get("id")),
        "track_name": clean_text(item.get("trackName")),
        "artist_name": clean_text(item.get("artistName")),
        "album_name": clean_text(item.get("albumName")),
        "duration": max(0, number(item.get("duration"), 0)),
        "synced": bool(clean_text(item.get("syncedLyrics"))),
        "format": "lrc" if clean_text(item.get("syncedLyrics")) else "plain",
        "source": "lrclib",
    }


def first_cover(*values):
    for value in values:
        if isinstance(value, dict):
            nested = first_cover(
                value.get("url"), value.get("cover"), value.get("coverUrl"), value.get("picUrl"),
                value.get("img"), value.get("image"), value.get("artwork"), value.get("albumArt"),
            )
            if nested:
                return nested
            continue
        if isinstance(value, list):
            for item in value:
                nested = first_cover(item)
                if nested:
                    return nested
            continue
        text = clean_text(value)
        if text.startswith("//"):
            text = "https:" + text
        if text.startswith("http://") or text.startswith("https://") or text.startswith("file://"):
            return text
    return ""


def itunes_cover(track):
    term = " ".join(filter(None, (clean_text(track.get("title")), clean_text(track.get("artist")))))
    if not term:
        return ""
    try:
        data = request_json(query_url("https://itunes.apple.com/search", {
            "term": term, "media": "music", "entity": "song", "limit": 5,
        }))
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ValueError):
        return ""
    results = data.get("results") if isinstance(data, dict) else None
    if not isinstance(results, list):
        return ""
    best = best_match(
        results, track,
        lambda x: x.get("trackName", ""),
        lambda x: x.get("artistName", ""),
        lambda x: x.get("collectionName", ""),
    )
    if not best:
        return ""
    url = clean_text(best.get("artworkUrl100") or best.get("artworkUrl60"))
    if not url:
        return ""
    return re.sub(r"/\d+x\d+bb\.", "/400x400bb.", url)


def success(source, lines, diag, total=0, cover="", format="lrc"):
    lines = finalize(lines, total)
    if not lines:
        return empty(source, *diag)
    stats = lyrics_quality(lines)
    if stats["sync"] == "plain":
        format = "plain"
    elif format == "plain":
        format = "lrc"
    payload = {
        "type": "lyrics",
        "source": source,
        "lines": lines,
        "diag": list(diag) + [format + " " + stats["sync"]],
        "format": format,
    }
    payload.update(stats)
    cover = clean_text(cover)
    if cover:
        payload["cover"] = cover
    return payload


def adapter_lrclib(track, credentials, options):
    source = "lrclib"
    params = {"track_name": track.get("title", ""), "artist_name": track.get("artist", "")}
    if track.get("album"):
        params["album_name"] = track["album"]
    data = request_json(query_url("https://lrclib.net/api/search", params))
    matches = lrclib_candidates(data, track)
    requested_id = clean_text(options.get("lyrics_candidate_id"))
    best = next((item for item in matches if clean_text(item.get("id")) == requested_id), None)
    if requested_id and best is None:
        return empty(source, "lrclib: requested match unavailable")
    if best is None and matches:
        best = matches[0]
    if not best:
        return empty(source, "lrclib: no match")
    lyrics = best.get("syncedLyrics") or best.get("plainLyrics") or ""
    lines, format_name = parse_lyric_text(lyrics)
    response = success(
        source, lines, ["lrclib: match"],
        duration_ms(track.get("duration")), itunes_cover(track), format_name,
    )
    if response.get("type") == "lyrics":
        if options.get("collect_candidates", True):
            response["candidates"] = [lrclib_candidate_metadata(item) for item in matches]
        response["selected_candidate_id"] = clean_text(best.get("id"))
    return response


def lyric_field(payload, name):
    value = payload.get(name, "")
    return decode_lyric(value.get("lyric", "") if isinstance(value, dict) else value)


def source_field_text(payload, source, format_name):
    if source in ("netease", "netease_public"):
        field = {"yrc": "yrc", "krc": "klyric", "lrc": "lrc", "plain": "lrc"}.get(format_name)
    else:
        field = {"qrc": "qrc", "lrc": "lyric", "plain": "lyric"}.get(format_name)
    if not field:
        return ""
    return qrc_content(lyric_field(payload, field))


def extract_source_lines(payload, source, format_name):
    content = source_field_text(payload, source, format_name)
    if not content:
        return []
    if format_name == "plain":
        # Do not display HTML error pages or metadata-only payloads as lyrics.
        if content.startswith(("<", "{")):
            return []
        return parse_plain(content)
    return parse_lrc(content)


def provider_lines_with_format(payload, source, options=None):
    lines = []
    chosen = "plain"
    for format_name in source_format_order(source, options):
        try:
            candidate = extract_source_lines(payload, source, format_name)
        except (ValueError, TypeError, ET.ParseError):
            candidate = []
        if candidate:
            lines, chosen = candidate, format_name
            break
    if source in ("netease", "netease_public"):
        translation_fields = ("ytlrc", "ytrans", "ytlyric", "tlyric")
        romanization_fields = ("yromalrc", "romalrc")
    else:
        translation_fields = ("trans", "tlyric")
        romanization_fields = ("roma", "romalrc")
    for field, names in (("translation", translation_fields), ("romanization", romanization_fields)):
        # Merge every available layer so a partially populated field (for example
        # NetEase's ytlrc) does not hide a full tlyric/romalrc layer.
        for name in names:
            try:
                secondary = parse_lrc(lyric_field(payload, name))
            except (ValueError, TypeError, ET.ParseError):
                secondary = []
            if secondary:
                merge_timed(lines, secondary, field)
    return lines, chosen


def provider_lines(payload, source, options=None):
    """Backward-compatible accessor returning only the parsed lines."""
    return provider_lines_with_format(payload, source, options)[0]


def candidate_identity(song):
    return clean_text(song.get("mid") or song.get("id"))


def catalogue_candidate_metadata(song, source, track):
    identity = candidate_identity(song)
    if not identity:
        return None
    duration = number(song.get("duration"), 0)
    if duration <= 0:
        duration = duration_ms(track.get("duration"))
    elif duration > 1000:
        duration = int(duration / 1000)
    return {
        "id": identity,
        "track_name": clean_text(song.get("title")) or clean_text(track.get("title")),
        "artist_name": clean_text(song.get("artist")) or clean_text(track.get("artist")),
        "album_name": clean_text(song.get("album")) or clean_text(track.get("album")),
        "duration": max(0, int(duration)),
        "synced": None,
        "source": source,
    }


def catalogue_candidates(songs, source, track):
    candidates, seen = [], set()
    for song in songs if isinstance(songs, list) else []:
        if not isinstance(song, dict):
            continue
        identity = candidate_identity(song)
        if not identity or identity in seen:
            continue
        seen.add(identity)
        metadata = catalogue_candidate_metadata(song, source, track)
        if metadata:
            candidates.append(metadata)
    return candidates


def adapter_catalogue(track, source, options=None):
    options = options if isinstance(options, dict) else {}
    client = CatalogueClient(request_json, source)
    requested_id = clean_text(options.get("lyrics_candidate_id"))
    collect = bool(options.get("collect_candidates", False))
    direct = direct_song(track, source)
    songs = []
    seen = set()
    # A direct player URL can fetch its lyrics without searching. Only pay for
    # the extra search request when collecting alternates or resolving a
    # requested candidate.
    source_songs = client.search(track) if (collect or requested_id or not direct) else []
    for song in ([direct] if direct else []) + source_songs:
        if not isinstance(song, dict):
            continue
        identity = candidate_identity(song)
        if not identity or identity in seen:
            continue
        seen.add(identity)
        songs.append(song)
    if not songs:
        return empty(source, source + ": no match", *client.diag[-3:])
    candidates = catalogue_candidates(songs, source, track) if collect else []
    selected = requested_id
    if requested_id:
        songs = [song for song in songs if candidate_identity(song) == requested_id]
        if not songs:
            return empty(source, source + ": requested match unavailable")
    for song in songs:
        for payload in client.lyric_responses(song):
            lines, format_name = provider_lines_with_format(payload, source, options)
            if lines:
                response = success(source, lines,
                                   [source + ": match " + candidate_identity(song)],
                                   duration_ms(track.get("duration")), song.get("cover", ""), format_name)
                if collect:
                    response["candidates"] = candidates
                response["selected_candidate_id"] = candidate_identity(song)
                return response
    if requested_id:
        return empty(source, source + ": requested lyrics unavailable")
    return empty(source, source + ": lyrics unavailable", *client.diag[-3:])


def adapter_netease(track, credentials, options):
    return adapter_catalogue(track, "netease", options)


def adapter_qqmusic(track, credentials, options):
    return adapter_catalogue(track, "qqmusic", options)


def adapter_splayer(track, credentials, options):
    source = "splayer"
    base_url = clean_text(credentials.get("splayer_api_url")) or "http://127.0.0.1:25884"
    parsed_url = urllib.parse.urlsplit(base_url)
    if parsed_url.scheme not in ("http", "https") or not parsed_url.netloc:
        return empty(source, "splayer: invalid API URL")
    title = clean_text(track.get("title"))
    artist = clean_text(track.get("artist"))
    expected_duration = duration_ms(track.get("duration"))
    song_info_endpoint = base_url.rstrip("/") + "/api/control/song-info"
    last_state = "unavailable"
    for attempt in range(3):
        try:
            response = request_json(song_info_endpoint, timeout=1)
            current = response.get("data", {}) if isinstance(response, dict) else {}
            current_title = current.get("name", current.get("playName", ""))
            current_artist = current.get("artistName", current.get("artist", current.get("artists", "")))
            if isinstance(current_artist, list):
                current_artist = " ".join(
                    clean_text(item.get("name", item) if isinstance(item, dict) else item)
                    for item in current_artist
                )
            wanted_title = normalize(title)
            normalized_title = normalize(current_title)
            title_matches = normalized_title == wanted_title or (
                bool(normalized_title) and (normalized_title in wanted_title or wanted_title in normalized_title)
            )
            artist_matches = not artist or not current_artist or (
                normalize(artist) in normalize(current_artist) or normalize(current_artist) in normalize(artist)
            )
            if title_matches and artist_matches:
                lines = splayer_transmitted_lines(current)
                if lines:
                    format_name = "yrc" if any(item.get("chars") for item in lines) else "lrc"
                    cover = first_cover(
                        current.get("cover"), current.get("coverUrl"), current.get("picUrl"),
                        current.get("albumCover"), current.get("albumArt"), current.get("img"),
                        current.get("image"), current.get("al"),
                    )
                    return success(source, lines, ["splayer: transmitted lyrics"],
                                   expected_duration, cover, format_name)
                last_state = "loading" if current.get("lyricLoading") is True else "empty"
            else:
                last_state = "track not ready"
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ValueError):
            last_state = "API unavailable"
        if attempt < 2:
            time.sleep(0.4)
    return empty(source, "splayer: " + last_state)


def enrich_netease_layers(lines, payload, options):
    """Fill missing translation/romanization on SPlayer Next lines from NetEase.

    SPlayer Next can report word-timed lines while only carrying translations for
    a handful of them (its own layer merge is stricter). The same track is often
    available from NetEase with a complete tlyric/romalrc layer, so fill only the
    missing fields by a direct song-id request.
    """
    if not lines or not isinstance(payload, dict):
        return 0
    source = payload.get("source")
    if not isinstance(source, dict) or source.get("platform") != "netease":
        return 0
    track_id = clean_text(payload.get("trackId"))
    if not re.fullmatch(r"\d+", track_id):
        return 0
    missing_translation = sum(1 for item in lines if not item.get("translation"))
    missing_romanization = sum(1 for item in lines if not item.get("romanization"))
    if not missing_translation and not missing_romanization:
        return 0
    try:
        data = request_json(query_url("https://music.163.com/api/song/lyric/v1", {
            "id": track_id, "cp": "false", "lv": 0, "kv": 0, "tv": 0, "rv": 0,
            "yv": 0, "ytv": 0, "yrv": 0,
        }), {"Referer": "https://music.163.com/"}, timeout=5)
        secondary, _ = provider_lines_with_format(data, "netease", options)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ValueError, TypeError, ET.ParseError):
        return 0
    if not secondary:
        return 0
    before = sum(1 for item in lines if item.get("translation") or item.get("romanization"))
    translation_lines = [
        line(item.get("time", -1), text=item.get("translation", ""))
        for item in secondary if item.get("translation")
    ]
    romanization_lines = [
        line(item.get("time", -1), text=item.get("romanization", ""))
        for item in secondary if item.get("romanization")
    ]
    if translation_lines:
        merge_timed(lines, translation_lines, "translation")
    if romanization_lines:
        merge_timed(lines, romanization_lines, "romanization")
    after = sum(1 for item in lines if item.get("translation") or item.get("romanization"))
    return after - before


def adapter_splayer_next(track, credentials, options):
    source = "splayer_next"
    base_url = clean_text(credentials.get("splayer_next_api_url")) or "http://127.0.0.1:14558"
    parsed_url = urllib.parse.urlsplit(base_url)
    if parsed_url.scheme not in ("http", "https") or not parsed_url.netloc:
        return empty(source, "splayer_next: invalid API URL")
    base = base_url.rstrip("/")
    try:
        now_playing = request_json(base + "/api/now-playing", timeout=2)
        current = now_playing.get("track") if isinstance(now_playing, dict) else None
    except urllib.error.HTTPError as error:
        if error.code == 403:
            return empty(source, "splayer_next: external API disabled (enable it in SPlayer-Next settings)")
        return empty(source, "splayer_next: HTTP " + str(error.code))
    except (urllib.error.URLError, TimeoutError, ValueError):
        return empty(source, "splayer_next: API unavailable (start SPlayer-Next and enable its External API)")
    if not isinstance(current, dict):
        return empty(source, "splayer_next: no current track")

    current_title = clean_text(current.get("title", current.get("name", current.get("trackName", ""))))
    artists = current.get("artists")
    if isinstance(artists, list):
        current_artist = " / ".join(
            clean_text(item.get("name", item) if isinstance(item, dict) else item)
            for item in artists
        )
    else:
        current_artist = clean_text(current.get("artist", current.get("artistName", "")))
    album = current.get("album")
    if isinstance(album, dict):
        current_album = clean_text(album.get("name", ""))
        album_cover = album.get("cover", "")
    else:
        current_album = clean_text(album)
        album_cover = ""

    wanted_title = normalize(track.get("title"))
    normalized_title = normalize(current_title)
    title_matches = normalized_title == wanted_title or (
        bool(normalized_title) and (normalized_title in wanted_title or wanted_title in normalized_title)
    )
    wanted_artist = normalize(track.get("artist"))
    normalized_artist = normalize(current_artist)
    artist_matches = not wanted_artist or not normalized_artist or (
        wanted_artist in normalized_artist or normalized_artist in wanted_artist
    )
    if not title_matches or not artist_matches:
        return empty(source, "splayer_next: track not ready")

    try:
        payload = request_json(base + "/api/lyrics", timeout=2)
    except urllib.error.HTTPError as error:
        if error.code == 403:
            return empty(source, "splayer_next: external API disabled (enable it in SPlayer-Next settings)")
        return empty(source, "splayer_next: HTTP " + str(error.code))
    except (urllib.error.URLError, TimeoutError, ValueError):
        return empty(source, "splayer_next: API unavailable (start SPlayer-Next and enable its External API)")
    lyric = payload.get("lyric") if isinstance(payload, dict) else None
    if not isinstance(lyric, list) or not lyric:
        return empty(source, "splayer_next: lyrics unavailable")
    lyric_source = payload.get("source") if isinstance(payload, dict) else None
    word_timed = None
    if isinstance(lyric_source, dict) and "wordTimed" in lyric_source:
        word_timed = lyric_source.get("wordTimed") is True
    lines = splayer_transmitted_lines(
        {"yrcData": lyric, "duration": duration_ms(track.get("duration"))}, word_timed
    )
    if not lines:
        return empty(source, "splayer_next: lyrics unavailable")
    format_name = "yrc" if any(item.get("chars") for item in lines) else "lrc"
    cover = first_cover(
        current.get("cover"), current.get("coverOriginal"), album_cover,
        current.get("artwork"), current.get("image"), current.get("picUrl"),
    )
    diag = ["splayer_next: transmitted lyrics"]
    if word_timed is not None:
        diag.append("splayer_next: wordTimed=" + ("true" if word_timed else "false"))
    enriched = enrich_netease_layers(lines, payload, options)
    if enriched:
        diag.append("splayer_next: netease layers +" + str(enriched))
    return success(source, lines, diag, duration_ms(track.get("duration")), cover, format_name)


def adapter_kugou(track, credentials, options):
    source = "kugou"
    options = options if isinstance(options, dict) else {}
    requested_id = clean_text(options.get("lyrics_candidate_id"))
    keyword = " ".join(filter(None, (track.get("title"), track.get("artist"))))
    search = request_json(query_url("https://mobilecdn.kugou.com/api/v3/search/song", {
        "format": "json", "keyword": keyword, "page": 1, "pagesize": 10, "showtype": 1
    }))
    songs = search.get("data", {}).get("info", [])
    best = best_match(songs, track, lambda x: x.get("songname", x.get("filename", "")),
                      lambda x: x.get("singername", ""), lambda x: x.get("album_name", ""))
    if not best:
        return empty(source, "kugou: no match")
    cover = first_cover(best.get("album_sizable_cover"), best.get("imgUrl"), best.get("album_img"), best.get("cover"))
    if cover:
        cover = cover.replace("{size}", "400")
    versions = request_json(query_url("https://lyrics.kugou.com/search", {
        "ver": 1, "man": "yes", "client": "pc", "keyword": keyword,
        "duration": best.get("duration", duration_ms(track.get("duration"))), "hash": best.get("hash", "")
    })).get("candidates", [])
    if not versions:
        return empty(source, "kugou: lyrics unavailable")
    candidates = []
    for version in versions:
        candidate_id = clean_text(version.get("id"))
        if not candidate_id:
            continue
        duration = number(version.get("duration"), 0)
        candidates.append({
            "id": candidate_id,
            "track_name": clean_text(version.get("song")) or clean_text(best.get("songname", best.get("filename", ""))),
            "artist_name": clean_text(version.get("singer")) or clean_text(best.get("singername", "")),
            "album_name": clean_text(best.get("album_name", "")),
            "duration": max(0, int(duration / 1000)) if duration > 1000 else max(0, int(duration)),
            "synced": None,
            "source": source,
        })
    targets = versions
    selected_id = ""
    if requested_id:
        targets = [version for version in versions if clean_text(version.get("id")) == requested_id]
        if not targets:
            return empty(source, "kugou: requested match unavailable")
    for version in targets:
        data = request_json(query_url("https://lyrics.kugou.com/download", {
            "ver": 1, "client": "pc", "id": version.get("id"), "accesskey": version.get("accesskey"),
            "fmt": "lrc", "charset": "utf8"
        }))
        content = data.get("content", "")
        try:
            content = base64.b64decode(content).decode("utf-8", "replace")
        except (ValueError, TypeError):
            pass
        lines, format_name = parse_lyric_text(content)
        if lines:
            selected_id = clean_text(version.get("id"))
            response = success(source, lines, ["kugou: match " + selected_id],
                               duration_ms(track.get("duration")), cover, format_name)
            if options.get("collect_candidates", True):
                response["candidates"] = candidates
            response["selected_candidate_id"] = selected_id
            return response
    if requested_id:
        return empty(source, "kugou: requested lyrics unavailable")
    return empty(source, "kugou: lyrics unavailable")
def adapter_qishui(track, credentials, options):
    source = "qishui"
    template = clean_text(credentials.get("qishui_api_url"))
    if not template:
        return empty(source, "qishui: endpoint required")
    replacements = {key: urllib.parse.quote(str(track.get(key, "")), safe="") for key in ("title", "artist", "album")}
    try:
        url = template.format(**replacements)
    except (KeyError, ValueError):
        return empty(source, "qishui: invalid endpoint template")
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        return empty(source, "qishui: invalid endpoint")
    headers = {}
    if credentials.get("qishui_token"):
        headers["Authorization"] = "Bearer " + str(credentials["qishui_token"])
    body, charset = request_data(url, headers)
    lines, format_name = parse_payload_with_format(body.decode(charset, "replace"))
    return success(
        source, lines, ["qishui: response parsed"],
        duration_ms(track.get("duration")), itunes_cover(track), format_name,
    )


def spotify_token(credentials):
    token = clean_text(credentials.get("spotify_access_token"))
    if token:
        return token
    cookie = clean_text(credentials.get("spotify_sp_dc"))
    if not cookie:
        return ""
    data = request_json("https://open.spotify.com/get_access_token?reason=transport&productType=web_player",
                        {"Cookie": "sp_dc=" + cookie, "Referer": "https://open.spotify.com/"})
    return clean_text(data.get("accessToken"))


def adapter_spotify(track, credentials, options):
    source = "spotify"
    token = spotify_token(credentials)
    if not token:
        return empty(source, "spotify: credentials required")
    headers = {"Authorization": "Bearer " + token}
    search = request_json(query_url("https://api.spotify.com/v1/search", {
        "q": " ".join(filter(None, (track.get("title"), track.get("artist")))), "type": "track", "limit": 10
    }), headers)
    items = search.get("tracks", {}).get("items", [])
    best = best_match(items, track, lambda x: x.get("name", ""),
                      lambda x: " ".join(a.get("name", "") for a in x.get("artists", [])),
                      lambda x: x.get("album", {}).get("name", ""))
    if not best:
        return empty(source, "spotify: no match")
    album = best.get("album") if isinstance(best.get("album"), dict) else {}
    images = album.get("images") if isinstance(album.get("images"), list) else []
    cover = first_cover(images, album.get("image"), best.get("image"))
    data = request_json(query_url("https://spclient.wg.spotify.com/color-lyrics/v2/track/" + urllib.parse.quote(best["id"]), {
        "format": "json", "market": "from_token"
    }), headers)
    lines = parse_json_lines(data.get("lyrics", {}).get("lines", []))
    alternatives = data.get("lyrics", {}).get("alternatives", [])
    if alternatives and isinstance(alternatives[0], dict):
        merge_timed(lines, parse_json_lines(alternatives[0].get("lines", [])), "translation")
    format_name = "syllables" if any(item.get("chars") for item in lines) else "lrc"
    return success(source, lines, ["spotify: match"], duration_ms(track.get("duration")), cover, format_name)


def adapter_apple_music(track, credentials, options):
    source = "apple_music"
    developer = clean_text(credentials.get("apple_developer_token"))
    if not developer:
        return empty(source, "apple_music: developer token required")
    storefront = clean_text(credentials.get("apple_storefront")) or "us"
    if not re.fullmatch(r"[A-Za-z0-9-]+", storefront):
        return empty(source, "apple_music: invalid storefront")
    headers = {"Authorization": "Bearer " + developer, "Origin": "https://music.apple.com"}
    if credentials.get("apple_user_token"):
        headers["Music-User-Token"] = str(credentials["apple_user_token"])
    search = request_json(query_url("https://api.music.apple.com/v1/catalog/" + storefront + "/search", {
        "term": " ".join(filter(None, (track.get("title"), track.get("artist")))), "types": "songs", "limit": 10
    }), headers)
    songs = search.get("results", {}).get("songs", {}).get("data", [])
    best = best_match(songs, track, lambda x: x.get("attributes", {}).get("name", ""),
                      lambda x: x.get("attributes", {}).get("artistName", ""),
                      lambda x: x.get("attributes", {}).get("albumName", ""))
    if not best:
        return empty(source, "apple_music: no match")
    attrs = best.get("attributes") if isinstance(best.get("attributes"), dict) else {}
    artwork = attrs.get("artwork") if isinstance(attrs.get("artwork"), dict) else {}
    cover = ""
    template = clean_text(artwork.get("url"))
    if template:
        cover = template.replace("{w}", "400").replace("{h}", "400")
    cover = first_cover(cover, attrs.get("artworkUrl"), attrs.get("url"))
    body, charset = request_data(
        "https://amp-api.music.apple.com/v1/catalog/" + storefront + "/songs/" + urllib.parse.quote(str(best["id"])) + "/lyrics",
        headers,
    )
    text = body.decode(charset, "replace")
    try:
        payload = json.loads(text)
        lyric_data = first_value(payload, ("ttml", "syllableLyrics", "lyrics", "content"))
        if lyric_data is not None:
            lines, format_name = parse_payload_with_format(lyric_data)
        else:
            lines = parse_json_lines(payload)
            format_name = "syllables" if any(item.get("chars") for item in lines) else "lrc"
    except ValueError:
        lines = parse_ttml(text)
        format_name = "ttml"
    return success(source, lines, ["apple_music: match"], duration_ms(track.get("duration")), cover, format_name)


def adapter_musixmatch(track, credentials, options):
    source = "musixmatch"
    token = clean_text(credentials.get("musixmatch_token"))
    if not token:
        return empty(source, "musixmatch: usertoken required")
    params = {
        "app_id": "web-desktop-app-v1.0", "usertoken": token,
        "q_track": track.get("title", ""), "q_artist": track.get("artist", ""),
        "q_album": track.get("album", ""), "subtitle_format": "lrc", "page_size": 5,
    }
    language = clean_text(options.get("translation_language"))
    if language:
        params["selected_language"] = language
    data = request_json(query_url("https://apic-desktop.musixmatch.com/ws/1.1/macro.subtitles.get", params),
                        {"Origin": "https://www.musixmatch.com", "Referer": "https://www.musixmatch.com/"})
    subtitle = first_value(data, ("subtitle_body",))
    if not subtitle:
        return empty(source, "musixmatch: lyrics unavailable")
    lines = dedupe_timed_lines(parse_lrc(subtitle))
    translated = first_value(data, ("translation_list", "translations"))
    if isinstance(translated, list):
        translated_lines = []
        for item in translated:
            value = item.get("translation", item) if isinstance(item, dict) else item
            if isinstance(value, dict):
                text = value.get("description", value.get("translation", ""))
                time = value.get("time", value.get("matched_line", -1))
                translated_lines.append(line(time, text=text))
        merge_timed(lines, translated_lines, "translation")
    format_name = "enhanced_lrc" if any(item.get("chars") for item in lines) else "lrc"
    return success(
        source, lines, ["musixmatch: match"],
        duration_ms(track.get("duration")), itunes_cover(track), format_name,
    )


ADAPTERS = {
    "lrclib": adapter_lrclib,
    "netease": adapter_netease,
    "netease_public": adapter_netease,
    "qq": adapter_qqmusic,
    "qqmusic": adapter_qqmusic,
    "splayer": adapter_splayer,
    "splayer_next": adapter_splayer_next,
    "splayer-next": adapter_splayer_next,
    "kugou": adapter_kugou,
    "qishui": adapter_qishui,
    "apple": adapter_apple_music,
    "apple_music": adapter_apple_music,
    "spotify": adapter_spotify,
    "musixmatch": adapter_musixmatch,
}


def main():
    source = ""
    response = None
    if len(sys.argv) != 2:
        response = empty(source, "request: expected one file path")
    else:
        try:
            with open(sys.argv[1], "r", encoding="utf-8") as request_file:
                request = json.load(request_file)
            try:
                os.remove(sys.argv[1])
            except OSError:
                pass
        except FileNotFoundError:
            response = empty(source, "request: file not found")
        except (OSError, UnicodeError, json.JSONDecodeError):
            response = empty(source, "request: unreadable or invalid JSON")
        else:
            try:
                if not isinstance(request, dict):
                    response = empty(source, "request: invalid JSON object")
                else:
                    source = clean_text(request.get("source")).lower()
                    track = request.get("track") if isinstance(request.get("track"), dict) else {}
                    credentials = request.get("credentials") if isinstance(request.get("credentials"), dict) else {}
                    options = request.get("options") if isinstance(request.get("options"), dict) else {}
                    adapter = ADAPTERS.get(source)
                    if not adapter:
                        response = empty(source, "request: unknown source")
                    elif not clean_text(track.get("title")):
                        response = empty(source, "request: track title required")
                    elif not SSL_AVAILABLE and source not in ("splayer", "splayer_next", "splayer-next", "qishui"):
                        response = ssl_missing(source)
                    else:
                        response = adapter(track, credentials, options)
            except urllib.error.HTTPError as error:
                response = empty(source, "source: HTTP " + str(error.code))
            except (urllib.error.URLError, TimeoutError):
                response = ssl_missing(source) if not SSL_AVAILABLE else empty(source, "source: network failure")
            except (ValueError, ET.ParseError):
                response = empty(source, "source: invalid response")
            except Exception:
                response = empty(source, "source: unexpected failure")
    print(json.dumps(response or empty(source, "source: empty response"), ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
