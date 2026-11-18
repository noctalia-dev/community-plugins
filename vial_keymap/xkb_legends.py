#!/usr/bin/env python3
"""Print, as JSON, the character each QMK keycode produces under the given XKB layouts.

usage: xkb_legends.py <layouts> [<variants>]   e.g.  xkb_legends.py us,rumac  ,
Uses libxkbcommon through ctypes, so custom layouts in ~/.config/xkb are honoured.
Output: {"layouts": ["us", "rumac"], "legends": {"us": {"KC_Q": "Q", ...}, "rumac": {...}}}
"""
import ctypes, json, sys

# QMK keycode aliases -> Linux evdev keycode (input-event-codes.h)
EVDEV = {
    ("KC_GRAVE", "KC_GRV"): 41,
    ("KC_1",): 2, ("KC_2",): 3, ("KC_3",): 4, ("KC_4",): 5, ("KC_5",): 6,
    ("KC_6",): 7, ("KC_7",): 8, ("KC_8",): 9, ("KC_9",): 10, ("KC_0",): 11,
    ("KC_MINUS", "KC_MINS"): 12, ("KC_EQUAL", "KC_EQL"): 13,
    ("KC_Q",): 16, ("KC_W",): 17, ("KC_E",): 18, ("KC_R",): 19, ("KC_T",): 20, ("KC_Y",): 21,
    ("KC_U",): 22, ("KC_I",): 23, ("KC_O",): 24, ("KC_P",): 25,
    ("KC_LBRACKET", "KC_LBRC"): 26, ("KC_RBRACKET", "KC_RBRC"): 27, ("KC_BSLASH", "KC_BSLS"): 43,
    ("KC_A",): 30, ("KC_S",): 31, ("KC_D",): 32, ("KC_F",): 33, ("KC_G",): 34, ("KC_H",): 35,
    ("KC_J",): 36, ("KC_K",): 37, ("KC_L",): 38, ("KC_SCOLON", "KC_SCLN"): 39, ("KC_QUOTE", "KC_QUOT"): 40,
    ("KC_Z",): 44, ("KC_X",): 45, ("KC_C",): 46, ("KC_V",): 47, ("KC_B",): 48, ("KC_N",): 49, ("KC_M",): 50,
    ("KC_COMMA", "KC_COMM"): 51, ("KC_DOT",): 52, ("KC_SLASH", "KC_SLSH"): 53,
    ("KC_NONUS_BSLASH", "KC_NUBS"): 86, ("KC_NONUS_HASH", "KC_NUHS"): 43,
}

class RuleNames(ctypes.Structure):
    _fields_ = [(n, ctypes.c_char_p) for n in ("rules", "model", "layout", "variant", "options")]

def main():
    layouts = [s for s in (sys.argv[1] if len(sys.argv) > 1 else "us").split(",")]
    variants = (sys.argv[2] if len(sys.argv) > 2 else "").split(",")
    variants += [""] * (len(layouts) - len(variants))

    lib = ctypes.CDLL("libxkbcommon.so.0")
    lib.xkb_context_new.restype = ctypes.c_void_p
    lib.xkb_keymap_new_from_names.restype = ctypes.c_void_p
    lib.xkb_keymap_new_from_names.argtypes = [ctypes.c_void_p, ctypes.POINTER(RuleNames), ctypes.c_int]
    lib.xkb_state_new.restype = ctypes.c_void_p
    lib.xkb_state_new.argtypes = [ctypes.c_void_p]
    lib.xkb_state_key_get_utf8.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_size_t]
    lib.xkb_state_unref.argtypes = [ctypes.c_void_p]
    lib.xkb_keymap_unref.argtypes = [ctypes.c_void_p]
    lib.xkb_context_unref.argtypes = [ctypes.c_void_p]

    ctx = lib.xkb_context_new(0)  # default flags: includes ~/.config/xkb
    out = {"layouts": layouts, "legends": {}}
    buf = ctypes.create_string_buffer(32)
    for layout, variant in zip(layouts, variants):
        names = RuleNames(None, None, layout.encode(), variant.encode() or None, None)
        km = lib.xkb_keymap_new_from_names(ctx, ctypes.byref(names), 0)
        if not km:
            out["legends"][layout] = None
            continue
        st = lib.xkb_state_new(km)
        legends = {}
        for aliases, ev in EVDEV.items():
            n = lib.xkb_state_key_get_utf8(st, ev + 8, buf, 32)
            if n > 0:
                ch = buf.value.decode("utf-8", "replace")
                if ch.strip():
                    for a in aliases:
                        legends[a] = ch.upper()
        out["legends"][layout] = legends
        lib.xkb_state_unref(st); lib.xkb_keymap_unref(km)
    lib.xkb_context_unref(ctx)
    json.dump(out, sys.stdout, ensure_ascii=False)

if __name__ == "__main__":
    main()
