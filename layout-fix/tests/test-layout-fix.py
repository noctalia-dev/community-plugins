#!/usr/bin/env python3
"""Tests for the correction logic: re-encoding and the decision to correct.

Layout tables come from libxkbcommon for the layouts given on the command
line, so the suite exercises exactly what the daemon would do on a machine
configured that way:

    python3 tests/test-layout-fix.py            # us,ru
    python3 tests/test-layout-fix.py us,de      # any other pair

Cases are written as the *intended* word plus the layout it should have
been typed in; what appears on screen is derived from the real tables, so
the fixtures cannot drift away from the keymap.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "scripts", "layout-fix")
sys.argv = ["layout-fix-tests"]
exec(open(DAEMON).read().replace("sys.exit(main())", "pass"))  # noqa: S102

# (intended word, index of the layout it belongs to, should the daemon fix it)
CASES = [
    # Russian words typed while the US layout was active.
    ("привет", 1, True), ("как", 1, True), ("дела", 1, True),
    ("работает", 1, True), ("спасибо", 1, True), ("нормально", 1, True),
    ("хорошо", 1, True), ("пожалуйста", 1, True), ("компьютер", 1, True),
    ("программа", 1, True), ("клавиатура", 1, True), ("раскладка", 1, True),
    ("сообщение", 1, True), ("интересно", 1, True), ("время", 1, True),
    ("сегодня", 1, True), ("проверка", 1, True), ("тест", 1, True),
    # Colloquial words no dictionary lists: the candidate is rejected by
    # hunspell, so only the heuristics can save these.
    ("максималка", 1, True), ("движуха", 1, True), ("тестируем", 1, True),
    ("зачетно", 1, True), ("норимально", 1, True),
    # English words and commands typed in the US layout: never touch them.
    ("hello", 0, False), ("world", 0, False), ("please", 0, False),
    ("thanks", 0, False), ("keyboard", 0, False), ("message", 0, False),
    ("python", 0, False), ("docker", 0, False), ("systemctl", 0, False),
    ("grep", 0, False), ("install", 0, False), ("update", 0, False),
    ("terminal", 0, False), ("browser", 0, False), ("commit", 0, False),
    ("branch", 0, False), ("plugin", 0, False), ("config", 0, False),
    ("start", 0, False), ("server", 0, False), ("project", 0, False),
    # Identifiers no dictionary knows either: both sides are unknown words,
    # so the heuristics have to leave them alone.
    ("systemd", 0, False), ("kubectl", 0, False), ("noctalia", 0, False),
    ("hunspell", 0, False), ("pacman", 0, False), ("wayland", 0, False),
    ("keybinds", 0, False), ("upstream", 0, False),
    # Too short to judge.
    ("ls", 0, False), ("cd", 0, False), ("npm", 0, False),
    ("git", 0, False), ("ssh", 0, False), ("btw", 0, False),
    ("cli", 0, False), ("api", 0, False), ("cwd", 0, False),
    # Russian typed in the Russian layout: nothing to correct.
    ("привет", 1, False), ("работает", 1, False), ("спасибо", 1, False),
    ("сегодня", 1, False), ("проверка", 1, False), ("сообщение", 1, False),
]


def keystrokes(word, table):
    """The keys someone presses to type `word` in the layout of `table`."""
    by_char = {}
    for code, (plain, shifted) in table.items():
        by_char.setdefault(plain, (code, False))
        by_char.setdefault(shifted, (code, True))
    keys = []
    for char in word:
        entry = by_char.get(char)
        if entry is None:
            return None
        keys.append(entry)
    return keys


# Whole phrases typed in the wrong layout, and what should be on screen
# afterwards. These exercise the buffer and the lookback over short words,
# not just the per-word decision.
PHRASES = [
    # The short "а" is only fixed because the long word next to it was; the
    # layout switches after a correction, so the rest is typed correctly.
    ("а максималка ", 1, True),
    ("это работает ", 1, True),
    # Phrases typed in the layout they belong to must come out unchanged.
    ("git commit and push ", 0, False),
    ("a docker container ", 0, False),
    ("a hello world ", 0, False),
]


def phrase_check(watcher, tables, languages, phrase, home, wrong_layout):
    """Types `phrase` key by key and returns what ends up on screen."""
    other = next(i for i in sorted(tables) if i != home)
    keys = keystrokes(phrase, tables[home])
    if keys is None:
        return None
    screen, typed_in = [], other if wrong_layout else home

    def fake_retype(count, text):
        del screen[len(screen) - count:]
        screen.extend(text)
        return True

    def fake_switch(index):
        nonlocal typed_in
        typed_in = index

    def fake_target(_watcher):
        return (typed_in, home if typed_in != home else other,
                tables[typed_in], tables[home if typed_in != home else other],
                languages[typed_in], languages[home if typed_in != home else other])

    globals()["retype"], globals()["switch_layout"] = fake_retype, fake_switch
    globals()["target_layout"] = fake_target
    for code, shift in keys:
        screen.append(render([(code, shift)], tables[typed_in]))
        finished = watcher.feed(code, shift)
        if finished:
            autofix(watcher, finished, None if code in RESET_KEYS else code, shift)
    return "".join(screen)


def main():
    global SPELLER, LAYOUT_CODES
    requested = sys.argv[1] if len(sys.argv) > 1 else None
    if requested:
        LAYOUT_CODES = {index: code for index, code in enumerate(requested.split(","))}
    else:
        names, _ = niri_layouts()
        LAYOUT_CODES = layout_codes(names)
        if len(LAYOUT_CODES) < 2:
            LAYOUT_CODES = {0: "us", 1: "ru"}

    tables = build_tables(LAYOUT_CODES)
    if len(tables) < 2:
        print("need two layouts to test against")
        return 2
    languages = {i: dictionary_for(LAYOUT_CODES.get(i)) for i in tables}
    SPELLER = Speller([lang for lang in languages.values() if lang])
    print("layouts:", ", ".join(f"{i}={LAYOUT_CODES[i]}" for i in sorted(tables)))
    print("dictionaries:", SPELLER.loaded or "none, using heuristics")
    print()

    ok = wrong = missed = skipped = 0
    for word, home, want_fix in CASES:
        other = next(i for i in sorted(tables) if i != home)
        # Typed in the wrong layout when a fix is expected, in its own when not.
        typed_in = other if want_fix else home
        keys = keystrokes(word, tables[home])
        if keys is None:
            skipped += 1
            continue
        on_screen = render(keys, tables[typed_in])
        candidate = render(keys, tables[home if typed_in != home else other])
        will_fix = SPELLER.should_fix(on_screen, languages[typed_in],
                                      candidate, languages[home if typed_in != home else other])
        if will_fix == want_fix:
            ok += 1
            verdict = "ok"
        elif want_fix:
            missed += 1
            verdict = "MISSED"
        else:
            wrong += 1
            verdict = "FALSE POSITIVE"
        if verdict != "ok":
            print(f"! {on_screen:<16} -> {candidate:<16} {verdict}")

    phrases_ok = phrases_bad = 0
    for phrase, home, wrong_layout in PHRASES:
        watcher = Watcher(tables)
        watcher.auto = True
        result = phrase_check(watcher, tables, languages, phrase, home, wrong_layout)
        if result == phrase:
            phrases_ok += 1
        else:
            phrases_bad += 1
            print(f"! phrase {phrase!r} came out as {result!r}")

    total = ok + wrong + missed
    print()
    print(f"phrases typed end to end: {phrases_ok}/{phrases_ok + phrases_bad}")
    print(f"correct decisions: {ok}/{total}")
    print(f"false positives (would corrupt text): {wrong}")
    print(f"missed (should have corrected): {missed}")
    if skipped:
        print(f"skipped (word not typable in these layouts): {skipped}")
    return 1 if wrong or phrases_bad else 0


if __name__ == "__main__":
    sys.exit(main())
