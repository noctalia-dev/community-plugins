#!/usr/bin/env python3
"""Generate jalali_calendar/data/occasions.luau from two CC0 datasets.

Build-time tool only. It is never shipped to users and never runs on their
machine. It fetches nothing: pass already-downloaded inputs, so the output is
reproducible and auditable.

Inputs (both CC0 1.0 Universal / public domain):

  --events   persian-calendar/events        events.json
             Occasion and holiday definitions. Iran's entries are transcribed
             from the official University of Tehran calendar.
  --qamari   roozbehp/qamari                consolidated.txt
             The first Gregorian day of each Lunar Hijri month *as actually
             used in Iran*. This is the primary source; do not substitute a
             computed Islamic calendar, which disagrees with Iran's official
             sighting-based dates by a day or two.

Occasions are emitted by rule, not resolved per year: Persian occasions keyed
by (month, day), Hijri ones by (hijri month, hijri day), Gregorian ones by
(month, day). The runtime converts a date into all three calendars and looks
up each table. That keeps the table small and readable, and keeps it correct
for years beyond the ones anyone thought to generate.

Usage:
  generate_occasions.py --selftest
  generate_occasions.py --events events.json --qamari consolidated.txt \
      --output ../data/occasions.luau
"""

import argparse
import re
import datetime
import json
import sys
from collections import defaultdict

BREAKS = [-61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181, 1210, 1635, 2060]

# Source sets we emit. "International" is left out (85 world-observance rows
# that would swamp the calendar) and so is "IranFormer" (a single superseded
# entry).
#
# Iran's rows are grouped into civil and cultural days and religious
# observances, each a toggle in the plugin's settings. Rows matching
# EXCLUDED_MARKERS are not carried at all, except public holidays.
TYPE_CATEGORY = {
    "AncientIran": "ancient",
    "Afghanistan": "afghan",
}

# Ordered rules, exclusions first, so a title that matches both lists stays
# excluded.
#
# These are keyword heuristics over Persian titles, not a curated taxonomy --
# the upstream data ships none. They are listed in full so they can be audited
# and corrected. Substring matching means short words are dangerous: "بیعت"
# was removed because it matches inside "طبیعت" and excluded Nature Day.
EXCLUDED_MARKERS = [
    "انقلاب", "خمینی", "خامنه", "رهبر معظم", "بسیج", "سپاه", "دفاع مقدس",
    "جنگ", "استکبار", "قدس", "ولایت فقیه", "ستم‌شاهی", "ستمشاهی", "طاغوت",
    "پهلوی", "رضاخان", "رضا شاه", "آمریکا", "امریکا", "اسرائیل", "صهیونیس",
    "فتح‌المبین", "کربلای", "عملیات", "ارتحال", "نهضت", "شهدا", "شهید",
    "شهادت", "جمهوری اسلامی", "حزب‌الله", "منافق", "ساواک", "تسخیر",
    "جاسوسی", "بیداری اسلامی", "مقاومت", "خرمشهر", "اشغال", "تجاوز",
    "انتفاضه", "حجاب و عفاف", "نماز جمعه", "ارتش", "پدافند", "قرارگاه",
    "نیروی زمینی", "نیروی دریایی", "نیروی هوایی", "انتظامی", "بعث", "صدام",
    "آزادسازی", "بیت‌المقدس", "قیام",
    "فلسطین", "اقصی", "غزه", "حماسه", "جهاد", "استعمار", "تروریسم",
    "نسل‌کشی", "صنعت دفاعی", "فناوری هسته‌ای", "روز سرباز",
]

RELIGIOUS_MARKERS = [
    "(ع)", "(ص)", "(س)", "(عج)", "امام", "حضرت", "آیت‌الله", "آیت الله",
    "عید سعید", "مبعث", "قرآن", "مسجد", "حوزه علمیه", "روحانیت", "طلاب",
    "اعتکاف", "زیارت", "تشیع", "شیعه", "اسلام", "محرم", "رمضان", "دینی",
    "مذهبی",
]


def normalize_title(title):
    """Strip religious honorifics from an event name.

    "حضرت" ("His/Her Holiness") is an honorific, not part of a name, so
    "شهادت حضرت امام علی" becomes "شهادت امام علی". "سعید" ("blessed") is
    stripped only in the fixed phrase "عید سعید" -- it is also a surname, and
    a blind removal would mangle "آیت‌الله سعیدی".

    The event itself is unchanged; only the honorific is removed.
    """
    title = title.replace("عید سعید", "عید")
    title = re.sub(r"حضرت\s+", "", title)
    title = re.sub(r"\s{2,}", " ", title)
    return title.strip()


def classify(event):
    """Group one Iranian event, or return "excluded" for a row on the
    exclusion list. Lunar-calendar rows are religious observances almost by
    definition, which is why the calendar itself is a signal."""
    title = event["title"]
    if any(k in title for k in EXCLUDED_MARKERS):
        return "excluded"
    if event["calendar"] == "Hijri" or any(k in title for k in RELIGIOUS_MARKERS):
        return "religious"
    return "national"


def holiday_group(event):
    """Group for a public holiday whose title is on the exclusion list.

    Holidays are always carried, so they need a real group. The calendar they
    are fixed in decides it: lunar holidays are religious, solar ones national.
    Title keywords are deliberately not used here -- "اسلام" and "امام" occur
    in the names of solar national holidays too.
    """
    return "religious" if event["calendar"] == "Hijri" else "national"


def idiv(a, b):
    """Integer division truncating toward zero. NOT Python's //, which floors."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def imod(a, b):
    return a - idiv(a, b) * b


def gregorian_to_jdn(gy, gm, gd):
    d = (idiv((gy + idiv(gm - 8, 6) + 100100) * 1461, 4)
         + idiv(153 * imod(gm + 9, 12) + 2, 5)
         + gd - 34840408)
    return d - idiv(idiv(gy + 100100 + idiv(gm - 8, 6), 100) * 3, 4) + 752


def gregorian_from_jdn(jdn):
    j = 4 * jdn + 139361631
    j = j + idiv(idiv(4 * jdn + 183187720, 146097) * 3, 4) * 4 - 3908
    i = idiv(imod(j, 1461), 4) * 5 + 308
    gd = idiv(imod(i, 153), 5) + 1
    gm = imod(idiv(i, 153), 12) + 1
    gy = idiv(j, 1461) - 100100 + idiv(8 - gm, 6)
    return gy, gm, gd


def jal_cal(jy):
    """Returns (gregorian year of Nowruz, March day of Nowruz, leap indicator)."""
    gy = jy + 621
    leap_j = -14
    jp = BREAKS[0]
    if jy < jp or jy >= BREAKS[-1]:
        raise ValueError(f"jalali year out of range: {jy}")

    jump = 0
    for jm in BREAKS[1:]:
        jump = jm - jp
        if jy < jm:
            break
        leap_j += idiv(jump, 33) * 8 + idiv(imod(jump, 33), 4)
        jp = jm

    n = jy - jp
    leap_j += idiv(n, 33) * 8 + idiv(imod(n, 33) + 3, 4)
    if imod(jump, 33) == 4 and jump - n == 4:
        leap_j += 1

    leap_g = idiv(gy, 4) - idiv((idiv(gy, 100) + 1) * 3, 4) - 150
    march = 20 + leap_j - leap_g

    nn = n - jump + idiv(jump + 4, 33) * 33 if jump - n < 6 else n
    leap = imod(imod(nn + 1, 33) - 1, 4)
    if leap == -1:
        leap = 4
    return gy, march, leap


def jalali_to_jdn(jy, jm, jd):
    gy, march, _ = jal_cal(jy)
    return gregorian_to_jdn(gy, 3, march) + (jm - 1) * 31 - idiv(jm, 7) * (jm - 7) + jd - 1


def jalali_from_jdn(jdn):
    gy = gregorian_from_jdn(jdn)[0]
    jy = gy - 621
    _, march, leap = jal_cal(jy)
    k = jdn - gregorian_to_jdn(gy, 3, march)
    if k >= 0:
        if k <= 185:
            return jy, 1 + idiv(k, 31), imod(k, 31) + 1
        k -= 186
    else:
        jy -= 1
        k += 179
        if leap == 1:
            k += 1
    return jy, 7 + idiv(k, 30), imod(k, 30) + 1


def selftest():
    """Assert the port matches lib/jalali.luau before it is trusted with data."""
    assert gregorian_to_jdn(2000, 1, 1) == 2451545
    assert jalali_to_jdn(1400, 1, 1) == gregorian_to_jdn(2021, 3, 21)
    assert jalali_to_jdn(1403, 1, 1) == gregorian_to_jdn(2024, 3, 20)
    assert jalali_to_jdn(1404, 1, 1) == gregorian_to_jdn(2025, 3, 21)
    assert jalali_to_jdn(1405, 1, 1) == gregorian_to_jdn(2026, 3, 21)
    assert jalali_to_jdn(1403, 12, 30) == gregorian_to_jdn(2025, 3, 20)
    assert jalali_from_jdn(gregorian_to_jdn(2026, 9, 22)) == (1405, 6, 31)
    assert jalali_from_jdn(gregorian_to_jdn(2026, 9, 23)) == (1405, 7, 1)
    for jdn in range(jalali_to_jdn(1300, 1, 1), jalali_to_jdn(1500, 1, 1)):
        assert jalali_to_jdn(*jalali_from_jdn(jdn)) == jdn
    print("selftest ok")


def lua_string(s):
    """Escape for a Luau double-quoted string. Persian text passes through as
    UTF-8; only quotes and backslashes need handling."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def parse_qamari(path, min_year, max_year):
    """consolidated.txt lines look like: 1447/1 2025-06-27 # calendar-center

    An asterisk marks a month where observation differed from the published
    calendar; the listed date is what was observed. We take the line as given.
    """
    starts = defaultdict(dict)
    for raw in open(path, encoding="utf-8"):
        line = raw.split("#", 1)[0].strip().rstrip("*").strip()
        if not line:
            continue
        ym, _, date = line.partition(" ")
        hy_s, _, hm_s = ym.partition("/")
        try:
            hy, hm = int(hy_s), int(hm_s)
            gy, gm, gd = (int(x) for x in date.strip().split("-"))
        except ValueError:
            continue
        if min_year <= hy <= max_year:
            starts[hy][hm] = gregorian_to_jdn(gy, gm, gd)
    return starts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--events")
    ap.add_argument("--qamari")
    ap.add_argument("--output")
    ap.add_argument("--events-sha", default="unknown")
    ap.add_argument("--qamari-sha", default="unknown")
    ap.add_argument("--hijri-min", type=int, default=1400)
    ap.add_argument("--hijri-max", type=int, default=1500)
    args = ap.parse_args()

    if args.selftest:
        selftest()
        return 0

    if not (args.events and args.qamari and args.output):
        ap.error("--events, --qamari and --output are required")

    selftest()

    events = json.load(open(args.events, encoding="utf-8"))["data"]
    wanted = [e for e in events if e.get("type") in ("Iran",) or e.get("type") in TYPE_CATEGORY]

    solar = defaultdict(lambda: defaultdict(list))
    lunar = defaultdict(lambda: defaultdict(list))
    lunar_eom = defaultdict(list)
    gregorian = defaultdict(lambda: defaultdict(list))
    skipped = []

    excluded = 0
    for e in wanted:
        category = TYPE_CATEGORY.get(e["type"]) or classify(e)
        is_holiday = bool(e["holiday"])

        # Rows on the exclusion list are not carried. Public holidays are the
        # exception: dropping a day off would make the calendar wrong about the
        # working week, so those stay, filed under a real group.
        if category == "excluded":
            if not is_holiday:
                excluded += 1
                continue
            category = holiday_group(e)

        entry = (normalize_title(e["title"]), is_holiday, category)
        cal, rule = e["calendar"], e["rule"]
        if rule == "simple":
            if cal == "Persian":
                solar[e["month"]][e["day"]].append(entry)
            elif cal == "Hijri":
                lunar[e["month"]][e["day"]].append(entry)
            elif cal == "Gregorian":
                gregorian[e["month"]][e["day"]].append(entry)
            else:
                skipped.append(e)
        elif rule == "end of month" and cal == "Hijri":
            lunar_eom[e["month"]].append(entry)
        else:
            # Weekday-relative and one-off rules. Reported, never silently
            # dropped; none of the survivors is an official holiday.
            skipped.append(e)

    starts = parse_qamari(args.qamari, args.hijri_min, args.hijri_max)

    # The source is explicitly "not considered final" and is missing some
    # months mid-year. Leaving those holes would make a single "day of month"
    # span 147 days, so gaps are bridged by distributing tabular 29/30-day
    # lengths between the two observed anchors. The sequence then reconnects
    # exactly on the next observed start, and only the bridged months are
    # marked approximate.
    observed = sorted(
        (hy * 12 + (hm - 1), jdn)
        for hy, months in starts.items()
        for hm, jdn in months.items()
    )

    by_index = {}
    interpolated = set()
    for (idx_a, jdn_a), (idx_b, jdn_b) in zip(observed, observed[1:]):
        by_index[idx_a] = jdn_a
        span = idx_b - idx_a
        if span <= 1:
            continue
        total = jdn_b - jdn_a
        base, rem = divmod(total, span)
        cursor = jdn_a
        for k in range(span - 1):
            # The longer months go first; any split summing to `total` keeps
            # the reconnection exact, which is what actually matters.
            cursor += base + (1 if k < rem else 0)
            by_index[idx_a + k + 1] = cursor
            interpolated.add(idx_a + k + 1)
    by_index[observed[-1][0]] = observed[-1][1]

    emitted = defaultdict(list)
    for idx in sorted(by_index):
        emitted[idx // 12].append(by_index[idx])

    # An observed month start is only trustworthy if every month before it is
    # too; exactness is reported per month, not as one horizon.
    approx_keys = sorted(f"{i // 12}:{i % 12 + 1}" for i in interpolated)

    max_jdn = observed[-1][1]
    hy_lo, hy_hi = min(emitted), max(emitted)

    out = []
    w = out.append
    w("--!nonstrict")
    w("-- Iranian calendar occasions and Lunar Hijri month starts.")
    w("--")
    w("-- GENERATED by tools/generate_occasions.py -- do not edit by hand.")
    w(f"-- Generated {datetime.date.today().isoformat()}.")
    w("--")
    w("-- Sources, both CC0 1.0 Universal (public domain):")
    w(f"--   Occasions:    github.com/persian-calendar/events @ {args.events_sha}")
    w("--                 Iran's entries transcribe the official University of")
    w("--                 Tehran calendar (calendar.ut.ac.ir).")
    w(f"--   Month starts: github.com/roozbehp/qamari @ {args.qamari_sha}")
    w("--                 The first Gregorian day of each Hijri month as")
    w("--                 actually observed in Iran.")
    w("--")
    w("-- Occasions are keyed by rule, not resolved per Jalali year: the runtime")
    w("-- converts a date into all three calendars and looks up each table, so")
    w("-- these stay correct for any year.")
    w("--")
    w("-- Entry shape: { title, isOfficialHoliday, category }")
    w("--")
    w("-- category is one of:")
    w("--   national   Iranian civil, cultural and scientific days")
    w("--   religious  Shia and Islamic observances")
    w("--   ancient    pre-Islamic / Zoroastrian Iranian festivals")
    w("--   afghan     Afghan national days")
    w("--")
    w("-- The Iranian split is keyword-based, not a curated taxonomy; see")
    w("-- tools/generate_occasions.py for the rules.")
    w("")
    w("return {")
    w("  version = 1,")
    w("")
    w("  -- Fixed Jalali dates: solar[month][day]")
    w("  solar = {")
    for jm in sorted(solar):
        w(f"    [{jm}] = {{")
        for jd in sorted(solar[jm]):
            items = ", ".join(
                f"{{ {lua_string(t)}, {str(h).lower()}, {lua_string(c)} }}"
                for t, h, c in solar[jm][jd]
            )
            w(f"      [{jd}] = {{ {items} }},")
        w("    },")
    w("  },")
    w("")
    w("  -- Fixed Lunar Hijri dates: lunar[month][day]")
    w("  lunar = {")
    for hm in sorted(lunar):
        w(f"    [{hm}] = {{")
        for hd in sorted(lunar[hm]):
            items = ", ".join(
                f"{{ {lua_string(t)}, {str(h).lower()}, {lua_string(c)} }}"
                for t, h, c in lunar[hm][hd]
            )
            w(f"      [{hd}] = {{ {items} }},")
        w("    },")
    w("  },")
    w("")
    w("  -- Occasions on the last day of a Hijri month, whether it runs 29 or 30")
    w("  -- days: lunarEndOfMonth[month]")
    w("  lunarEndOfMonth = {")
    for hm in sorted(lunar_eom):
        items = ", ".join(
            f"{{ {lua_string(t)}, {str(h).lower()}, {lua_string(c)} }}"
            for t, h, c in lunar_eom[hm]
        )
        w(f"    [{hm}] = {{ {items} }},")
    w("  },")
    w("")
    w("  -- Fixed Gregorian dates: gregorian[month][day]")
    w("  gregorian = {")
    for gm in sorted(gregorian):
        w(f"    [{gm}] = {{")
        for gd in sorted(gregorian[gm]):
            items = ", ".join(
                f"{{ {lua_string(t)}, {str(h).lower()}, {lua_string(c)} }}"
                for t, h, c in gregorian[gm][gd]
            )
            w(f"      [{gd}] = {{ {items} }},")
        w("    },")
    w("  },")
    w("")
    w("  -- JDN of the first day of each Hijri month, ascending within a year.")
    w("  -- Iran publishes these about a year ahead, so the table simply stops at")
    w(f"  -- hijriExactMaxJDN ({max_jdn}). Past that the runtime continues the")
    w("  -- sequence arithmetically and marks the result approximate.")
    w(f"  hijriYearMin = {hy_lo},")
    w(f"  hijriYearMax = {hy_hi},")
    w(f"  hijriExactMaxJDN = {max_jdn},")
    w("")
    w("  -- Months bridged across a gap in the source data, keyed \"year:month\".")
    w("  -- Their dates are interpolated, not observed, so they are reported as")
    w("  -- approximate even though they sit inside the table's range.")
    w("  hijriInterpolated = {")
    for key in approx_keys:
        w(f"    [\"{key}\"] = true,")
    w("  },")
    w("")
    w("  hijriMonths = {")
    for hy in sorted(emitted):
        months = ", ".join(str(j) for j in emitted[hy])
        w(f"    [{hy}] = {{ {months} }},")
    w("  },")
    w("}")
    w("")

    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out))

    counts = (
        sum(len(v) for m in solar.values() for v in m.values()),
        sum(len(v) for m in lunar.values() for v in m.values()),
        sum(len(v) for v in lunar_eom.values()),
        sum(len(v) for m in gregorian.values() for v in m.values()),
    )
    print(f"wrote {args.output}")
    print(f"  solar={counts[0]} lunar={counts[1]} lunarEndOfMonth={counts[2]} gregorian={counts[3]}")
    print(f"  excluded {excluded} entries")
    print(f"  hijri years {hy_lo}-{hy_hi}, exact through JDN {max_jdn} "
          f"({'-'.join(str(x) for x in gregorian_from_jdn(max_jdn))})")
    if skipped:
        print(f"  SKIPPED {len(skipped)} weekday-relative / one-off rules "
              f"({sum(1 for e in skipped if e['holiday'])} of them holidays):")
        for e in skipped:
            print(f"    [{e['calendar']}/{e['rule']}] {e['title'][:70]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
