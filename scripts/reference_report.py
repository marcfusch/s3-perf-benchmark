#!/usr/bin/env python3
"""Report on the homogeneous reference runs (reference.sh).

Per system and op: median throughput and latency over the repetitions, the
coefficient of variation (CV) of the throughput between runs, the number of
repetitions needed to detect a 10 % change, and two homogeneity checks:
the spread of the number of requests served by each endpoint and the spread of the
CPU used by the nodes, both as (max-min)/mean, medians over runs.
"""
import glob
import json
import math
import os
import statistics
import sys
from collections import defaultdict

runs = defaultdict(list)
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*", "summary.json"))):
    s = json.load(open(p))
    for op, c in s["client"].items():
        runs[(s["meta"]["system"], s["meta"]["op"], op)].append((s, c))


def spread(vals):
    m = statistics.mean(vals)
    return (max(vals) - min(vals)) / m if m else 0


print("| system | workload | op | runs | median (MiB/s, or ops/s for STAT and DELETE) | CV | p50 ms | p99 ms | reps for 10% | endpoint spread | node CPU spread | errors |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
for (sysn, wl, op), lst in sorted(runs.items()):
    # STAT and DELETE move no payload, their throughput is in ops/s
    key = "mib_s" if any(c["mib_s"] for _, c in lst) else "ops_s"
    thr = [c[key] for _, c in lst]
    cv = statistics.stdev(thr) / statistics.mean(thr) if len(thr) > 1 else float("nan")
    # two sided, alpha 0.05, power 0.8, two groups: n = 2 (1.96 + 0.84)^2 cv^2 / d^2
    reps = math.ceil(2 * (1.96 + 0.84) ** 2 * cv ** 2 / 0.10 ** 2) if not math.isnan(cv) else "n/a"
    ep = statistics.median(spread([v["lat_ms"]["n"] for v in c["by_node"].values()]) for _, c in lst)
    cpu = statistics.median(s["cpu_imbalance"] or 0 for s, _ in lst)
    print(f"| {sysn} | {wl} | {op} | {len(lst)} | {statistics.median(thr):.1f} | {cv:.1%} | "
          f"{statistics.median(c['lat_ms']['p50'] for _, c in lst):.1f} | "
          f"{statistics.median(c['lat_ms']['p99'] for _, c in lst):.1f} | {reps} | {ep:.1%} | {cpu:.1%} | "
          f"{sum(c['errors'] for _, c in lst)} |")
