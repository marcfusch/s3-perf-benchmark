#!/usr/bin/env python3
"""Per container resource sampler.

Runs in the helper image with --pid=host and the host cgroup tree mounted.
Every interval it appends one row per container with cumulative counters:
CPU time and throttling (cpu.stat), memory (memory.current), disk bytes and
ops on the benchmark disk (io.stat), and bytes sent and received on eth0
(/proc/<pid>/net/dev, read through the container's own netns).

usage: sample.py --out FILE --dev MAJ:MIN [--interval 1] name=pid:cgroup ...
Stops cleanly on SIGTERM.
"""
import argparse
import signal
import sys
import time

FIELDS = ["t", "container", "cpu_usec", "throttled_usec", "nr_throttled",
          "mem_bytes", "io_rbytes", "io_wbytes", "io_rios", "io_wios",
          "net_rx_bytes", "net_tx_bytes"]


def kv_file(path):
    out = {}
    with open(path) as f:
        for line in f:
            k, v = line.split()
            out[k] = int(v)
    return out


def io_stat(path, dev):
    with open(path) as f:
        for line in f:
            parts = line.split()
            if parts and parts[0] == dev:
                return {k: int(v) for k, v in (p.split("=") for p in parts[1:])}
    return {}


def net_dev(pid):
    with open(f"/proc/{pid}/net/dev") as f:
        for line in f:
            if line.strip().startswith("eth0:"):
                cols = line.split(":", 1)[1].split()
                return int(cols[0]), int(cols[8])
    return 0, 0


def sample(name, pid, cg, dev):
    base = f"/sys/fs/cgroup{cg}"
    cpu = kv_file(f"{base}/cpu.stat")
    with open(f"{base}/memory.current") as f:
        mem = int(f.read())
    io = io_stat(f"{base}/io.stat", dev)
    rx, tx = net_dev(pid)
    return [f"{time.time():.3f}", name, cpu.get("usage_usec", 0),
            cpu.get("throttled_usec", 0), cpu.get("nr_throttled", 0), mem,
            io.get("rbytes", 0), io.get("wbytes", 0), io.get("rios", 0),
            io.get("wios", 0), rx, tx]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--dev", required=True)
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("targets", nargs="+")
    a = ap.parse_args()
    targets = []
    for t in a.targets:
        name, rest = t.split("=", 1)
        pid, cg = rest.split(":", 1)
        targets.append((name, pid, cg))

    running = True

    def stop(*_):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    with open(a.out, "w") as out:
        out.write(",".join(FIELDS) + "\n")
        nxt = time.monotonic()
        while running:
            for name, pid, cg in targets:
                try:
                    out.write(",".join(map(str, sample(name, pid, cg, a.dev))) + "\n")
                except OSError:
                    # container gone (killed node): keep sampling the others
                    pass
            out.flush()
            nxt += a.interval
            time.sleep(max(0.0, nxt - time.monotonic()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
