#!/usr/bin/env python3
"""Turns calibration.csv into a markdown report.

For each condition and test: measured value per node, the limit, and the
ratio measured/limit. CPU has no absolute unit, so its ratio is taken
against the homogeneous reference: bogo ops per allotted core, divided by
the same quantity in the homogeneous condition (1.0 means the CPU limit
scales exactly as requested). The delay is applied on the egress of the
probe only, so the expected RTT is the configured delay plus the base RTT
measured in "raw".
"""
import csv
import statistics
import sys
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1])))
data = defaultdict(dict)
for r in rows:
    data[(r["condition"], r["test"])][r["node"]] = (
        float(r["measured"]) if r["measured"] else None,
        float(r["limit"]) if r["limit"] else None)

conds = list(dict.fromkeys(r["condition"] for r in rows))
tests = list(dict.fromkeys(r["test"] for r in rows))
nodes = sorted({r["node"] for r in rows})
homog = next((c for c in conds if c.startswith("none")), None)
cpu_ref = None
if homog:
    cpu_ref = statistics.median(m / l for m, l in data[(homog, "cpu")].values())
base_rtt = statistics.median(m for m, _ in data[("raw", "rtt")].values()) if ("raw", "rtt") in data else 0

print("| condition | test | " + " | ".join(nodes) + " | spread |")
print("|---|---|" + "---|" * len(nodes) + "---|")
for c in conds:
    for t in tests:
        cells, vals = [], []
        for n in nodes:
            m, l = data[(c, t)].get(n, (None, None))
            if m is None:
                cells.append("n/a")
                continue
            vals.append(m)
            if l is None:
                cells.append(f"{m:.1f}")
            elif t == "cpu":
                cells.append(f"{m:.0f} ({m / l / cpu_ref:.2f})" if cpu_ref else f"{m:.0f}")
            elif t == "rtt":
                cells.append(f"{m:.2f} ms (limit {l:g} ms)")
            else:
                cells.append(f"{m:.1f} / {l:g} ({m / l:.2f})")
        spread = (max(vals) - min(vals)) / statistics.mean(vals) if vals and statistics.mean(vals) else 0
        print(f"| {c} | {t} | " + " | ".join(cells) + f" | {spread:.1%} |")
print()
print("Cells: measured / limit (ratio). CPU: bogo ops/s (ops per core relative to the homogeneous reference).")
print(f"Spread: (max-min)/mean across nodes. Base RTT without limits: {base_rtt:.2f} ms.")
