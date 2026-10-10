#!/usr/bin/env python3
"""Report for validate_loadgen.sh: uniqueness, warp vs s3load, client
headroom and byte accounting, one line per system and op."""
import json
import os
import sys

d = sys.argv[1]
systems = sorted({f.split("-")[0] for f in os.listdir(d) if f.endswith("-uniqueness.json")})

print("## Data uniqueness (warp PUT objects)\n")
print("| system | objects distinct/read | 1 MiB blocks distinct/read |")
print("|---|---|---|")
for s in systems:
    u = json.load(open(os.path.join(d, f"{s}-uniqueness.json")))
    print(f"| {s} | {u['object']['distinct']}/{u['object']['total']} | "
          f"{u['block_1MiB']['distinct']}/{u['block_1MiB']['total']} |")

print("\n## warp vs independent client (s3load, boto3)\n")
print("| system | op | warp MiB/s | s3load MiB/s | ratio | warp p50 ms | s3load p50 ms | warp client cores / limit | throttled | warp bytes vs client NIC |")
print("|---|---|---|---|---|---|---|---|---|---|")
for s in systems:
    for op in ("put", "get"):
        sm = json.load(open(os.path.join(d, f"{s}-warp-{op}", "summary.json")))
        c = sm["client"][op.upper()]
        cl = sm["server"].get("warp-client", {})
        lo = json.load(open(os.path.join(d, f"{s}-s3load-{op}.json")))
        nic = cl.get("net_tx_mib_s" if op == "put" else "net_rx_mib_s", 0)
        print(f"| {s} | {op} | {c['mib_s']:.1f} | {lo['throughput_mib_s']:.1f} | "
              f"{lo['throughput_mib_s'] / c['mib_s']:.2f} | {c['lat_ms']['p50']:.1f} | "
              f"{lo['lat_ms']['p50']:.1f} | {cl.get('cores', 0):.2f} / {sm['meta']['client_cpus']} | "
              f"{cl.get('throttled_ratio', 0):.2f} | {nic / c['mib_s']:.2f} |")
print("\nratio = s3load / warp. Last column: client NIC rate / warp payload rate (about 1.0 plus protocol overhead expected).")
