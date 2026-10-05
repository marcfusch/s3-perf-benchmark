#!/usr/bin/env python3
"""Summarizes runs produced by run_warp.sh.

For every run directory given, reads warp.csv.zst (one line per request) and
resources.csv (sampler) and writes summary.json next to them:
  * client side, per op: throughput, ops/s, errors, latency p50/p90/p99,
    overall and per endpoint (node);
  * server side, per node: mean cores used, CPU throttling ratio, peak memory,
    disk and network rates over the measured window;
  * network amplification: bytes sent by the nodes per useful byte moved
    by the client.
The first --skip seconds are dropped (warm up). With --csv, also prints one
flat line per run and op, ready to be appended to a table.

usage: summarize.py [--skip 3] [--csv] run_dir...
"""
import argparse
import csv
import io
import json
import os
import sys
from collections import defaultdict
from datetime import datetime

import zstandard


def ts(s):
    # warp writes RFC3339 with nanoseconds, python keeps microseconds
    s = s.rstrip("Z")
    if "." in s:
        a, b = s.split(".")
        s = f"{a}.{b[:6]:0<6}"
    return datetime.fromisoformat(s).timestamp()


def pct(v, p):
    if not v:
        return None
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))]


def lat_stats(lat_ms):
    return {"p50": pct(lat_ms, 50), "p90": pct(lat_ms, 90), "p99": pct(lat_ms, 99),
            "n": len(lat_ms)}


def read_requests(path):
    with open(path, "rb") as f:
        text = io.TextIOWrapper(zstandard.ZstdDecompressor().stream_reader(f))
        for row in csv.DictReader(text, delimiter="\t"):
            # skip trailing metadata lines that are not requests
            if row.get("start") and row.get("end"):
                yield row


def client_side(run_dir, skip, bench_op):
    rows = list(read_requests(os.path.join(run_dir, "warp.csv.zst")))
    # warp records the uploads it does to prepare a GET or MIXED benchmark:
    # the measured phase starts with the first request that is not a PUT
    if bench_op != "put":
        others = [ts(r["start"]) for r in rows if r["op"] != "PUT"]
        if others:
            t_bench = min(others)
            rows = [r for r in rows if ts(r["start"]) >= t_bench]
    if not rows:
        return {}, None
    t0 = min(ts(r["start"]) for r in rows) + skip
    t1 = max(ts(r["end"]) for r in rows)
    win = (t0, t1)
    per_op = defaultdict(lambda: {"lat": [], "bytes": 0, "errors": 0,
                                  "host": defaultdict(lambda: {"lat": [], "bytes": 0, "errors": 0})})
    for r in rows:
        if ts(r["start"]) < t0:
            continue
        host = r["endpoint"].split("//")[-1].split(":")[0]
        for d in (per_op[r["op"]], per_op[r["op"]]["host"][host]):
            if r["error"]:
                d["errors"] += 1
            else:
                d["lat"].append(int(r["duration_ns"]) / 1e6)
                d["bytes"] += int(r["bytes"])
    dur = t1 - t0
    out = {}
    for op, d in per_op.items():
        out[op] = {
            "window_s": dur,
            "mib_s": d["bytes"] / dur / 2**20, "ops_s": len(d["lat"]) / dur,
            "errors": d["errors"], "lat_ms": lat_stats(d["lat"]),
            "bytes": d["bytes"],
            "by_node": {h: {"mib_s": x["bytes"] / dur / 2**20, "errors": x["errors"],
                            "lat_ms": lat_stats(x["lat"])} for h, x in sorted(d["host"].items())},
        }
    return out, win


def server_side(run_dir, win):
    path = os.path.join(run_dir, "resources.csv")
    if not os.path.exists(path) or win is None:
        return {}
    series = defaultdict(list)
    with open(path) as f:
        for r in csv.DictReader(f):
            t = float(r["t"])
            if win[0] <= t <= win[1]:
                series[r["container"]].append({k: float(v) for k, v in r.items() if k != "container"})
    out = {}
    for c, s in series.items():
        if len(s) < 2:
            continue
        a, b = s[0], s[-1]
        dt = b["t"] - a["t"]
        rate = lambda k: (b[k] - a[k]) / dt
        out[c] = {
            "cores": rate("cpu_usec") / 1e6,
            "throttled_ratio": rate("throttled_usec") / 1e6,
            "mem_peak_mib": max(x["mem_bytes"] for x in s) / 2**20,
            "disk_read_mib_s": rate("io_rbytes") / 2**20,
            "disk_write_mib_s": rate("io_wbytes") / 2**20,
            "net_rx_mib_s": rate("net_rx_bytes") / 2**20,
            "net_tx_mib_s": rate("net_tx_bytes") / 2**20,
            "net_tx_bytes": b["net_tx_bytes"] - a["net_tx_bytes"],
        }
    return out


def summarize(run_dir, skip):
    meta = json.load(open(os.path.join(run_dir, "meta.json")))
    limits_p = os.path.join(run_dir, "limits.json")
    limits = json.load(open(limits_p)) if os.path.exists(limits_p) else None
    client, win = client_side(run_dir, skip, meta["op"])
    server = server_side(run_dir, win)
    nodes = {c: v for c, v in server.items() if "-node" in c}
    useful = sum(v["bytes"] for v in client.values())
    node_tx = sum(v["net_tx_bytes"] for v in nodes.values())
    cores = [v["cores"] for v in nodes.values()]
    s = {
        "run": os.path.basename(os.path.normpath(run_dir)), "meta": meta, "limits": limits,
        "skip_s": skip, "client": client, "server": server,
        "net_bytes_per_useful_byte": node_tx / useful if useful else None,
        "cpu_imbalance": (max(cores) - min(cores)) / (sum(cores) / len(cores)) if cores and sum(cores) else None,
    }
    with open(os.path.join(run_dir, "summary.json"), "w") as f:
        json.dump(s, f, indent=1)
    return s


CSV_COLS = ["run", "system", "resource", "factor", "n_degraded", "op", "mib_s", "ops_s",
            "errors", "p50_ms", "p90_ms", "p99_ms", "net_amp", "cpu_imbalance",
            "client_cores", "client_throttled"]


def flat(s):
    lim = s["limits"] or {}
    cl = s["server"].get("warp-client", {})
    for op, c in s["client"].items():
        yield {"run": s["run"], "system": s["meta"]["system"], "resource": lim.get("resource"),
               "factor": lim.get("factor"), "n_degraded": lim.get("n_degraded"), "op": op,
               "mib_s": round(c["mib_s"], 2), "ops_s": round(c["ops_s"], 2), "errors": c["errors"],
               "p50_ms": round(c["lat_ms"]["p50"] or 0, 1), "p90_ms": round(c["lat_ms"]["p90"] or 0, 1),
               "p99_ms": round(c["lat_ms"]["p99"] or 0, 1),
               "net_amp": round(s["net_bytes_per_useful_byte"] or 0, 2),
               "cpu_imbalance": round(s["cpu_imbalance"] or 0, 3),
               "client_cores": round(cl.get("cores", 0), 2),
               "client_throttled": round(cl.get("throttled_ratio", 0), 3)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip", type=float, default=3.0)
    ap.add_argument("--csv", action="store_true")
    ap.add_argument("runs", nargs="+")
    a = ap.parse_args()
    w = csv.DictWriter(sys.stdout, CSV_COLS) if a.csv else None
    if w:
        w.writeheader()
    for r in a.runs:
        s = summarize(r, a.skip)
        if w:
            for line in flat(s):
                w.writerow(line)
        else:
            print(f"{r}: summary.json written")


if __name__ == "__main__":
    main()
