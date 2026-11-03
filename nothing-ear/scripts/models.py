"""Nothing/CMF earbuds model identification.

Maps a device's SKU (derived from its serial number — see
protocol.parse_serial) to a product name and a minimal capability flag
(whether it has ANC). This is an original implementation of publicly
documented protocol *facts* (SKU codes, product names, which bases have ANC),
cross-checked between two independently published community
reverse-engineering projects covering the wider Nothing/CMF earbuds line:
ear-web (AGPL-3.0, https://github.com/radiance-project/ear-web) and earctl
(AGPL-3.0, https://github.com/DaanHessen/earctl, not vendored). No code from
either project is copied here — only the numeric/tabular facts, which both
independently derived from the same public device line.

Newer models are identified by the model ID the buds report (protocol
MODEL_READ), falling back to the serial number and then the Bluetooth name.
Model IDs, names, EQ preset tables and which models have bass boost are
only included where ear-web and BudsLink (GPL-3.0,
https://github.com/maniacx/BudsLink, not vendored) agree.

Hardware-verified by this plugin only for the Nothing Ear (2) (base B155,
SKUs 17/18/19/27/28/29). Every other entry is best-effort: untested by this
plugin's author, believed accurate because both reference projects agree on
it and because this plugin's own hardware-confirmed command set (frame
format, CRC, ANC/EQ/latency command IDs and payloads) is identical to what
both of them independently document for the whole product line.

CMF Neckband Pro (base B164) is deliberately excluded: it's a neckband, not
earbuds, and out of scope for this plugin.
"""
from __future__ import annotations

# base -> (display name, has ANC)
BASES: dict[str, tuple[str, bool]] = {
    "B181": ("Nothing Ear (1)", True),
    "B157": ("Nothing Ear (stick)", False),
    "B155": ("Nothing Ear (2)", True),
    "B163": ("CMF Buds Pro", True),
    "B171": ("Nothing Ear", True),
    "B162": ("Nothing Ear (a)", True),
    "B183": ("Nothing Ear (a)", True),
    "B173": ("Nothing Ear (3)", True),
    "B190": ("Nothing Ear (3a)", True),
    "B168": ("CMF Buds", True),
    "B172": ("CMF Buds Pro 2", True),
    "B187": ("CMF Buds Pro 2", True),
    "B179": ("CMF Buds 2", True),
    "B184": ("CMF Buds 2 Plus", True),
    "B185": ("CMF Buds 2a", True),
    "B174": ("Nothing Ear (open)", False),
}

# Wire index -> preset name (a panel.eq.* translation key), in display order.
# The classic table is the one mapped on a Nothing Ear (2); index 4 is unused
# and 5 is the user's custom curve.
CLASSIC_EQ = [(0, "balanced"), (3, "more_bass"), (2, "more_treble"), (1, "voice"), (5, "custom")]
_CMF_EQ = [(3, "pop"), (1, "rock"), (2, "electronic"), (4, "enhance_vocals"), (5, "classical"), (6, "custom")]

# Models that pick their preset with the LISTENING_MODE commands. The CMF
# Buds 2 Plus has no Dirac preset, and the 2a puts it at index 7.
LISTENING_EQ: dict[str, list[tuple[int, str]]] = {
    "B179": [(0, "dirac")] + _CMF_EQ,
    "B184": _CMF_EQ,
    "B185": [(7, "dirac")] + _CMF_EQ,
}
# Also on the LISTENING_MODE commands, but without a preset table both
# sources agree on, so the EQ section stays hidden rather than sending
# indexes that mean something else on these models.
LISTENING_EQ_UNKNOWN = {"B168", "B172", "B187"}

# Bass boost with five levels.
BASS_BOOST = {"B168", "B171", "B162", "B172", "B179", "B184"}

# SKU (as embedded in the device's serial number) -> base
SKU_TO_BASE: dict[str, str] = {
    "01": "B181", "02": "B181", "03": "B181", "04": "B181",
    "06": "B181", "07": "B181", "08": "B181", "10": "B181",
    "14": "B157", "15": "B157", "16": "B157",
    "17": "B155", "18": "B155", "19": "B155",
    "27": "B155", "28": "B155", "29": "B155",
    "30": "B163", "31": "B163", "32": "B163", "33": "B163", "34": "B163", "35": "B163",
    "54": "B168", "55": "B168", "56": "B168", "57": "B168", "58": "B168", "59": "B168",
    "61": "B171", "62": "B171", "69": "B171", "70": "B171", "74": "B171", "75": "B171",
    "63": "B162", "64": "B162", "65": "B162", "66": "B162", "67": "B162", "68": "B162",
    "71": "B162", "72": "B162", "73": "B162",
    "76": "B172", "77": "B172", "78": "B172", "79": "B172",
    "80": "B172", "81": "B172", "82": "B172", "83": "B172",
    "11200005": "B174",
}


def _derive_sku_from_serial(serial: str) -> str | None:
    """Best-effort SKU extraction from the raw serial string.

    Per community reverse-engineering (see module docstring): a fixed
    "SH"/"13"-prefixed serial embeds the SKU at offset 4:6; a "MA"-prefixed
    one (older stock-keeping scheme) is disambiguated by a year digit pair
    instead. Verified by this plugin only for the "SH" case, against the
    Ear (2)'s own serial.
    """
    if serial == "12345678901234567":
        return "01"
    if len(serial) < 6:
        return None
    head = serial[:2]
    if head == "MA":
        if len(serial) < 8:
            return None
        year = serial[6:8]
        if year in ("22", "23"):
            return "14"
        if year == "24":
            return "11200005"
        return None
    if head in ("SH", "13"):
        return serial[4:6]
    return None


def _presets(table: list[tuple[int, str]]) -> list[dict]:
    return [{"index": index, "name": name} for index, name in table]


def describe(base: str | None) -> dict:
    """Returns {"name", "base", "anc", "eq", "eq_presets", "bass"}.

    `eq` is "classic" (EQ_PRESET commands), "listening" (LISTENING_MODE
    commands) or None (no EQ shown). An unknown base gets a permissive
    descriptor (anc=True, classic EQ), so an unrecognised device behaves
    like the Ear (2) this plugin was built on rather than losing controls.
    """
    if base not in BASES:
        return {"name": None, "base": None, "anc": True, "eq": "classic", "eq_presets": _presets(CLASSIC_EQ), "bass": False}
    name, anc = BASES[base]
    if base in LISTENING_EQ:
        eq, presets = "listening", LISTENING_EQ[base]
    elif base in LISTENING_EQ_UNKNOWN:
        eq, presets = None, []
    else:
        eq, presets = "classic", CLASSIC_EQ
    return {
        "name": name,
        "base": base,
        "anc": anc,
        "eq": eq,
        "eq_presets": _presets(presets),
        "bass": base in BASS_BOOST,
    }


def identify(model_id: str | None = None, serial: str | None = None, bt_name: str | None = None) -> dict:
    """The model from, in order of trust: the model ID the buds report, the
    SKU in their serial number, or their Bluetooth name matching a known
    model exactly."""
    if model_id in BASES:
        return describe(model_id)
    if serial:
        sku = _derive_sku_from_serial(serial)
        base = SKU_TO_BASE.get(sku) if sku else None
        if base is not None:
            return describe(base)
    if bt_name:
        wanted = bt_name.strip().lower()
        for base, (name, _) in BASES.items():
            if name.lower() == wanted:
                return describe(base)
    return describe(None)
