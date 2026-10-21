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
    "B168": ("CMF Buds", True),
    "B172": ("CMF Buds Pro 2", True),
    "B174": ("Nothing Ear (open)", False),
}

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


def identify(serial: str | None) -> dict:
    """Returns {"name", "base", "anc"}.

    Falls back to a permissive "unknown model" descriptor (anc=True, so
    nothing is hidden in the UI) when the serial is missing or doesn't match
    a known SKU — an unrecognized device behaves exactly like today's
    Ear (2)-only plugin rather than losing functionality.
    """
    if serial:
        sku = _derive_sku_from_serial(serial)
        base = SKU_TO_BASE.get(sku) if sku else None
        if base is not None:
            name, anc = BASES[base]
            return {"name": name, "base": base, "anc": anc}
    return {"name": None, "base": None, "anc": True}
