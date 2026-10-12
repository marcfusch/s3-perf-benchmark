#!/usr/bin/env python3
"""Report of the sweeps (sweep.sh), from the summary.json of every run.

For each system, op, condition and object size: median throughput over the
repetitions, and the degradation ratio r = median(condition) /
median(homogeneous, same system, op and size). Each system is only ever
compared to itself.

Q3 index W = (1 - r) / (1 - 1/k). The cluster budget is constant across
conditions, so a cluster that follows the AVERAGE of its nodes keeps r = 1
(W = 0), and a cluster paced by its WEAKEST node (k times slower) drops to
r = 1/k (W = 1). W > 1 means worse than the weakest node alone would explain.

usage: sweep_report.py <sweep_dir>   writes sweep.csv and prints markdown
"""
import csv
import glob
import json
import os
import statistics
import sys
from collections import defaultdict

d = sys.argv[1]
groups = defaultdict(list)
for p in glob.glob(os.path.join(d, "*", "summary.json")):
    s = json.load(open(p))
    if not s.get("client") or s["meta"].get("warp_rc") != 0:
        continue
    lim = s["limits"]
    size = os.path.basename(os.path.dirname(p)).split("-")[3]
    op = s["meta"]["op"].upper()
    c = s["client"][op]
    key = (s["meta"]["system"], op, lim["resource"], lim["factor"], lim["n_degraded"], size)
    groups[key].append({"mib_s": c["mib_s"], "ops_s": c["ops_s"], "p50": c["lat_ms"]["p50"],
                        "p99": c["lat_ms"]["p99"], "errors": c["errors"],
                        "imbalance": s["cpu_imbalance"] or 0})

med = lambda l, k: statistics.median(x[k] for x in l)
rows = []
for key, runs in groups.items():
    sysn, op, res, k, nd, size = key
    base = groups.get((sysn, op, "none", 1, 0, size))
    if not base:
        continue
    r = med(runs, "ops_s") / med(base, "ops_s")
    w = (1 - r) / (1 - 1 / k) if k > 1 else None
    spread = (max(x["ops_s"] for x in runs) - min(x["ops_s"] for x in runs)) / med(runs, "ops_s")
    rows.append({"system": sysn, "op": op, "resource": res, "factor": k, "n_degraded": nd,
                 "size": size, "runs": len(runs), "mib_s": round(med(runs, "mib_s"), 2),
                 "ops_s": round(med(runs, "ops_s"), 2), "ratio": round(r, 3),
                 "W": None if w is None else round(w, 2),
                 "p50_ms": round(med(runs, "p50"), 1), "p99_ms": round(med(runs, "p99"), 1),
                 "p99_ratio": round(med(runs, "p99") / med(base, "p99"), 2),
                 "rep_spread": round(spread, 3), "errors": sum(x["errors"] for x in runs)})

order = {"none": 0, "cpu": 1, "disk": 2, "net": 3, "all": 4, "hdd": 5, "fs": 6}
sizes = {"16KiB": 0, "1MiB": 1, "8MiB": 2}
rows.sort(key=lambda x: (x["system"], x["op"], sizes.get(x["size"], 9), order[x["resource"]],
                         x["factor"], x["n_degraded"]))
with open(os.path.join(d, "sweep.csv"), "w") as f:
    w = csv.DictWriter(f, rows[0].keys())
    w.writeheader()
    w.writerows(rows)

cols = ["system", "op", "size", "resource", "factor", "n_degraded", "runs", "mib_s", "ops_s",
        "ratio", "W", "p99_ms", "p99_ratio", "rep_spread", "errors"]
print("| " + " | ".join(cols) + " |")
print("|" + "---|" * len(cols))
for r in rows:
    print("| " + " | ".join("" if r[c] is None else str(r[c]) for c in cols) + " |")
