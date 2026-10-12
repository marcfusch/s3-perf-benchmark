#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["zstandard"]
# ///
"""Report of the node kill campaigns (kill_campaign.sh).

For each campaign, the client requests (every warp slice) are binned per
second, only inside the time each slice was actually running, and split in
phases from events.json:
  before    load start + 5 s .. kill
  degraded  kill .. degraded check (node dead, nothing replaced yet)
  rebuild   replacement done .. rebuild detected
  after     rebuild detected .. load end
Per phase: median and mean per second throughput, the longest stall (run of
seconds without a single answer), p50/p99 latency, errors, and the
throughput ratios to "before". Also: rebuild duration (replacement to
detection), rebuild rate (bytes on the new node / duration), and the two
data checks (degraded, final).

usage: kill_report.py <campaigns_dir>   writes kill.csv, timeline.csv per
campaign, and prints markdown
"""
import csv
import glob
import io
import json
import os
import statistics
import sys
from collections import defaultdict
from datetime import datetime

import zstandard


def ts(s):
    s = s.rstrip("Z")
    if "." in s:
        a, b = s.split(".")
        s = f"{a}.{b[:6]:0<6}"
    return datetime.fromisoformat(s + "+00:00").timestamp()


def pct(v, p):
    if not v:
        return None
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))]


def requests(run):
    reqs, windows = [], []
    for f in sorted(glob.glob(os.path.join(run, "chunks", "*.csv.zst"))):
        with open(f, "rb") as fh:
            text = io.TextIOWrapper(zstandard.ZstdDecompressor().stream_reader(fh))
            rows = [r for r in csv.DictReader(text, delimiter="\t")
                    if r.get("start") and r.get("end") and r["op"] == "GET"]
        if not rows:
            continue
        chunk = [(ts(r["start"]), ts(r["end"]), int(r["bytes"]), int(r["duration_ns"]) / 1e6,
                  bool(r["error"])) for r in rows]
        windows.append((min(c[0] for c in chunk), max(c[1] for c in chunk)))
        reqs += chunk
    return reqs, windows


def analyse(run):
    ev = json.load(open(os.path.join(run, "events.json")))
    reqs, windows = requests(run)
    # per second bins, kept only when fully covered by a running slice
    bins = defaultdict(lambda: [0, 0])
    for s, e, b, lat, err in reqs:
        sec = int(e)
        if err:
            bins[sec][1] += 1
        else:
            bins[sec][0] += b
    covered = lambda sec: any(w0 <= sec and sec + 1 <= w1 for w0, w1 in windows)
    # every second during which a slice was running counts, including the
    # seconds where no request finished at all (a stalled cluster is 0 MiB/s)
    secs = sorted({sec for w0, w1 in windows for sec in range(int(w0), int(w1) + 1) if covered(sec)})
    timeline = [(sec, bins[sec][0] / 2**20, bins[sec][1]) if sec in bins else (sec, 0.0, 0) for sec in secs]
    with open(os.path.join(run, "timeline.csv"), "w") as f:
        f.write("t,mib_s,errors\n")
        for sec, m, e in timeline:
            f.write(f"{sec - ev['t_load_start']:.0f},{m:.2f},{e}\n")

    end = ev["t_load_end"]
    rebuilt = ev.get("t_rebuilt")
    phases = {"before": (ev["t_load_start"] + 5, ev["t_kill"]),
              "degraded": (ev["t_kill"], ev["t_check_degraded_start"]),
              "rebuild": (ev["t_replace_done"], rebuilt or end),
              "after": (rebuilt, end) if rebuilt else None}
    out = {}
    for name, w in phases.items():
        if not w:
            out[name] = None
            continue
        thr = [m for sec, m, e in timeline if w[0] <= sec and sec + 1 <= w[1]]
        # longest run of consecutive seconds without a single answer
        stall = streak = 0
        for m in thr:
            streak = streak + 1 if m == 0 else 0
            stall = max(stall, streak)
        lat = [lat for s, e, b, lat, err in reqs if w[0] <= s < w[1] and not err]
        errs = sum(1 for s, e, b, lat, err in reqs if w[0] <= s < w[1] and err)
        out[name] = {"seconds": round(w[1] - w[0]), "mib_s": statistics.median(thr) if thr else None,
                     "mean_mib_s": statistics.fmean(thr) if thr else None, "stall_s": stall,
                     "p50_ms": pct(lat, 50), "p99_ms": pct(lat, 99), "errors": errs}
    base = out["before"]["mib_s"]
    base_mean = out["before"]["mean_mib_s"]
    for name, v in out.items():
        if v and v["mib_s"] is not None and base:
            v["ratio"] = v["mib_s"] / base
        if v and v["mean_mib_s"] is not None and base_mean:
            v["mean_ratio"] = v["mean_mib_s"] / base_mean

    # longest stall over the whole time the node is dead (kill to replacement)
    stall_dead = streak = 0
    prev = None
    for sec, m, e in timeline:
        if not (ev["t_kill"] <= sec < ev["t_replace"]):
            continue
        streak = streak + 1 if m == 0 and (prev is None or sec == prev + 1 or streak == 0) else (1 if m == 0 else 0)
        stall_dead = max(stall_dead, streak)
        prev = sec

    victim = ev["victim"]
    reb = list(csv.DictReader(open(os.path.join(run, "rebuild.csv"))))
    new_bytes = int(reb[-1][f"node{victim}"]) if reb else 0
    # time until the new node holds 90 % of the bytes of the median survivor:
    # with Garage most blocks can come back long before the last ones
    t90 = None
    for x in reb:
        others = sorted(int(x[f"node{i}"]) for i in (1, 2, 3) if i != victim)
        if others and int(x[f"node{victim}"]) >= 0.9 * others[len(others) // 2]:
            t90 = float(x["t"]) - ev["t_replace"]
            break
    duration = rebuilt - ev["t_replace"] if rebuilt else None
    return {"run": os.path.basename(run), "system": ev["system"], "resource": ev["resource"],
            "factor": ev["factor"], "n_degraded": ev["n_degraded"], "victim": victim,
            "leader": ev.get("seaweedfs_master_leader", ""),
            "rebuild_s": duration, "rebuild_mib_s": new_bytes / 2**20 / duration if duration else None,
            "stall_while_dead_s": stall_dead, "rebuild90_s": t90,
            "check_degraded": ev["check_degraded"], "check_final": ev["check_final"], "phases": out}


def main():
    res = []
    for run in sorted(glob.glob(os.path.join(sys.argv[1], "*"))):
        if os.path.exists(os.path.join(run, "events.json")):
            a = analyse(run)
            json.dump(a, open(os.path.join(run, "kill_summary.json"), "w"), indent=1)
            res.append(a)
    rows = []
    for a in res:
        p = a["phases"]
        f = lambda ph, k: (p[ph] or {}).get(k)
        cd, cf = a["check_degraded"] or {}, a["check_final"] or {}
        rows.append({
            "run": a["run"], "system": a["system"],
            "condition": "homogeneous" if a["resource"] == "none" else f"{a['resource']} {a['factor']}x, {a['n_degraded']} node",
            "victim": f"node{a['victim']}" + (" (weak)" if a["victim"] <= a["n_degraded"] else ""),
            "before_mib_s": round(f("before", "mib_s") or 0, 1),
            "degraded_ratio": round(f("degraded", "ratio") or 0, 2),
            "degraded_mean_ratio": round(f("degraded", "mean_ratio") or 0, 2),
            "stall_after_kill_s": a["stall_while_dead_s"],
            "rebuild_ratio": round(f("rebuild", "ratio") or 0, 2),
            "after_ratio": round(f("after", "ratio") or 0, 2),
            "rebuild_p99_ms": round(f("rebuild", "p99_ms") or 0, 1),
            "before_p99_ms": round(f("before", "p99_ms") or 0, 1),
            "errors": sum((p[ph] or {}).get("errors", 0) for ph in p),
            "rebuild90_s": None if a["rebuild90_s"] is None else round(a["rebuild90_s"]),
            "rebuild_s": None if a["rebuild_s"] is None else round(a["rebuild_s"]),
            "rebuild_mib_s": None if a["rebuild_mib_s"] is None else round(a["rebuild_mib_s"], 1),
            "readable_degraded": f"{cd.get('ok', '?')}/{cd.get('objects', '?')}",
            "readable_final": f"{cf.get('ok', '?')}/{cf.get('objects', '?')}",
        })
    with open(os.path.join(sys.argv[1], "kill.csv"), "w") as f:
        w = csv.DictWriter(f, rows[0].keys())
        w.writeheader()
        w.writerows(rows)
    cols = list(rows[0].keys())
    print("| " + " | ".join(cols) + " |")
    print("|" + "---|" * len(cols))
    for r in rows:
        print("| " + " | ".join("" if r[c] is None else str(r[c]) for c in cols) + " |")


if __name__ == "__main__":
    main()
