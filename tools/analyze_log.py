#!/usr/bin/env python3
"""
analyze_log.py: recompute TagAlert's reported results from its CSV test logs.

Usage:
    python3 tools/analyze_log.py logs/*.csv            # one summary per session
    python3 tools/analyze_log.py --totals logs/*.csv   # plus project-wide totals

For each scan session (SESSION_START to SESSION_STOP) it reports:
  - test marker (MARK rows, e.g. "B7 Start") and app build
  - session length and scan cycles
  - each confirmed AirTag: seconds from Start Scanning to confirmation, signal
  - threat changes (Low/Medium/High) with time, walked distance and presence
  - notifications, Find This Tag? prompts, automatic beeps
  - beep commands accepted / sent
  - battery % at start and end (iOS reports battery to apps in 5% steps)
Only LIVE rows are counted; DEMO rows are reported and ignored.

Row types handled: SESSION_START, SESSION_STOP, SCAN_START, SCAN_END, ADV, PERIPHERAL,
FIRST_SEEN, PROBE_START, PROBE_RESULT, DETECTED, THREAT_CHANGE, MOVE, MOTION, NOTIFY,
FIND_PROMPT, AUTO_BEEP, SOUND, SOUND_START, SOUND_RESULT, CLEAR, MARK, FILTER_PHASE_START
(early builds). Rows logged after SESSION_STOP (for example a beep sent after scanning
stopped) are counted with the session they follow. Unknown types are counted and listed.

Duplicate rows (the same row in two exported files) are removed, so overlapping exports
can be passed together.
"""
import csv, sys, re, os, statistics as st
from collections import Counter
from datetime import datetime

KNOWN = {"SESSION_START", "SESSION_STOP", "SCAN_START", "SCAN_END", "ADV", "PERIPHERAL",
         "FIRST_SEEN", "PROBE_START", "PROBE_RESULT", "DETECTED", "THREAT_CHANGE", "MOVE",
         "MOTION", "NOTIFY", "FIND_PROMPT", "AUTO_BEEP", "SOUND", "SOUND_START", "SOUND_RESULT", "CLEAR", "MARK",
         "FILTER_PHASE_START"}


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def kv(note):
    return dict(re.findall(r"(\w+)=([^\s]+)", note or ""))


def load(paths):
    seen, rows = set(), []
    for p in paths:
        with open(p, newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                if not r.get("iso_time") or r.get("event") == "event":
                    continue
                key = tuple(r.get(k, "") for k in ("iso_time", "event", "tag_id", "rssi", "note"))
                if key in seen:
                    continue
                seen.add(key)
                r["_t"] = ts(r["iso_time"])
                r["_file"] = os.path.basename(p)
                rows.append(r)
    rows.sort(key=lambda r: r["_t"])
    return rows


def sessions(rows):
    out, cur, mark = [], None, ""
    for r in rows:
        e = r["event"]
        if e == "MARK":
            mark = r["note"]
            if cur:
                cur["marks"].append(r["note"])
            continue
        if e == "SESSION_START":
            cur = {"start": r["_t"], "end": r["_t"], "note": r["note"], "mark": mark,
                   "file": r["_file"], "rows": [], "marks": []}
            out.append(cur)
            continue
        if cur is None:
            continue
        cur["rows"].append(r)
        if not cur.get("stopped"):
            cur["end"] = r["_t"]
        if e == "SESSION_STOP":
            cur["stopped"] = True
    return out


def summarize(s, totals):
    rel = lambda r: (r["_t"] - s["start"]).total_seconds()
    rows = [r for r in s["rows"] if r.get("mode", "LIVE") != "DEMO"]
    demo = len(s["rows"]) - len(rows)
    build = kv(s["note"]).get("build", "?")
    app = kv(s["note"]).get("app", "?")
    cycles = sum(1 for r in rows if r["event"] == "SCAN_END")
    length = (s["end"] - s["start"]).total_seconds()
    if length < 1 and cycles == 0:
        return
    print(f"\n== {s['file']}  start {s['start']:%Y-%m-%d %H:%M:%S} UTC  marker: {s['mark'] or '-'}  app {app} build {build}")
    print(f"   length {length:.0f} s, {cycles} scan cycles" + (f", {demo} DEMO rows ignored" if demo else ""))

    confirmed = [(r["tag_id"], rel(r), r["rssi"]) for r in rows
                 if r["event"] == "PROBE_RESULT" and kv(r["note"]).get("airtag") == "true"]
    probes = Counter(kv(r["note"]).get("reason", "?").split()[0] for r in rows if r["event"] == "PROBE_RESULT")
    for tag, t, rssi in confirmed:
        print(f"   CONFIRMED {tag}  {t:6.1f} s  {rssi} dBm")
        totals["confirm"].append(t)
    if probes:
        print("   probe results: " + ", ".join(f"{k} {v}" for k, v in sorted(probes.items())))

    for r in rows:
        e, k = r["event"], kv(r["note"])
        if e == "THREAT_CHANGE":
            print(f"   {r['threat'] or '?':6} {r['tag_id']}  {rel(r):6.1f} s  age {k.get('age_s', '?')} s  "
                  f"walk {k.get('walk_m', '?')} m  presence {k.get('presence_pct', '?')}%  moved {k.get('moved', '?')}")
        elif e in ("NOTIFY", "FIND_PROMPT", "AUTO_BEEP", "CLEAR"):
            print(f"   {e:12} {r['tag_id']}  {rel(r):6.1f} s  {r['threat']}  {r['note'][:60]}")
            if e == "NOTIFY":
                totals["notify"] += 1

    beeps = [r for r in rows if r["event"] == "SOUND_RESULT"]
    if beeps:
        ok = sum(1 for r in beeps if kv(r["note"]).get("ok") == "true")
        print(f"   beep accepted {ok} / {len(beeps)}: " +
              ", ".join(f"{r['tag_id']} {'ok' if kv(r['note']).get('ok') == 'true' else 'fail'} {r['rssi']}" for r in beeps))
        totals["beep_ok"] += ok
        totals["beep_sent"] += len(beeps)

    batt = [int(r["battery_pct"]) for r in rows if r.get("battery_pct", "").lstrip("-").isdigit()]
    if batt:
        print(f"   battery {batt[0]}% to {batt[-1]}% (5% steps)")

    unknown = Counter(r["event"] for r in rows if r["event"] not in KNOWN)
    if unknown:
        print("   unknown row types: " + ", ".join(f"{k} {v}" for k, v in unknown.items()))


def main(argv):
    show_totals = "--totals" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if not paths:
        print(__doc__)
        return 1
    totals = {"confirm": [], "notify": 0, "beep_ok": 0, "beep_sent": 0}
    for s in sessions(load(paths)):
        summarize(s, totals)
    if show_totals:
        c = totals["confirm"]
        print("\n== TOTALS")
        if c:
            print(f"   confirmations {len(c)}, {min(c):.1f} to {max(c):.1f} s, median {st.median(c):.1f} s "
                  "(includes tags that appeared mid-session)")
        print(f"   notifications {totals['notify']}")
        print(f"   beep accepted {totals['beep_ok']} / {totals['beep_sent']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
