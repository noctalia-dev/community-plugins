#!/usr/bin/env python3
"""Generate an EDID for a virtual tablet display.

Describe the tablet by its native resolution and the refresh rates to offer;
a few common lower resolutions are added at the same rates (when smaller than
native). This is the shape the plugin's per-device settings will take.

Each mode goes where it fits:
  - a detailed timing (DTD) using CVT reduced blanking v1, as `cvt -r` prints:
    three in the base block (the first is the preferred mode), up to six more
    in a CTA-861 extension;
  - a mode too fast for a DTD (pixel clock over 655.35 MHz, e.g. 2960x1848 at
    120 Hz) uses CVT reduced blanking v2, which has less blanking, and goes
    into a DisplayID 1.3 extension as a Type I timing (up to five).

Usage:
  make-edid.py -o tablet.bin                                  # Galaxy Tab S9 Ultra
  make-edid.py -o tablet.bin --native 2732x2048 --size-mm 263x197 --name "iPad Pro 13"
  make-edid.py -o tablet.bin --mode 2960x1848@60 --mode 2960x1848@120   # exact list
"""

import argparse
import math
import sys

DTD_MAX_KHZ = 655_350
# Manufacturer "VDP" (Virtual DisPlay): unassigned in the PNP ID registry.
MFG_ID = "VDP"

DEFAULT_NATIVE = "2960x1848"          # Galaxy Tab S9 Ultra
DEFAULT_SIZE_MM = "315x196"
DEFAULT_REFRESH = "60,90,120"
DEFAULT_EXTRA = "2560x1600,1920x1200,1920x1080"


def vsync_width(h, v):
    """CVT vertical sync width, which encodes the aspect ratio."""
    h_rnd = h - h % 8
    for num, den, width in ((4, 3, 4), (16, 9, 5), (16, 10, 6), (5, 4, 7), (15, 9, 7)):
        if (v * num // den) - (v * num // den) % 8 == h_rnd:
            return width
    return 10


def timing(h, v, refresh, h_blank, h_sync, h_front, v_blank, v_front, v_sync, step_khz):
    h_total, v_total = h + h_blank, v + v_blank
    pclk_khz = step_khz * math.floor(refresh * v_total * h_total / 1000.0 / step_khz)
    return {
        "h": h, "v": v, "pclk_khz": pclk_khz,
        "h_blank": h_blank, "h_front": h_front, "h_sync": h_sync,
        "v_blank": v_blank, "v_front": v_front, "v_sync": v_sync,
        "refresh": pclk_khz * 1000.0 / (h_total * v_total),
    }


def vbi_lines(v, refresh, min_vblank_us=460.0):
    h_period_est = ((1_000_000.0 / refresh) - min_vblank_us) / v
    return math.floor(min_vblank_us / h_period_est) + 1


def cvt_rb1(h, v, refresh):
    """CVT reduced blanking v1, as xcvt/libxcvt compute it."""
    v_sync = vsync_width(h, v)
    vbi = max(vbi_lines(v, refresh), 3 + v_sync + 6)
    return timing(h, v, refresh, 160, 32, 48, vbi, 3, v_sync, 250)


def cvt_rb2(h, v, refresh):
    """CVT reduced blanking v2 (CVT 1.2): 80-pixel h-blank, 8-line v-sync,
    6-line back porch. Clock rounded down to 10 kHz, DisplayID's unit."""
    vbi = max(vbi_lines(v, refresh), 1 + 8 + 6)
    return timing(h, v, refresh, 80, 32, 8, vbi, vbi - 8 - 6, 8, 10)


def plan_mode(w, h, hz):
    if w < 320 or h < 200 or w > 8192 or h > 8192:
        raise ValueError(f"unsupported size {w}x{h}")
    t = cvt_rb1(w, h, hz)
    if t["pclk_khz"] <= DTD_MAX_KHZ:
        t["where"] = "dtd"
        return t
    t = cvt_rb2(w, h, hz)
    t["where"] = "dtd" if t["pclk_khz"] <= DTD_MAX_KHZ else "displayid"
    return t


def dtd(t, size_mm):
    """18-byte detailed timing descriptor."""
    clk = t["pclk_khz"] // 10
    h, hb, v, vb = t["h"], t["h_blank"], t["v"], t["v_blank"]
    hfp, hs, vfp, vs = t["h_front"], t["h_sync"], t["v_front"], t["v_sync"]
    # Image size follows each mode's aspect ratio, at the panel's width.
    wmm = size_mm[0]
    hmm = round(wmm * v / h)
    return bytes([
        clk & 0xFF, clk >> 8,
        h & 0xFF, hb & 0xFF, ((h >> 8) << 4) | (hb >> 8),
        v & 0xFF, vb & 0xFF, ((v >> 8) << 4) | (vb >> 8),
        hfp & 0xFF, hs & 0xFF, ((vfp & 0xF) << 4) | (vs & 0xF),
        ((hfp >> 8) << 6) | ((hs >> 8) << 4) | ((vfp >> 4) << 2) | (vs >> 4),
        wmm & 0xFF, hmm & 0xFF, ((wmm >> 8) << 4) | (hmm >> 8),
        0, 0,
        0x1A,  # digital separate sync, +hsync -vsync (CVT-RB polarity)
    ])


def displayid_type1(t):
    """20-byte DisplayID Type I detailed timing (kernel: drm_mode_displayid_detailed)."""
    def u16(x, flag=0):
        x -= 1
        return bytes([x & 0xFF, ((x >> 8) & 0x7F) | flag])
    clk = t["pclk_khz"] // 10 - 1
    aspect = 8  # "undefined": computed from the active size
    for code, (a, b) in ((2, (4, 3)), (4, (16, 9)), (5, (16, 10))):
        if t["h"] * b == t["v"] * a:
            aspect = code
    return (bytes([clk & 0xFF, (clk >> 8) & 0xFF, clk >> 16, aspect])
            + u16(t["h"]) + u16(t["h_blank"])
            + u16(t["h_front"], 0x80)       # bit 15: hsync positive
            + u16(t["h_sync"])
            + u16(t["v"]) + u16(t["v_blank"])
            + u16(t["v_front"])             # vsync negative
            + u16(t["v_sync"]))


def text_descriptor(tag, text):
    data = text.encode("ascii")[:13]
    if len(data) < 13:
        data += b"\n" + b" " * (12 - len(data))
    return bytes([0, 0, 0, tag, 0]) + data


def checksum(block):
    assert len(block) == 127
    return bytes(block) + bytes([(-sum(block)) % 256])


def base_block(name, size_mm, timings, extensions):
    b = bytearray(b"\x00\xff\xff\xff\xff\xff\xff\x00")
    a, c, d = (ord(ch) - 64 for ch in MFG_ID)
    mfg = (a << 10) | (c << 5) | d
    b += bytes([mfg >> 8, mfg & 0xFF])
    b += bytes([0x01, 0x00])               # product code
    b += bytes([0, 0, 0, 0])               # serial
    b += bytes([1, 2026 - 1990])           # week 1, 2026
    b += bytes([1, 4])                     # EDID 1.4
    b += bytes([0xA5])                     # digital, 8 bpc, DisplayPort
    b += bytes([round(size_mm[0] / 10), round(size_mm[1] / 10)])
    b += bytes([120])                      # gamma 2.2
    b += bytes([0x06])                     # sRGB default, preferred timing is native
    b += bytes([0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54])  # sRGB
    b += bytes([0x20, 0x00, 0x00])         # established: 640x480@60
    b += bytes([0x01, 0x01] * 8)           # no standard timings
    descs = [dtd(t, size_mm) for t in timings[:3]]
    descs.append(text_descriptor(0xFC, name))
    while len(descs) < 4:
        descs.append(bytes([0, 0, 0, 0x10]) + bytes(14))  # dummy descriptor
    for desc in descs:
        b += desc
    b += bytes([extensions])
    return checksum(b)


def cta_block(timings, size_mm):
    # CTA-861 rev 3. Data blocks: video (VIC 1, 640x480p60, which CTA requires)
    # and a video capability block (selectable RGB quantization). Then DTDs.
    data_blocks = bytes([0x41, 0x01, 0xE2, 0x00, 0x40])
    b = bytearray([0x02, 0x03, 4 + len(data_blocks), 0x80])  # 0x80: underscanned
    b += data_blocks
    for t in timings:
        b += dtd(t, size_mm)
    b += bytes(127 - len(b))
    return checksum(b)


def displayid_block(timings):
    payload = bytes([0x03, 0x00, 20 * len(timings)])  # Type I timing block, rev 0
    for t in timings:
        payload += displayid_type1(t)
    section = bytes([0x13, len(payload), 0x03, 0x00]) + payload  # v1.3, standalone display
    section += bytes([(-sum(section)) % 256])
    b = bytearray([0x70]) + section
    b += bytes(127 - len(b))
    return checksum(b)


def build(name, size_mm, modes):
    planned = [plan_mode(*m) for m in modes]
    if planned[0]["where"] != "dtd":
        raise ValueError("the first (preferred) mode must fit a detailed timing; list a slower one first")
    dtds = [t for t in planned if t["where"] == "dtd"]
    dids = [t for t in planned if t["where"] == "displayid"]
    # Overflow past the 9 DTD slots also goes into DisplayID, which can hold
    # any timing.
    for t in dtds[9:]:
        t["where"] = "displayid"
    dids += dtds[9:]
    dtds = dtds[:9]
    if len(dids) > 5:
        raise ValueError(f"{len(dtds) + len(dids)} modes; at most 14 fit (9 DTD + 5 DisplayID)")

    exts = []
    if len(dtds) > 3:
        exts.append(cta_block(dtds[3:], size_mm))
    if dids:
        exts.append(displayid_block(dids))
    return base_block(name, size_mm, dtds, len(exts)) + b"".join(exts), planned


def parse_res(s):
    w, h = s.lower().split("x")
    return int(w), int(h)


def parse_mode(s):
    try:
        res, hz = s.split("@")
        return (*parse_res(res), float(hz))
    except ValueError:
        raise argparse.ArgumentTypeError(f"bad mode {s!r}, expected WxH@Hz")


def default_modes(native, rates, extras):
    nw, nh = native
    modes = [(nw, nh, r) for r in rates]
    for w, h in extras:
        if (w, h) != (nw, nh) and w <= nw and h <= nh:
            modes += [(w, h, r) for r in rates]
    return modes


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--name", default="TabletDisplay", help="monitor name, up to 13 characters")
    ap.add_argument("--native", default=DEFAULT_NATIVE, help="tablet resolution WxH (first rate is preferred)")
    ap.add_argument("--refresh", default=DEFAULT_REFRESH, help="comma-separated refresh rates")
    ap.add_argument("--extra", default=DEFAULT_EXTRA, help="extra resolutions, comma-separated ('' for none)")
    ap.add_argument("--size-mm", default=DEFAULT_SIZE_MM, help="physical size WxH in mm")
    ap.add_argument("--mode", action="append", type=parse_mode,
                    help="WxH@Hz, repeatable; replaces --native/--refresh/--extra; first is preferred")
    args = ap.parse_args()

    try:
        size_mm = parse_res(args.size_mm)
        if args.mode:
            modes = args.mode
        else:
            rates = [float(r) for r in args.refresh.split(",") if r.strip()]
            extras = [parse_res(e) for e in args.extra.split(",") if e.strip()]
            modes = default_modes(parse_res(args.native), rates, extras)
        edid, planned = build(args.name, size_mm, modes)
    except ValueError as e:
        sys.exit(f"make-edid: {e}")

    with open(args.output, "wb") as f:
        f.write(edid)
    for t in planned:
        where = "DisplayID" if t["where"] == "displayid" else "DTD"
        gbps = t["pclk_khz"] * 24 / 1e6
        print(f"{t['h']}x{t['v']} @ {t['refresh']:7.3f} Hz  {t['pclk_khz'] / 1000:7.2f} MHz"
              f"  {gbps:5.1f} Gbit/s  {where}")
    print(f"wrote {len(edid)} bytes to {args.output}")


if __name__ == "__main__":
    main()
