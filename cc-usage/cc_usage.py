#!/usr/bin/env python3
"""Command Code usage meters for the Noctalia cc-usage plugin.

Reads ~/.commandcode/projects/**/*.jsonl (top-level `usage` on assistant
messages) and prints JSON with the same meters the CLI's /usage overlay shows:

  {"title": "22% mes . 5h 11% . 7d 44%", "description": "renova em 28d . ..."}

The numbers are an approximation: windows are simulated from local timestamps
(anchored at the first request, as the usage-limits docs describe) and the
credit multiplier is calibrated against /usage. Set CC_USAGE_PLAN to change the
caps: GOAT (default), PRO, GO, MAX20.
"""
import json
import os
import sys
from datetime import datetime, timedelta

PLANS = {
    # name: (monthly credits, 5h cap, 7d cap)
    "GO": (10.0, 2.0, 5.0),
    "GOAT": (100.0, 20.0, 50.0),
    "PRO": (110.0, 22.0, 55.0),
    "MAX20": (300.0, 90.0, 180.0),
}
PLAN = os.environ.get("CC_USAGE_PLAN", "GOAT").upper()
MONTHLY_CREDITS, CAP_5H, CAP_7D = PLANS.get(PLAN, PLANS["GOAT"])
CREDIT_MULTIPLIER = float(os.environ.get("CC_USAGE_MULTIPLIER", "2.5"))
BILLING_DAY = int(os.environ.get("CC_USAGE_BILLING_DAY", "28"))
DATA_DIR = os.path.expanduser("~/.commandcode/projects")


def parse_events():
    events = []
    for root, _dirs, names in os.walk(DATA_DIR):
        for name in names:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(root, name)
            try:
                with open(path, "r", errors="replace") as f:
                    for line in f:
                        if '"usage"' not in line:
                            continue
                        try:
                            obj = json.loads(line)
                        except ValueError:
                            continue
                        if obj.get("type") != "message":
                            continue
                        if (obj.get("message") or {}).get("role") != "assistant":
                            continue
                        usage = obj.get("usage") or {}
                        ts = obj.get("timestamp")
                        if not ts:
                            continue
                        try:
                            epoch = datetime.fromisoformat(
                                ts.replace("Z", "+00:00")).timestamp()
                        except ValueError:
                            continue
                        events.append((epoch, float(usage.get("costUsd", 0.0))))
            except OSError:
                continue
    events.sort()
    return events


def window_usage(events, span, now):
    start = None
    spent = 0.0
    for ts, cost in events:
        if start is None:
            start = ts
        elif ts >= start + span:
            start = ts
            spent = 0.0
        spent += cost
    if start is None or now >= start + span:
        return 0.0, None
    return spent, start + span


def fmt_left(seconds):
    if seconds is None:
        return "—"
    s = max(0, int(seconds))
    days, rem = divmod(s, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return f"{days}d{hours}h"
    if hours:
        return f"{hours}h{minutes:02d}m"
    return f"{minutes}m"


def cycle_start(now):
    start = now.replace(day=BILLING_DAY, hour=0, minute=0, second=0, microsecond=0)
    if now < start:
        prev = now.replace(day=1) - timedelta(days=1)
        start = prev.replace(day=BILLING_DAY, hour=0, minute=0, second=0, microsecond=0)
    return start


def add_month(dt):
    month = dt.month + 1
    year = dt.year
    if month > 12:
        month = 1
        year += 1
    return dt.replace(year=year, month=month)


def pct(spent, cap):
    if cap <= 0:
        return 0.0
    return min(999.0, spent * CREDIT_MULTIPLIER / cap * 100.0)


def main():
    now_dt = datetime.now()
    now = now_dt.timestamp()
    events = parse_events()

    spent_5h, reset_5h = window_usage(events, 5 * 3600, now)
    spent_7d, reset_7d = window_usage(events, 7 * 86400, now)

    cstart = cycle_start(now_dt)
    cstart_epoch = cstart.timestamp()
    spent_month = sum(c for ts, c in events if ts >= cstart_epoch)
    renew = add_month(cstart)
    secs_left = (renew - now_dt).total_seconds()
    days_left = int((secs_left + 86399) // 86400) if secs_left > 0 else 0

    p_month = pct(spent_month, MONTHLY_CREDITS)
    p_5h = pct(spent_5h, CAP_5H)
    p_7d = pct(spent_7d, CAP_7D)

    result = {
        "title": f"{p_month:.0f}% mês · 5h {p_5h:.0f}% · 7d {p_7d:.0f}%",
        "description": (
            f"renova em {days_left}d"
            f" · 5h {fmt_left(reset_5h - now if reset_5h else None)}"
            f" · 7d {fmt_left(reset_7d - now if reset_7d else None)}"
            f" · {PLAN}"),
        "plan": PLAN,
        "month_percent": round(p_month),
        "five_hour_percent": round(p_5h),
        "weekly_percent": round(p_7d),
        "renew_in_days": days_left,
        "five_hour_reset": fmt_left(reset_5h - now if reset_5h else None),
        "weekly_reset": fmt_left(reset_7d - now if reset_7d else None),
        "updated_at": now_dt.isoformat(timespec="seconds"),
    }
    json.dump(result, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
