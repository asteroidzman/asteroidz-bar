#!/usr/bin/env bash
# reminders-test.sh — the reminders plugin's scheduling, as pure logic.
#
# No Wayland, no bar, no compositor: `scheduled_today` and `reload_doses` are
# ordinary functions over a JSON document, and the bug that prompted this file
# was invisible to every test that drives the UI. An air filter set to every 30
# days went off the day after it was created, because the scheduler read
# `frequency` while the form wrote `frequencyValue` -- so the interval defaulted
# to 1 and the modulo that enforces it was never reached.
#
# That is a spelling mistake between two halves of one file. Nothing that clicks
# on things can see it; a test that calls the function can see it immediately.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$HERE/plugins/asteroidz-bar-reminders" <<'PY'
import importlib.machinery, importlib.util, json, os, sys, tempfile
from datetime import date, datetime, timedelta

# The plugin has no .py suffix -- it is installed as a program -- so it is
# loaded by path. Its __main__ guard means importing it starts nothing.
spec = importlib.util.spec_from_loader(
    "reminders", importlib.machinery.SourceFileLoader("reminders", sys.argv[1]))
rem = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rem)

PASS = FAIL = 0
def ok(m):
    global PASS; PASS += 1; print("  ok   " + m)
def bad(m):
    global FAIL; FAIL += 1; print("  FAIL " + m)
def check(cond, m):
    ok(m) if cond else bad(m)

START = date(2026, 8, 1)
def med(freq, unit="days", start=START, key="frequencyValue"):
    return {"id": "x", "name": "air filter", "times": ["12:00"],
            key: freq, "frequencyUnit": unit,
            "startDate": start.strftime("%Y-%m-%d"), "enabled": True}

# ── the reported bug ────────────────────────────────────────────────────────
m30 = med(30)
check(rem.scheduled_today(m30, START),
      "a 30-day reminder is due on its start date")
check(not rem.scheduled_today(m30, START + timedelta(days=1)),
      "...and NOT the day after (the bug: it fired)")
check(not rem.scheduled_today(m30, START + timedelta(days=29)),
      "...nor on day 29")
check(rem.scheduled_today(m30, START + timedelta(days=30)),
      "...and is due again on day 30")
check(not rem.scheduled_today(m30, START + timedelta(days=31)),
      "...and silent on day 31")
check(rem.scheduled_today(m30, START + timedelta(days=60)),
      "...and due on day 60, so the cycle repeats")

# ── the cases that were already right, which must stay right ────────────────
check(all(rem.scheduled_today(med(1), START + timedelta(days=i))
          for i in range(5)),
      "a daily reminder is due every day")
check(not rem.scheduled_today(m30, START - timedelta(days=1)),
      "nothing is due before its start date")
check(rem.scheduled_today(med(2), START + timedelta(days=2)),
      "every-2-days lands on day 2")
check(not rem.scheduled_today(med(2), START + timedelta(days=3)),
      "...and not on day 3")

# A unit this code does not implement must not silently become "every day at
# the wrong interval" -- with a non-days unit the modulo is skipped on purpose.
check(rem.scheduled_today(med(30, unit="weeks"), START + timedelta(days=1)),
      "an unhandled frequency unit falls back to daily rather than misfiring")

# The old spelling still works, for a file written before the form settled.
check(not rem.scheduled_today(med(30, key="frequency"),
                              START + timedelta(days=1)),
      "a document using the older `frequency` key is still honoured")

# A document with no interval at all is daily, not never.
check(rem.scheduled_today(
        {"startDate": START.strftime("%Y-%m-%d"), "times": ["12:00"]},
        START + timedelta(days=1)),
      "a reminder with no frequency at all is daily")

# ── end to end, through the real document reader ────────────────────────────
#
# scheduled_today can be right while nothing calls it. This goes through
# reload_doses, which is what actually decides whether the pill lights up.
with tempfile.TemporaryDirectory() as tmp:
    os.environ["XDG_STATE_HOME"] = tmp
    os.makedirs(os.path.join(tmp, "waybar-medication"), exist_ok=True)
    today = datetime.now().date()
    doc = {"version": 1, "doseState": {}, "history": [],
           "medications": [
               # Started yesterday on a 30-day cycle: not today's business.
               med(30, start=today - timedelta(days=1)),
               # Daily, started today: today's business.
               {"id": "d", "name": "escitalopram", "times": ["08:00"],
                "frequencyValue": 1, "frequencyUnit": "days",
                "startDate": today.strftime("%Y-%m-%d"), "enabled": True},
           ]}
    open(rem.store_path(), "w").write(json.dumps(doc))
    rem.reload_doses()
    names = sorted({d["name"] for d in rem.doses})
    check(names == ["escitalopram"],
          "reload_doses lists only what is scheduled today (%s)" % (names,))

print()
print("  %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
