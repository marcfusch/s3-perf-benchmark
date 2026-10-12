#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["matplotlib"]
# ///
"""Figures of the report, from sweep.csv (sweep_report.py) and the kill
campaigns (kill_report.py). One fixed colour and marker per system, the same
in every figure; the colour is never the only encoding (markers, direct
labels, legend).

usage: figures.py <sweep_dir> <kill_dir> <out_dir> [gateway_sweep_dir]
"""
import csv
import glob
import json
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

SYSTEMS = ["garage", "minio", "seaweedfs"]
NAMES = {"garage": "Garage", "minio": "MinIO", "seaweedfs": "SeaweedFS"}
COLOR = {"garage": "#2a78d6", "minio": "#eb6834", "seaweedfs": "#1baf7a"}
MARKER = {"garage": "o", "minio": "s", "seaweedfs": "^"}
HATCH = {"garage": "", "minio": "//", "seaweedfs": ".."}
INK, INK2, GRID, REF = "#0b0b0b", "#52514e", "#e4e3df", "#8a8984"

plt.rcParams.update({
    "font.size": 9, "axes.edgecolor": INK2, "axes.labelcolor": INK, "axes.titlesize": 10,
    "xtick.color": INK2, "ytick.color": INK2, "axes.spines.top": False,
    "axes.spines.right": False, "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6,
    "legend.frameon": False, "savefig.dpi": 200, "figure.facecolor": "white",
})


def load_sweep(d):
    rows = list(csv.DictReader(open(os.path.join(d, "sweep.csv"))))
    for r in rows:
        r["factor"], r["n_degraded"], r["ratio"] = int(r["factor"]), int(r["n_degraded"]), float(r["ratio"])
    return rows


def pick(rows, **kw):
    return [r for r in rows if all(str(r[k]) == str(v) for k, v in kw.items())]


def ratio(rows, sysn, op, res, k, nd, size="1MiB"):
    if res == "none":
        return 1.0
    m = pick(rows, system=sysn, op=op, resource=res, factor=k, n_degraded=nd, size=size)
    return m[0]["ratio"] if m else None


def save(fig, out, name):
    fig.tight_layout()
    fig.savefig(os.path.join(out, name + ".png"))
    fig.savefig(os.path.join(out, name + ".svg"))
    plt.close(fig)


def lines(rows, out, name, xs, getx, xlabel, title, refs):
    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.0), sharey=True)
    for ax, op in zip(axes, ["PUT", "GET"]):
        for label, fn in refs:
            ax.plot(xs, [fn(x) for x in xs], ls="--", lw=1, color=REF, zorder=1)
            ax.annotate(label, (xs[-1], fn(xs[-1])), xytext=(4, 0), textcoords="offset points",
                        color=INK2, fontsize=7, va="center")
        for s in SYSTEMS:
            ys = [getx(s, op, x) for x in xs]
            pts = [(x, y) for x, y in zip(xs, ys) if y is not None]
            if not pts:
                continue
            ax.plot(*zip(*pts), color=COLOR[s], marker=MARKER[s], ms=6, lw=2, label=NAMES[s], zorder=3,
                    markeredgecolor="white", markeredgewidth=1)
        ax.set_title(op, color=INK)
        ax.set_xlabel(xlabel)
        ax.set_xticks(xs)
    axes[0].set_ylabel("throughput / homogeneous")
    axes[0].set_ylim(0, 1.15)
    axes[1].legend(loc="upper right", bbox_to_anchor=(1.0, 0.9))
    fig.suptitle(title, color=INK, fontsize=10)
    save(fig, out, name)


def bars(rows, out, name, cats, getr, xlabel, title):
    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.0), sharey=True)
    w = 0.26
    for ax, op in zip(axes, ["PUT", "GET"]):
        for i, s in enumerate(SYSTEMS):
            ys = [getr(s, op, c) or 0 for c in cats]
            xs = [j + (i - 1) * (w + 0.02) for j in range(len(cats))]
            b = ax.bar(xs, ys, w, color=COLOR[s], hatch=HATCH[s], edgecolor="white", linewidth=0.5,
                       label=NAMES[s], zorder=3)
            for rect, y in zip(b, ys):
                ax.annotate(f"{y:.2f}", (rect.get_x() + rect.get_width() / 2, y), xytext=(0, 2),
                            textcoords="offset points", ha="center", fontsize=6, color=INK2)
        ax.axhline(1, ls="--", lw=1, color=REF, zorder=1)
        ax.set_xticks(range(len(cats)))
        ax.set_xticklabels(cats)
        ax.set_title(op, color=INK)
        ax.set_xlabel(xlabel)
        ax.grid(axis="x", visible=False)
    axes[0].set_ylabel("throughput / homogeneous")
    axes[0].set_ylim(0, 1.2)
    axes[1].legend(loc="upper right", fontsize=7)
    fig.suptitle(title, color=INK, fontsize=10)
    save(fig, out, name)


def sweep_figures(d, out):
    rows = load_sweep(d)
    bars(rows, out, "s1_resource", ["cpu", "disk", "net", "all"],
         lambda s, op, c: ratio(rows, s, op, c, 5, 1), "degraded resource (one node, 5x slower)",
         "S1: which resource hurts")
    lines(rows, out, "s2_factor", [1, 2, 5, 10],
          lambda s, op, k: ratio(rows, s, op, "all" if k > 1 else "none", k, 1 if k > 1 else 0),
          "slowdown factor of one node (all resources)", "S2: gradual loss or cliff",
          [("follows average", lambda k: 1.0), ("follows weakest", lambda k: 1 / k)])
    lines(rows, out, "s3_nodes", [0, 1, 2],
          lambda s, op, n: ratio(rows, s, op, "all" if n else "none", 5 if n else 1, n),
          "degraded nodes out of 3 (all resources, 5x)", "S3: crossing the majority",
          [("follows average", lambda n: 1.0), ("follows weakest", lambda n: 0.2 if n else 1.0)])
    bars(rows, out, "s4_size", ["16KiB", "1MiB", "8MiB"],
         lambda s, op, z: ratio(rows, s, op, "all", 5, 1, z), "object size (one node, all resources 5x)",
         "S4: does object size change the loss")


def kill_figures(d, out):
    camps = []
    for p in sorted(glob.glob(os.path.join(d, "*", "kill_summary.json"))):
        a = json.load(open(p))
        a["dir"] = os.path.dirname(p)
        camps.append(a)
    if not camps:
        return
    scen = lambda a: ("homogeneous" if a["resource"] == "none" else
                      ("weak node killed" if a["victim"] <= a["n_degraded"] else "healthy node killed"))
    scenarios = ["homogeneous", "weak node killed", "healthy node killed"]

    # one timeline per system and scenario (first repetition)
    fig, axes = plt.subplots(3, 3, figsize=(7.4, 6.0), sharex=False)
    for i, s in enumerate(SYSTEMS):
        for j, sc in enumerate(scenarios):
            ax = axes[i][j]
            c = next((a for a in camps if a["system"] == s and scen(a) == sc), None)
            if not c:
                ax.set_visible(False)
                continue
            ev = json.load(open(os.path.join(c["dir"], "events.json")))
            t0 = ev["t_load_start"]
            tl = list(csv.DictReader(open(os.path.join(c["dir"], "timeline.csv"))))
            ax.plot([float(r["t"]) for r in tl], [float(r["mib_s"]) for r in tl], color=COLOR[s], lw=1)
            ax.axvspan(ev["t_kill"] - t0, ev["t_replace"] - t0, color="#f0efec", zorder=0)
            ax.axvline(ev["t_check_degraded_start"] - t0, color=INK2, lw=0.8, ls=":", zorder=1)
            if ev.get("t_rebuilt"):
                ax.axvspan(ev["t_replace"] - t0, ev["t_rebuilt"] - t0, color="#cde2fb", zorder=0)
            ax.set_ylim(bottom=0)
            if i == 0:
                ax.set_title(sc, color=INK)
            if j == 0:
                ax.set_ylabel(f"{NAMES[s]}\nGET MiB/s")
            if i == 2:
                ax.set_xlabel("time (s)")
    from matplotlib.lines import Line2D
    from matplotlib.patches import Patch
    handles = [Patch(color="#f0efec", label="node dead"),
               Line2D([0], [0], color=INK2, lw=0.8, ls=":", label="every object read back"),
               Patch(color="#cde2fb", label="rebuild")]
    fig.legend(handles=handles, loc="lower center", ncol=3, fontsize=8)
    fig.suptitle("Client GET throughput around a node kill", color=INK, fontsize=10)
    fig.tight_layout(rect=(0, 0.04, 1, 1))
    fig.savefig(os.path.join(out, "kill_timelines.png"))
    fig.savefig(os.path.join(out, "kill_timelines.svg"))
    plt.close(fig)

    # rebuild duration and client throughput during the rebuild
    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.0))
    w = 0.26
    for i, s in enumerate(SYSTEMS):
        for ax, key in zip(axes, ["rebuild_s", "rebuild_ratio"]):
            ys = []
            for sc in scenarios:
                v = [a["rebuild_s"] if key == "rebuild_s" else (a["phases"]["rebuild"] or {}).get("ratio")
                     for a in camps if a["system"] == s and scen(a) == sc]
                v = sorted(x for x in v if x is not None)
                ys.append(v[len(v) // 2] if v else 0)
            xs = [j + (i - 1) * (w + 0.02) for j in range(len(scenarios))]
            ax.bar(xs, ys, w, color=COLOR[s], hatch=HATCH[s], edgecolor="white", linewidth=0.5,
                   label=NAMES[s], zorder=3)
    for ax, lab in zip(axes, ["rebuild duration (s)", "GET throughput during rebuild / before"]):
        ax.set_xticks(range(len(scenarios)))
        ax.set_xticklabels([sc.replace(" killed", "\nkilled") for sc in scenarios], fontsize=8)
        ax.set_ylabel(lab)
        ax.grid(axis="x", visible=False)
    axes[1].axhline(1, ls="--", lw=1, color=REF, zorder=1)
    axes[0].legend(fontsize=7)
    fig.suptitle("Rebuild after a node kill", color=INK, fontsize=10)
    save(fig, out, "rebuild")


def gateway_figure(sweep_dir, gw_dir, out):
    """Ratio with the client on all three nodes (the weak one included as a
    gateway) against the client on the two healthy nodes only."""
    allr, gw = load_sweep(sweep_dir), load_sweep(gw_dir)
    xs = [1, 2, 5, 10]
    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.0), sharey=True)
    for ax, op in zip(axes, ["PUT", "GET"]):
        ax.plot(xs, [1 / k for k in xs], ls="--", lw=1, color=REF, zorder=1)
        ax.plot(xs, [1.0] * len(xs), ls="--", lw=1, color=REF, zorder=1)
        ax.annotate("follows weakest", (xs[-1], 0.1), xytext=(4, 0), textcoords="offset points",
                    color=INK2, fontsize=7, va="center")
        ax.annotate("follows average", (xs[-1], 1.0), xytext=(4, 0), textcoords="offset points",
                    color=INK2, fontsize=7, va="center")
        for s in SYSTEMS:
            for rows, ls, lab in ((allr, ":", "via weak node too"), (gw, "-", "healthy gateways")):
                ys = [ratio(rows, s, op, "all" if k > 1 else "none", k, 1 if k > 1 else 0) for k in xs]
                pts = [(x, y) for x, y in zip(xs, ys) if y is not None]
                if pts:
                    ax.plot(*zip(*pts), color=COLOR[s], marker=MARKER[s], ms=5, lw=2 if ls == "-" else 1.2,
                            ls=ls, markeredgecolor="white", markeredgewidth=1,
                            label=f"{NAMES[s]}, {lab}", zorder=3)
        ax.set_title(op, color=INK)
        ax.set_xticks(xs)
        ax.set_xlabel("slowdown factor of one node (all resources)")
    axes[0].set_ylabel("throughput / homogeneous")
    axes[0].set_ylim(0, 1.4)
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="lower center", ncol=3, fontsize=7)
    fig.suptitle("Gateway effect: solid, the client avoids the weak node; dotted, it uses it",
                 color=INK, fontsize=10)
    fig.tight_layout(rect=(0, 0.12, 1, 1))
    fig.savefig(os.path.join(out, "gateway.png"))
    fig.savefig(os.path.join(out, "gateway.svg"))
    plt.close(fig)


if __name__ == "__main__":
    sweep_dir, kill_dir, out = sys.argv[1:4]
    os.makedirs(out, exist_ok=True)
    if os.path.exists(os.path.join(sweep_dir, "sweep.csv")):
        sweep_figures(sweep_dir, out)
    kill_figures(kill_dir, out)
    if len(sys.argv) > 4 and os.path.exists(os.path.join(sys.argv[4], "sweep.csv")):
        gateway_figure(sweep_dir, sys.argv[4], out)
