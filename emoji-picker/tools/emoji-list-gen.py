#!/usr/bin/env python3
"""Generate the emoji + Unicode-symbol dataset for the Noctalia
emoji-picker plugin (assets/emoji.json, assembled by hosts/zeus/
noctalia-plugins.nix; the picker itself is picker.luau).

Inputs (all pinned by hash in the Nix module that runs this script):
  1. CLDR common/annotations/en.xml        — short names (type="tts") and
     " | "-separated keywords for base emoji
  2. CLDR common/annotationsDerived/en.xml — same, for derived sequences
     (skin tones, ZWJ combinations, regional-indicator flags)
  3. unicode.org emoji-test.txt            — the fully-qualified RGI set in
     CLDR recommended sort order; supplies ordering, per-emoji category
     (from the "# group:" headers) and fallback names
  4. unicode.org UnicodeData.txt           — formal names for the symbol
     set (and validation: every curated symbol codepoint must exist
     there or the build fails)

Output (stdout): one JSON array — every RGI emoji in browse order, then
every curated Unicode symbol in browse order:

    {"e": "🚀", "n": "rocket", "l": "rocket", "z": "rocket launch space", "c": "travel", "k": ["launch", "space"]}
    {"e": "€", "n": "euro", "l": "euro", "z": "euro eur euro sign currency", "c": "chars", "a": ["eur", "euro sign"], "k": ["currency"], "s": 1}

  e — the character itself (copied on selection)
  n — canonical name (footer display + search)
  l — lower-cased canonical name (search only)
  z — pre-built lower-cased name/keyword/alias search blob
  c — category id (smileys | animals | food | activity | travel | objects |
     symbols | flags | chars); "Smileys & Emotion" and "People & Body"
     merge into "smileys" (classic "Smileys & People" section, macOS-style);
     "chars" is the Unicode-symbol category
  k — search keywords (weaker match class, never rendered)
  a — SYMBOLS ONLY: name-class search aliases — the names people actually
      type ("arrow right", "plusminus", "gbp"). Ranked like names by the
      picker, unlike the weaker k class
  s — SYMBOLS ONLY: 1, the entry-type marker the picker's ranking keys on

CLDR stores annotation cp values with U+FE0F (VARIATION SELECTOR-16)
stripped, so lookups go through the same normalisation.
"""

import json
import sys
import xml.etree.ElementTree as ET

# U+FE0F VARIATION SELECTOR-16 (written as an escape: the literal is invisible)
VS16 = "\ufe0f"

# emoji-test.txt "# group:" header -> category id, in browse order.
GROUPS = {
    "Smileys & Emotion": "smileys",
    "People & Body": "smileys",  # classic "Smileys & People" section
    "Animals & Nature": "animals",
    "Food & Drink": "food",
    "Activities": "activity",
    "Travel & Places": "travel",
    "Objects": "objects",
    "Symbols": "symbols",
    "Flags": "flags",
}

# ── Unicode symbol set ──────────────────────────────────────────────────
# Curated in BROWSE order (the order tiles appear in the "chars" category).
# Tuple per character: (codepoint, name, aliases, keywords)
#   name    — canonical name; None = derive from the formal Unicode name
#             (lowercased, hyphens turned into spaces)
#   aliases — name-class search terms (what people actually type); the
#             formal Unicode name is appended automatically, and every
#             multi-word name/alias also gets its "hyphen-joined" and
#             "squashed" variants ("plus minus" also matches "plus-minus"
#             and "plusminus")
#   keywords — weaker match class, for fuzzy long-tail terms only
SYMBOLS = [
    # ── currency ──
    ("0024", "dollar", ["usd", "dollars"], ["money", "currency", "us"]),
    ("00A2", "cent", ["cent sign", "cents"], ["money"]),
    ("00A3", "pound", ["gbp", "pound sterling", "pound sign", "sterling", "pounds"], ["british", "uk", "currency"]),
    ("00A4", "currency sign", ["currency"], ["money"]),
    ("00A5", "yen", ["yuan", "jpy", "cny", "rmb", "yen sign"], ["japan", "china", "currency"]),
    ("20AC", "euro", ["eur", "euro sign", "euros"], ["europe", "european", "eu", "currency"]),
    ("20BD", "ruble", ["rouble", "rub", "russian ruble"], ["russia", "currency"]),
    ("20B9", "indian rupee", ["rupee", "inr"], ["india", "currency"]),
    ("20A8", None, ["rupee sign"], ["pakistan"]),
    ("20A9", "won", ["krw"], ["korea", "currency"]),
    ("20AA", "shekel", ["sheqel", "ils", "nis"], ["israel", "currency"]),
    ("20BA", "turkish lira", ["lira", "try"], ["turkey", "currency"]),
    ("20AB", "dong", ["vnd"], ["vietnam"]),
    ("20B1", "peso", ["php"], ["philippines"]),
    ("20B4", "hryvnia", ["grivna", "uah"], ["ukraine"]),
    ("20BF", "bitcoin", ["btc"], ["crypto", "cryptocurrency"]),
    ("20B2", "guarani", [], ["paraguay"]),
    ("20BC", "manat", [], ["azerbaijan"]),
    ("20BE", "lari", [], ["georgia"]),
    ("20A6", "naira", [], ["nigeria"]),
    ("20AD", "kip", [], ["laos"]),
    ("20AE", "tugrik", [], ["mongolia"]),
    ("20AF", None, [], ["greece"]),
    ("20B5", "cedi", [], ["ghana"]),
    ("20A0", None, [], []),
    ("20A1", None, [], ["costa rica"]),
    ("20A2", None, [], []),
    ("20A3", "french franc sign", ["franc"], ["france"]),
    ("20A4", None, ["italian lira"], ["italy"]),
    ("20A5", None, [], []),
    ("20A7", None, [], ["spain"]),
    ("20B3", None, [], []),
    # ── punctuation & typography ──
    ("2013", "en dash", ["ndash"], ["dash", "punctuation"]),
    ("2014", "em dash", ["mdash"], ["dash", "punctuation"]),
    ("2015", "horizontal bar", ["quotation dash"], []),
    ("2018", "left single quote", ["left single quotation mark", "open single quote"], ["quote", "punctuation"]),
    ("2019", "right single quote", ["right single quotation mark", "apostrophe", "close single quote", "curly apostrophe"], ["quote", "punctuation"]),
    ("201C", "left double quote", ["left double quotation mark", "open double quote"], ["quote", "punctuation"]),
    ("201D", "right double quote", ["right double quotation mark", "close double quote"], ["quote", "punctuation"]),
    ("201E", None, ["german quote", "low double quotation mark"], ["quote"]),
    ("2026", "ellipsis", ["dot dot dot", "...", "horizontal ellipsis", "dots"], ["three dots", "punctuation"]),
    ("2022", "bullet", ["bullet point"], ["dot", "list", "point", "punctuation"]),
    ("00B7", "middle dot", ["middot", "interpunct", "centered dot"], ["dot", "point"]),
    ("00A7", "section", ["section sign"], ["law", "legal"]),
    ("00B6", "paragraph", ["pilcrow", "paragraph mark", "para"], ["editing"]),
    ("2020", "dagger", [], ["footnote"]),
    ("2021", "double dagger", [], ["footnote"]),
    ("2030", "per mille", ["permille", "per thousand", "promille"], ["percent"]),
    ("2031", "per ten thousand", ["basis point", "basis points", "bps", "per myriad"], ["percent"]),
    ("0025", "percent", ["percentage", "percent sign"], ["modulo", "mod", "per cent"]),
    ("203D", "interrobang", ["interabang"], ["question", "exclamation"]),
    ("00BF", None, ["inverted question", "spanish question"], ["question", "spanish"]),
    ("00A1", None, ["inverted exclamation", "spanish exclamation"], ["exclamation", "spanish"]),
    ("2039", "left angle quote", ["single left angle quote"], ["quote", "guillemet"]),
    ("203A", "right angle quote", ["single right angle quote"], ["quote", "guillemet"]),
    ("00AB", "left guillemet", ["left double angle quote", "french quote"], ["quote"]),
    ("00BB", "right guillemet", ["right double angle quote", "french quote"], ["quote"]),
    ("2032", "prime", ["minutes", "feet"], ["arcminute", "angle"]),
    ("2033", "double prime", ["seconds", "inches"], ["arcsecond"]),
    ("2042", "asterism", [], []),
    ("002D", "hyphen", ["hyphen minus"], ["dash", "minus", "subtract"]),
    ("00A0", "no-break space", ["nbsp", "non-breaking space"], []),
    # ── math & comparison ──
    ("002B", "plus", ["plus sign"], ["add", "addition", "positive"]),
    ("00B1", "plus minus", ["plus or minus", "plus or minus sign"], ["pm", "math"]),
    ("2212", "minus", ["minus sign"], ["subtract", "subtraction", "negative"]),
    ("00D7", "multiply", ["times", "multiplication", "x"], ["math"]),
    ("00F7", "divide", ["division", "obelus"], ["math"]),
    ("003D", "equals", ["equal", "equal sign", "equals sign"], ["equality", "math"]),
    ("2260", "not equal", ["not equal to", "neq", "different", "is not equal to"], ["inequality", "math"]),
    ("2248", "almost equal", ["approx", "approximately", "approximately equal", "almost equal to", "approximately equal to"], ["approximate", "similar", "roughly", "tilde", "math"]),
    ("2245", None, ["congruent"], ["similar", "geometry"]),
    ("2261", "identical", ["identical to", "equivalent", "triple equals"], ["congruent", "math", "mod"]),
    ("2264", "less than or equal to", ["less than or equal", "less or equal", "less equal", "leq", "le", "<="], ["at most", "comparison", "math"]),
    ("2265", "greater than or equal to", ["greater than or equal", "greater or equal", "greater equal", "geq", "ge", ">="], ["at least", "comparison", "math"]),
    ("003C", "less than", ["lt"], ["smaller", "comparison"]),
    ("003E", "greater than", ["gt"], ["bigger", "comparison"]),
    ("226A", "much less than", ["much less"], []),
    ("226B", "much greater than", ["much greater"], []),
    ("221E", "infinity", ["infinite", "lemniscate"], ["forever", "math"]),
    ("221A", "square root", ["sqrt", "root", "radical"], ["math"]),
    ("2211", "sum", ["summation"], ["addition", "total", "math"]),
    ("220F", "product", [], ["multiplication", "math"]),
    ("222B", "integral", [], ["integration", "calculus", "math"]),
    ("2202", "partial derivative", ["partial differential", "partial"], ["calculus", "math"]),
    ("2207", "nabla", ["del", "gradient", "inverted delta"], ["math", "vector"]),
    ("00B0", "degree", ["degree sign", "degrees"], ["deg", "temperature", "angle"]),
    ("2220", "angle", [], ["geometry", "math"]),
    ("00AC", "not sign", ["logical not", "negation"], ["logic", "not"]),
    ("2227", "logical and", ["and", "conjunction", "wedge"], ["logic", "boolean"]),
    ("2228", "logical or", ["or", "disjunction"], ["logic", "boolean"]),
    ("2200", "for all", ["forall"], ["logic"]),
    ("2203", "there exists", ["there exist", "exists"], ["logic"]),
    ("2234", "therefore", ["thus"], ["logic", "math"]),
    ("2235", "because", ["since"], ["logic", "math"]),
    ("2205", "empty set", ["null set", "emptyset"], ["null", "set", "math"]),
    ("2208", "element of", ["in", "member of"], ["set", "math"]),
    ("2209", None, ["not an element of", "not in"], ["set", "math"]),
    ("2282", "subset", ["subset of", "proper subset"], ["set", "math"]),
    ("2283", "superset", ["superset of", "proper superset"], ["set", "math"]),
    ("2286", "subset or equal", [], ["set", "math"]),
    ("2287", "superset or equal", [], ["set", "math"]),
    ("222A", "union", ["cup"], ["set", "math"]),
    ("2229", "intersection", ["cap"], ["set", "math"]),
    ("2295", "circled plus", ["direct sum", "xor"], ["math"]),
    ("2297", "circled times", ["tensor product"], ["math"]),
    ("22A5", "perpendicular", ["is perpendicular to"], ["orthogonal", "geometry"]),
    ("2225", "parallel", ["is parallel to"], ["geometry"]),
    ("2308", "left ceiling", ["ceiling"], ["math", "round up"]),
    ("2309", None, [], []),
    ("230A", "left floor", ["floor"], ["math", "round down"]),
    ("230B", None, [], []),
    ("22C5", "dot operator", ["dot product"], ["dot", "math"]),
    ("007E", "tilde", ["twiddle", "squiggle"], ["approx", "approximately", "about", "not"]),
    # ── arrows ──
    ("2190", "left arrow", ["leftwards arrow", "arrow left", "left", "west arrow"], ["west", "back", "previous", "direction"]),
    ("2191", "up arrow", ["upwards arrow", "arrow up", "up", "north arrow"], ["north", "direction"]),
    ("2192", "right arrow", ["rightwards arrow", "arrow right", "right", "east arrow"], ["east", "forward", "next", "direction"]),
    ("2193", "down arrow", ["downwards arrow", "arrow down", "down", "south arrow"], ["south", "direction"]),
    ("2194", "left right arrow", ["left and right arrow", "horizontal arrow"], ["width", "horizontal", "direction"]),
    ("2195", "up down arrow", ["up and down arrow", "vertical arrow"], ["height", "vertical", "direction"]),
    ("2196", "up left arrow", ["north west arrow", "diagonal up left"], ["northwest", "diagonal"]),
    ("2197", "up right arrow", ["north east arrow", "diagonal up right"], ["northeast", "diagonal"]),
    ("2198", "down right arrow", ["south east arrow", "diagonal down right"], ["southeast", "diagonal"]),
    ("2199", "down left arrow", ["south west arrow", "diagonal down left"], ["southwest", "diagonal"]),
    ("21D0", "left double arrow", ["double left arrow", "leftwards double arrow"], ["direction"]),
    ("21D1", "up double arrow", ["double up arrow", "upwards double arrow"], []),
    ("21D2", "right double arrow", ["double right arrow", "rightwards double arrow", "implies"], ["logic"]),
    ("21D3", "down double arrow", ["double down arrow", "downwards double arrow"], []),
    ("21D4", "left right double arrow", ["double left right arrow", "if and only if", "iff"], ["logic"]),
    ("21D5", "up down double arrow", ["double up down arrow"], []),
    ("21C4", "right arrow over left arrow", ["arrows right and left", "swap arrows"], ["swap", "exchange"]),
    ("21BA", "anticlockwise arrow", ["counterclockwise arrow", "anticlockwise", "counterclockwise"], ["undo"]),
    ("21BB", "clockwise arrow", ["clockwise"], ["refresh", "reload", "redo"]),
    ("21A9", None, [], ["return", "reply"]),
    ("21AA", None, [], []),
    ("21E7", None, ["shift", "hollow up arrow", "upwards white arrow"], ["keyboard", "modifier"]),
    ("21E5", None, ["tab"], ["keyboard"]),
    # ── legal ──
    ("00A9", "copyright", ["copyright sign"], ["law", "legal", "rights"]),
    ("00AE", "registered", ["registered sign", "reg"], ["law", "legal"]),
    ("2122", "trademark", ["tm", "trade mark", "trademark sign"], ["law", "legal", "brand"]),
    ("2120", "service mark", ["sm"], ["law", "legal"]),
    ("2117", "phonogram", ["sound recording copyright"], ["law", "legal"]),
    # ── geometric shapes ──
    ("25A0", "black square", ["filled square"], ["shape", "square"]),
    ("25A1", "white square", ["empty square", "open square"], ["shape", "square"]),
    ("25AA", None, [], []),
    ("25AB", None, [], []),
    ("25AC", "black rectangle", ["filled rectangle"], ["shape"]),
    ("25AD", None, [], ["shape"]),
    ("25B2", "up triangle", ["black up triangle", "triangle up", "black up-pointing triangle"], ["shape", "triangle"]),
    ("25BC", "down triangle", ["black down triangle", "triangle down", "black down-pointing triangle"], ["shape", "triangle"]),
    ("25B3", "outline up triangle", ["white up triangle", "up triangle outline", "triangle outline", "empty triangle"], ["shape", "triangle"]),
    ("25BD", "outline down triangle", ["white down triangle", "down triangle outline"], ["shape", "triangle"]),
    ("25BA", "right pointer", ["right-pointing triangle"], ["shape"]),
    ("25C4", "left pointer", ["left-pointing triangle"], ["shape"]),
    ("25C6", "diamond", ["filled diamond", "black diamond"], ["shape"]),
    ("25CB", "circle", ["white circle", "empty circle", "open circle", "hollow circle"], ["shape"]),
    ("25CF", "filled circle", ["black circle"], ["shape"]),
    ("25E6", None, ["small circle"], []),
    ("25EF", "large circle", ["big circle"], ["shape"]),
    ("25D0", "left half-filled circle", ["half circle", "circle with left half black"], ["shape"]),
    ("25D1", "right half-filled circle", ["half circle right", "circle with right half black"], ["shape"]),
    ("25CA", "lozenge", [], ["diamond", "shape"]),
    ("2605", "black star", ["filled star"], ["shape"]),
    ("2606", "white star", ["outline star", "empty star", "star outline"], ["shape"]),
    ("2726", None, ["four pointed star"], []),
    ("2727", None, ["four pointed star outline"], []),
    # ── check marks & crosses ──
    ("2713", "check mark", ["check", "tick", "checkmark", "checked"], ["yes", "correct", "done", "approve"]),
    ("2714", "heavy check mark", ["bold check", "heavy tick"], ["check", "tick"]),
    ("2715", "x mark", ["multiplication x", "cross", "x", "cross mark"], ["close", "incorrect", "times"]),
    ("2716", "heavy multiplication x", ["heavy x", "heavy cross"], ["cross", "x"]),
    ("2717", "ballot x", ["x", "cross", "cross mark"], ["fail", "wrong", "no"]),
    ("2718", "heavy ballot x", ["heavy x mark"], ["cross", "wrong"]),
    ("2610", "ballot box", ["empty checkbox", "unchecked box"], ["form", "unchecked"]),
    ("2611", "ballot box with check", ["checkbox", "checked box", "checkbox checked"], ["form", "checked", "tick"]),
    ("2612", "ballot box with x", ["checkbox crossed", "crossed box"], ["form", "crossed"]),
    # ── technical ──
    ("00B5", "micro", ["micro sign"], ["mu", "si"]),
    ("2300", "diameter", ["diameter sign"], ["engineering"]),
    ("2318", "place of interest sign", ["command", "cmd", "command key", "apple", "looped square"], ["mac", "keyboard", "shortcut"]),
    ("2325", None, ["option", "alt", "alt key"], ["mac", "keyboard"]),
    ("232B", "backspace", ["erase to the left", "delete left", "delete key"], ["keyboard"]),
    ("2326", None, ["delete right", "forward delete"], ["keyboard"]),
    ("23CE", "return symbol", ["return", "enter", "carriage return", "enter key"], ["keyboard", "newline"]),
    ("2116", None, ["numero"], ["number"]),
    ("2103", "degree celsius", ["celsius", "degrees celsius", "centigrade"], ["temperature"]),
    ("2109", "degree fahrenheit", ["fahrenheit", "degrees fahrenheit"], ["temperature"]),
    # ── music & card suits ──
    ("266A", "eighth note", ["note", "quaver"], ["music", "music note"]),
    ("266B", None, ["notes"], ["music", "music notes"]),
    ("2669", "quarter note", ["crotchet"], ["music"]),
    ("266C", None, [], ["music"]),
    ("266D", "flat sign", ["flat"], ["music", "music flat"]),
    ("266F", "sharp sign", ["sharp"], ["music", "music sharp"]),
    ("266E", "natural sign", ["natural"], ["music", "music natural"]),
    ("2665", "heart suit", ["heart", "black heart", "hearts"], ["card", "suit", "love"]),
    ("2666", "diamond suit", ["diamond", "diamonds"], ["card", "suit"]),
    ("2663", "club suit", ["clubs", "club", "trefoil"], ["card", "suit"]),
    ("2660", "spade suit", ["spades", "spade"], ["card", "suit"]),
    # ── Greek letters (lowercase, then uppercase) ──
    ("03B1", "alpha", ["greek alpha"], []),
    ("03B2", "beta", ["greek beta"], []),
    ("03B3", "gamma", ["greek gamma"], []),
    ("03B4", "delta", ["greek delta"], ["change", "increment"]),
    ("03B5", "epsilon", ["greek epsilon"], []),
    ("03B6", "zeta", ["greek zeta"], []),
    ("03B7", "eta", ["greek eta"], []),
    ("03B8", "theta", ["greek theta"], ["angle"]),
    ("03B9", "iota", ["greek iota"], []),
    ("03BA", "kappa", ["greek kappa"], []),
    ("03BB", "lambda", ["greek lambda"], ["function"]),
    ("03BC", "mu", ["greek mu"], []),
    ("03BD", "nu", ["greek nu"], []),
    ("03BE", "xi", ["greek xi"], []),
    ("03BF", "omicron", ["greek omicron"], []),
    ("03C0", "pi", ["greek pi"], ["3.14", "constant"]),
    ("03C1", "rho", ["greek rho"], []),
    ("03C2", "final sigma", ["sigma final"], []),
    ("03C3", "sigma", ["greek sigma"], []),
    ("03C4", "tau", ["greek tau"], []),
    ("03C5", "upsilon", ["greek upsilon"], []),
    ("03C6", "phi", ["greek phi"], []),
    ("03C7", "chi", ["greek chi"], []),
    ("03C8", "psi", ["greek psi"], []),
    ("03C9", "omega", ["greek omega"], []),
    ("0391", "capital alpha", ["greek capital alpha"], []),
    ("0392", "capital beta", ["greek capital beta"], []),
    ("0393", "capital gamma", ["greek capital gamma"], []),
    ("0394", "capital delta", ["greek capital delta"], ["change", "increment", "difference"]),
    ("0395", "capital epsilon", ["greek capital epsilon"], []),
    ("0396", "capital zeta", ["greek capital zeta"], []),
    ("0397", "capital eta", ["greek capital eta"], []),
    ("0398", "capital theta", ["greek capital theta"], []),
    ("0399", "capital iota", ["greek capital iota"], []),
    ("039A", "capital kappa", ["greek capital kappa"], []),
    ("039B", "capital lambda", ["greek capital lambda"], []),
    ("039C", "capital mu", ["greek capital mu"], []),
    ("039D", "capital nu", ["greek capital nu"], []),
    ("039E", "capital xi", ["greek capital xi"], []),
    ("039F", "capital omicron", ["greek capital omicron"], []),
    ("03A0", "capital pi", ["greek capital pi"], []),
    ("03A1", "capital rho", ["greek capital rho"], []),
    ("03A3", "capital sigma", ["greek capital sigma"], ["sum"]),
    ("03A4", "capital tau", ["greek capital tau"], []),
    ("03A5", "capital upsilon", ["greek capital upsilon"], []),
    ("03A6", "capital phi", ["greek capital phi"], []),
    ("03A7", "capital chi", ["greek capital chi"], []),
    ("03A8", "capital psi", ["greek capital psi"], []),
    ("03A9", "capital omega", ["greek capital omega"], ["ohm"]),
    ("03D5", None, ["greek phi symbol", "variant phi"], []),
    # ── fractions ──
    ("00BD", "one half", ["half", "1/2"], []),
    ("00BC", "one quarter", ["quarter", "fourth", "1/4"], []),
    ("00BE", "three quarters", ["3/4"], []),
    ("2153", "one third", ["third", "1/3"], []),
    ("2154", "two thirds", ["2/3"], []),
    ("2155", "one fifth", ["1/5"], []),
    ("2156", "two fifths", ["2/5"], []),
    ("2157", "three fifths", ["3/5"], []),
    ("2158", "four fifths", ["4/5"], []),
    ("2159", "one sixth", ["1/6"], []),
    ("215A", "five sixths", ["5/6"], []),
    ("215B", "one eighth", ["eighth", "1/8"], []),
    ("215C", "three eighths", ["3/8"], []),
    ("215D", "five eighths", ["5/8"], []),
    ("215E", "seven eighths", ["7/8"], []),
    ("2150", "one seventh", ["1/7"], []),
    ("2151", "one ninth", ["1/9"], []),
    ("2152", "one tenth", ["1/10"], []),
    # ── superscripts & subscripts ──
    ("2070", "superscript zero", [], ["power"]),
    ("00B9", "superscript one", [], ["power"]),
    ("00B2", "superscript two", ["squared"], ["power"]),
    ("00B3", "superscript three", ["cubed"], ["power"]),
    ("2074", None, [], ["power"]),
    ("2075", None, [], ["power"]),
    ("2076", None, [], ["power"]),
    ("2077", None, [], ["power"]),
    ("2078", None, [], ["power"]),
    ("2079", None, [], ["power"]),
    ("207A", None, [], ["power"]),
    ("207B", None, [], ["power"]),
    ("207F", None, ["nth"], ["power"]),
    ("2071", None, [], ["imaginary", "power"]),
    ("2080", "subscript zero", [], ["sub"]),
    ("2081", "subscript one", [], ["sub"]),
    ("2082", "subscript two", [], ["sub"]),
    ("2083", "subscript three", [], ["sub"]),
    ("2084", None, [], ["sub"]),
    ("2085", None, [], ["sub"]),
    ("2086", None, [], ["sub"]),
    ("2087", None, [], ["sub"]),
    ("2088", None, [], ["sub"]),
    ("2089", None, [], ["sub"]),
    ("208A", None, [], ["sub"]),
    ("208B", None, [], ["sub"]),
    ("208C", None, [], ["sub"]),
]


def load_annotations(path):
    """Return {emoji: (tts_name, [keywords])} from one CLDR annotations file."""
    names, keywords = {}, {}
    for el in ET.parse(path).iter("annotation"):
        cp = el.get("cp")
        if cp is None or not el.text:
            continue
        if el.get("type") == "tts":
            names[cp] = el.text.strip()
        else:
            keywords.setdefault(cp, []).extend(
                k.strip() for k in el.text.split("|") if k.strip()
            )
    return {
        cp: (names.get(cp, ""), keywords.get(cp, []))
        for cp in names.keys() | keywords.keys()
    }


def load_formal_names(path):
    """Return {U+XXXX: formal name} from UnicodeData.txt."""
    formal = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            fields = line.split(";", 2)
            if len(fields) >= 2 and fields[1]:
                formal[fields[0]] = fields[1]
    return formal


def formal_to_common(formal):
    """'PLUS-MINUS SIGN' -> 'plus minus sign' (searchable common form)."""
    return " ".join(formal.lower().replace("-", " ").split())


def term_variants(term):
    """Expand one name/alias with the separator variants people type.

    'plus minus' also matches the queries 'plus-minus' and 'plusminus'.
    """
    out = [term]
    if " " in term:
        for variant in (term.replace(" ", "-"), term.replace(" ", "")):
            if variant not in out:
                out.append(variant)
    return out


def build_symbol_entries(formal):
    """Build the symbol dataset entries from SYMBOLS + formal Unicode names."""
    entries = []
    seen = set()
    for cp, name, aliases, keywords in SYMBOLS:
        if cp in seen:
            raise ValueError(f"duplicate symbol codepoint {cp}")
        seen.add(cp)
        if cp not in formal:
            raise ValueError(
                f"symbol codepoint U+{cp} not in UnicodeData.txt (typo?)"
            )
        common_formal = formal_to_common(formal[cp])
        canonical = name if name is not None else common_formal

        # Name-class aliases: the canonical name + curated aliases with
        # separator variants. The formal Unicode name goes to the weaker
        # keyword class instead ("MUSIC FLAT SIGN" must not make a "music"
        # query rank ♭ above 🎵; curated aliases already cover the names
        # people type, formal jargon just has to stay findable).
        expanded = []
        for term in [canonical] + list(aliases):
            for variant in term_variants(term.lower()):
                if variant not in expanded:
                    expanded.append(variant)
        kw = [k.lower() for k in keywords]
        raw_formal = formal[cp].strip().lower()
        for extra in (common_formal, raw_formal):
            if extra != canonical and extra not in expanded and extra not in kw:
                kw.append(extra)

        entries.append({
            "e": chr(int(cp, 16)),
            "n": canonical,
            "c": "chars",
            "a": expanded,
            "k": kw,
            "s": 1,
        })
    return entries


def main():
    ann_base, ann_derived, emoji_test, unicode_data = sys.argv[1:5]

    # CLDR's cp keys are FE0F-stripped; merge base + derived (derived wins).
    annotations = load_annotations(ann_base)
    annotations.update(load_annotations(ann_derived))

    entries = []
    category = None
    with open(emoji_test, encoding="utf-8") as fh:
        for raw in fh:
            if raw.startswith("# group:"):
                category = GROUPS.get(raw.partition(":")[2].strip())
                continue
            left, _, comment = raw.partition("#")
            if "fully-qualified" not in left:
                continue
            seq = left.split(";", 1)[0].split()
            emoji = "".join(chr(int(cp, 16)) for cp in seq)
            bare = emoji.replace(VS16, "")
            name, keywords = annotations.get(
                bare, annotations.get(emoji, ("", []))
            )
            if not name:
                # comment tail: "<glyph> <version> <name…>"
                parts = comment.split()
                name = " ".join(parts[2:]) if len(parts) > 2 else "emoji"
            # Dedupe keywords, preserving order; drop ones identical to the
            # name (the name is already searched). Search fields (k, and a
            # for symbols) are emitted LOWER-CASED: the picker must not
            # spend its per-callback CPU budget re-normalising them at
            # load time (see ensureData in picker.luau).
            seen = {name.lower()}
            kws = [
                k.lower() for k in keywords
                if k.lower() not in seen and not seen.add(k.lower())
            ]
            entries.append(
                {"e": emoji, "n": name, "c": category, "k": kws}
            )

    entries.extend(build_symbol_entries(load_formal_names(unicode_data)))

    # These fields are consumed on every search and used to be constructed
    # for all ~4,000 entries inside the first onOpen callback. That cold-start
    # work can exceed Noctalia's hard callback budget under desktop load,
    # abort initialization halfway, and cause the panel to be auto-disabled.
    # Generate them once here instead; neither field is rendered.
    for entry in entries:
        lowered_name = entry["n"].lower()
        entry["l"] = lowered_name
        entry["z"] = " ".join(
            [lowered_name] + entry["k"] + entry.get("a", [])
        )

    json.dump(entries, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
