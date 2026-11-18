#!/usr/bin/env python3
"""Generate the data tables baked into the Noctalia lunar-calendar plugin.

Source of truth: `lunar_python` (a port of the 6tail Lunar library, which uses
the ShouXing astronomical algorithms). Everything produced here is verified by
round-tripping every day in range back through lunar_python.

Outputs (both written as plain, human-readable tables on purpose - a reviewer
of the plugin should be able to read the numbers it ships):
  * "terms":        one row per Gregorian year, the day of month each of the 24
                    solar terms falls on, in calendar order.
  * "lunar_years":  one row per lunar year: the leap month (0 = none), the 12
                    month lengths, and the leap month's length.
"""
import argparse
import datetime
import pathlib
import sys

from lunar_python import Lunar, Solar, LunarYear

# lunar-calendar/tools/generate_data.py -> the plugin directory it belongs to.
# The only file written unconditionally is the plugin's own lib/data.luau; the
# test fixture is opt-in via --fixtures, so running this never writes outside the
# plugin directory.
PLUGIN = pathlib.Path(__file__).resolve().parents[1]
DATA = PLUGIN / "lib" / "data.luau"

MIN_YEAR = 1900
MAX_YEAR = 2100
EPOCH = datetime.date(1900, 1, 31)  # 农历 1900 年正月初一

TERM_NAMES = [
    "小寒", "大寒", "立春", "雨水", "惊蛰", "春分",
    "清明", "谷雨", "立夏", "小满", "芒种", "夏至",
    "小暑", "大暑", "立秋", "处暑", "白露", "秋分",
    "寒露", "霜降", "立冬", "小雪", "大雪", "冬至",
]


def encode_year(year):
    ly = LunarYear.fromYear(year)
    leap = ly.getLeapMonth()
    # NOTE: LunarYear.getMonths() starts with the previous lunar year's 11th and
    # 12th months (the year is defined from the winter-solstice month), so keep
    # only the months that actually belong to `year`.
    lengths = {}
    for m in ly.getMonths():
        if m.getYear() != year:
            continue
        lengths[m.getMonth()] = m.getDayCount()
    # sanity: every non-leap month 1..12 present, and nothing else
    for m in range(1, 13):
        assert m in lengths, (year, m, sorted(lengths))
    assert len(lengths) == (13 if leap else 12), (year, leap, sorted(lengths))
    if leap:
        assert lengths.get(-leap) is not None, (year, leap, sorted(lengths))
    return leap, lengths


def month_sequence(leap, lens):
    """Month numbers in calendar order from 正月初一."""
    out = []
    for m in range(1, 13):
        out.append(m)
        if leap == m:
            out.append(-m)
    return out


def verify_lunar(years):
    """Round-trip every day 1900-01-31 .. 2100-12-31 through lunar_python.

    `years` maps a lunar year to (leap month, {month: length}) exactly as the
    generated table records it, so this checks the shipped numbers themselves.
    """
    # Lunar new year solar dates, indexed by lunar year.
    cny = {}
    for y in range(MIN_YEAR, MAX_YEAR + 2):
        s = Lunar.fromYmd(y, 1, 1).getSolar()
        cny[y] = datetime.date(s.getYear(), s.getMonth(), s.getDay())
    # Sanity: the encoded year lengths must reproduce every lunar new year.
    day = 0
    for y in range(MIN_YEAR, MAX_YEAR + 1):
        got = EPOCH + datetime.timedelta(days=day)
        if got != cny[y]:
            raise AssertionError(f"new year mismatch {y}: got {got} want {cny[y]}")
        leap, lens = years[y]
        day += sum(lens[m] for m in month_sequence(leap, lens))

    checked = 0
    cur = EPOCH
    end = datetime.date(MAX_YEAR, 12, 31)
    while cur <= end:
        ly = cur.year if cur >= cny[cur.year] else cur.year - 1
        if ly < MIN_YEAR:
            ly = MIN_YEAR
        start = cny[ly]
        offset = (cur - start).days
        leap, lens = years[ly]
        seq = month_sequence(leap, lens)
        month = None
        for m in seq:
            d = lens[m]
            if offset < d:
                month = m
                break
            offset -= d
        if month is None:
            raise AssertionError(f"day outside lunar year {cur} ({ly})")
        ref = Solar.fromYmd(cur.year, cur.month, cur.day).getLunar()
        if (ref.getYear(), ref.getMonth(), ref.getDay()) != (ly, month, offset + 1):
            raise AssertionError(
                f"mismatch {cur}: got {ly}/{month}/{offset+1} want "
                f"{ref.getYear()}/{ref.getMonth()}/{ref.getDay()}"
            )
        checked += 1
        cur += datetime.timedelta(days=1)
    return checked


def solar_terms():
    """Collect the 24 solar-term day numbers for every year in range.

    A lunar year's JieQi table starts at the previous December (its 冬至 key is
    the *previous* Gregorian year's winter solstice), so the December terms of
    year y come from the table anchored in y + 1.
    """
    tables = {y: Lunar.fromYmd(y, 6, 1).getJieQiTable()
              for y in range(MIN_YEAR, MAX_YEAR + 2)}
    rows = []
    for y in range(MIN_YEAR, MAX_YEAR + 1):
        found = {}
        for name in TERM_NAMES[:-1]:  # 小寒 .. 大雪
            s = tables[y][name]
            if s.getYear() != y:
                raise AssertionError(f"year {y}: {name} landed in {s.toYmd()}")
            found[name] = s.getDay()
        last = tables[y + 1]["冬至"]
        if last.getYear() != y:
            raise AssertionError(f"year {y}: 冬至 landed in {last.toYmd()}")
        found["冬至"] = last.getDay()
        if len(found) != 24:
            raise AssertionError(f"year {y}: {len(found)} terms")
        rows.append((y, [found[name] for name in TERM_NAMES]))
    return rows


def ganzhi_day_reference():
    """Find a 甲子 day to anchor the sexagenary day cycle."""
    d = datetime.date(2000, 1, 1)
    for _ in range(80):
        if Solar.fromYmd(d.year, d.month, d.day).getLunar().getDayInGanZhi() == "甲子":
            return d, (d - datetime.date(1970, 1, 1)).days
        d += datetime.timedelta(days=1)
    raise AssertionError("no 甲子 day found")


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Regenerate lunar-calendar's lib/data.luau.")
    parser.add_argument(
        "--fixtures",
        type=pathlib.Path,
        default=None,
        help="also write the test-suite reference fixture (reference.luau) into this directory",
    )
    return parser.parse_args(argv)


def main(fixtures_dir=None):
    years = {}
    for y in range(MIN_YEAR, MAX_YEAR + 1):
        years[y] = encode_year(y)
    print(f"# lunar years read: {len(years)}")

    terms = solar_terms()
    print(f"# solar-term rows: {len(terms)}")

    checked = verify_lunar(years)
    print(f"# verified {checked} days against lunar_python")

    ref_date_obj, ref_num = ganzhi_day_reference()
    ref_date = ref_date_obj.isoformat()
    print(f"# 甲子 day anchor: {ref_date} (day number {ref_num})")

    lines = []
    lines.append("--!nocheck")
    lines.append("-- Generated by tools/generate_data.py (see tools/README.md) - DO NOT EDIT BY HAND.")
    lines.append("-- Source of truth: lunar_python (6tail Lunar, the ShouXing 寿星天文历 algorithms),")
    lines.append("-- which reproduces the Hong Kong Observatory tables for 1900-2100.")
    lines.append("--")
    lines.append("-- terms: one row per Gregorian year,")
    lines.append("--        { year, 小寒, 大寒, 立春, 雨水, ... 冬至 } (day of month, calendar order).")
    lines.append("-- lunar_years: one row per lunar year,")
    lines.append("--        { year, leap, m1 .. m12, leap_days }, where 29/30 are month lengths,")
    lines.append("--        `leap` is the leap month number (0 = none) and `leap_days` its length.")
    lines.append("")
    lines.append("return {")
    lines.append(f"    min_year = {MIN_YEAR},")
    lines.append(f"    max_year = {MAX_YEAR},")
    lines.append("")
    lines.append("    -- Days since 1970-01-01 of a known 甲子 day (sexagenary day anchor).")
    lines.append(f"    ganzhi_ref_day = {ref_num},  -- {ref_date}")
    lines.append("")
    lines.append("    terms = {")
    for year, days in terms:
        lines.append("        { " + ", ".join(str(v) for v in [year] + days) + " },")
    lines.append("    },")
    lines.append("")
    lines.append("    lunar_years = {")
    for year in range(MIN_YEAR, MAX_YEAR + 1):
        leap, lens = years[year]
        row = [year, leap] + [lens[m] for m in range(1, 13)]
        row.append(lens[-leap] if leap else 0)
        lines.append("        { " + ", ".join(str(v) for v in row) + " },")
    lines.append("    },")
    lines.append("}")
    lines.append("")

    DATA.write_text("\n".join(lines), encoding="utf-8")
    print(f"# wrote {DATA}")

    # A Luau reference module for the test harness (Luau CLI has no file IO).
    # Covers 2024-2031 plus a few boundary dates outside that window.
    lines = []
    lines.append("--!nocheck")
    lines.append("-- Generated by tools/generate_data.py - reference data for tests only.")
    lines.append("-- Each row: { lunar year, lunar month (negative = leap), lunar day,")
    lines.append("--             solar term (\"\" when none), day ganzhi, year ganzhi, zodiac }")
    lines.append("return {")
    samples = []
    d = datetime.date(2024, 1, 1)
    while d <= datetime.date(2031, 12, 31):
        samples.append(d)
        d += datetime.timedelta(days=1)
    samples += [datetime.date(1900, 1, 31), datetime.date(1900, 12, 31),
                datetime.date(2100, 1, 1), datetime.date(2100, 12, 31),
                datetime.date(2023, 3, 22), datetime.date(2033, 12, 22)]
    for d in samples:
        l = Solar.fromYmd(d.year, d.month, d.day).getLunar()
        jq = l.getJieQi()
        lines.append(
            f'    ["{d.isoformat()}"] = {{ {l.getYear()}, {l.getMonth()}, {l.getDay()}, '
            f'"{jq}", "{l.getDayInGanZhi()}", "{l.getYearInGanZhi()}", "{l.getYearShengXiao()}" }},'
        )
    lines.append("}")
    lines.append("")
    if fixtures_dir is not None:
        fixtures_dir.mkdir(parents=True, exist_ok=True)
        target = fixtures_dir / "reference.luau"
        target.write_text("\n".join(lines), encoding="utf-8")
        print(f"# wrote {target} with {len(samples)} days")
    else:
        print("# (skipped the test fixture; pass --fixtures <dir> to write it)")


if __name__ == "__main__":
    main(parse_args(sys.argv[1:]).fixtures)
