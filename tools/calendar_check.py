#!/usr/bin/env python3
"""Check the seasonal calendar (themes/events.json + themes.py): print the event per day and
assert the key dates. Every event counts as having its theme folder, made or not.

    python3 tools/calendar_check.py [from YYYY-MM-DD] [to YYYY-MM-DD] [-q]
"""
from __future__ import annotations

import datetime as dt
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import themes  # noqa: E402

_real_exists = Path.exists
themes.Path.exists = lambda self: True if self.name == "theme.json" else _real_exists(self)  # type: ignore


def pick(day: str, **cfg):
    return themes.pick_event(cfg, dt.date.fromisoformat(day))


def check(day: str, event: str | None, level: int | None = None, **cfg) -> None:
    p = pick(day, **cfg)
    got = p["event"] if p else None
    assert got == event, f"{day}: wanted {event}, got {p}"
    if level is not None:
        assert p and p["level"] == level, f"{day}: wanted level {level}, got {p}"


def asserts() -> None:
    # date rules
    rd = themes.resolve_date
    arrival = {"month": 11, "day": 12, "weekday": "sat"}
    known = {2018: "11-17", 2019: "11-16", 2020: "11-14", 2021: "11-13", 2022: "11-12",
             2023: "11-18", 2024: "11-16", 2025: "11-15", 2026: "11-14"}
    for y, md in known.items():
        assert rd(arrival, y).strftime("%m-%d") == md, (y, rd(arrival, y))
    kings = {"month": 4, "day": 27, "move": {"sun": -1}}
    assert rd(kings, 2025) == dt.date(2025, 4, 26)        # a Sunday
    assert rd(kings, 2027) == dt.date(2027, 4, 27)
    assert rd({"month": 11, "weekday": "thu", "nth": 4}, 2026) == dt.date(2026, 11, 26)  # nth still works
    assert rd({"easter": -50}, 2027) == dt.date(2027, 2, 6)

    # 2026/27 season
    check("2026-10-31", "halloween", 8)
    check("2026-11-09", None)
    check("2026-11-10", None)                         # St Maarten: only the day itself
    check("2026-11-11", "stmaarten", 8)                 # beats carnaval-opening
    check("2026-11-11", "carnaval-opening", 5, themes_disabled_types=["stmaarten"])
    check("2026-11-12", None)
    check("2026-11-14", "sinterklaas-intocht", 6)
    check("2026-11-15", "sinterklaas")
    check("2026-12-05", "sinterklaas-pakjesavond", 8)
    check("2026-12-06", "christmas")
    check("2026-12-24", "christmas", 8)
    check("2026-12-31", "newyear", 8)
    check("2027-01-01", "newyear", 8)
    check("2027-01-02", None)
    check("2027-02-06", "carnaval", 8)
    check("2027-02-09", "carnaval", 8)
    check("2027-02-14", "valentine", 8)
    check("2027-03-28", "easter", 8)
    check("2027-03-29", "easter", 8)
    check("2027-04-27", "kingsday", 8)
    check("2027-11-13", "sinterklaas-intocht")          # default rule, no per-year date

    # names: families, single ids, types
    check("2026-11-14", "sinterklaas", themes_disabled_types=["sinterklaas-intocht"])
    check("2026-11-14", None, themes_disabled_types=["sinterklaas"])
    check("2026-12-05", None, themes_disabled_types=["Sinterklaas"])
    check("2026-12-31", "christmas", themes_disabled_types=["newyear"])
    p = pick("2026-07-01", themes_force="sinterklaas-intocht")
    assert p == {"theme": "sinterklaas", "level": 8, "event": "sinterklaas-intocht"}, p
    p = pick("2026-07-01", themes_force="carnaval")
    assert p["theme"] == "carnaval" and p["event"] == "carnaval", p
    p = pick("2026-07-01", themes_force="halloween")
    assert p["theme"] == "halloween", p
    assert themes.pick_theme({}, dt.date(2026, 11, 14)) == ("sinterklaas", 6)


def table(start: dt.date, end: dt.date) -> None:
    run = None
    d = start
    while d <= end:
        p = themes.pick_event({}, d)
        key = (p["event"], p["level"]) if p else None
        if run is None or key != run[1]:
            if run:
                print_run(run)
            run = [d, key, d]
        else:
            run[2] = d
        d += dt.timedelta(days=1)
    if run:
        print_run(run)


def print_run(run) -> None:
    a, key, b = run
    span = a.strftime("%a %Y-%m-%d") + (" .. " + b.strftime("%a %m-%d") if b != a else "")
    print(f"{span:<30} {key[0] + ' level ' + str(key[1]) if key else '-'}")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "-q"]
    start = dt.date.fromisoformat(args[0]) if args else dt.date(2026, 10, 15)
    end = dt.date.fromisoformat(args[1]) if len(args) > 1 else dt.date(2027, 5, 1)
    if "-q" not in sys.argv:
        table(start, end)
    asserts()
    print("calendar ok")
