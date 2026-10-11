# Bench: distributed object storage on bad hardware (MGL870)

Test bench for the proposal: three S3 systems (Garage, MinIO, SeaweedFS),
each deployed as a 3 node cluster in containers on a single host, with
explicit and scripted limits on CPU, disk and network per node. Each system
is only ever compared to its own homogeneous reference.

## Layout

```
env/budget.env        nominal resources of one node (the cluster budget is 3x)
env/creds.env         S3 credentials shared by the three systems
images/minio          MinIO built from source (no official image anymore)
images/tools          helper image: tc, fio, stress-ng, iperf3, python + boto3
systems/<sys>/        compose file + init script of each cluster
scripts/              everything else (see below)
results/              raw data, one directory per run (not versioned)
```

## Requirements

A Linux docker host with cgroup v2 (io and cpu controllers). On macOS:
`brew install colima docker docker-compose` then
`colima start --cpu 6 --memory 6 --disk 15 --vm-type vz`.
Then `scripts/build.sh` once.

## Scripts

| script | role |
|---|---|
| `up.sh <sys>` / `down.sh <sys>` | fresh cluster (empty volumes), formed, homogeneous limits |
| `limits.sh <sys> <resource> <factor> <n_degraded>` | applies a condition (sweeps S1, S2, S3), prints it as JSON |
| `run_warp.sh <sys> <dir> <op> [warp flags]` | one warp run + resource sampling of every node and of the client |
| `summarize.sh [--csv] <dirs>` | summary.json per run: throughput, latency percentiles per node, CPU, memory, disk, network, network bytes per useful byte |
| `pilot.sh` | first pilot: whole chain on the 3 systems, homogeneous and one degraded condition |
| `calibrate_limits.sh` | checks the limits with fio, stress-ng, iperf3 and ping on probe containers |
| `reference.sh` | homogeneous reference, repeated, random order: noise and homogeneity |
| `validate_loadgen.sh` | data uniqueness, cross check with a second client, client headroom |

Status and results of the first two phases: [PHASE1-2.md](PHASE1-2.md).

## How a condition is built

`limits.sh` keeps the cluster budget constant: a degraded node gets
`nominal / factor`, and what it loses is split equally between the healthy
nodes. Degraded nodes are node1, then node2. Mechanisms:

* CPU: `docker update --cpus` (cgroup `cpu.max`), memory fixed at `MEM_PER_NODE`;
* disk: cgroup v2 `io.max` (read/write bytes and IOPS) on the disk holding the volumes;
* link: `tc netem` (rate + delay) on the egress of the node, ingress policed at the same rate.
  The delay is not a budget: a degraded node gets `factor x` the nominal delay.

The client (warp) runs in its own container with `CLIENT_CPUS`, outside the
cluster budget, and spreads requests round robin over the three nodes
(`--host-select roundrobin`), so the client never routes around a slow node.

## Choices worth knowing

* warp is pinned to **v1.0.8**. Versions v1.1.0 to v1.3.1 send nearly identical
  objects (1 to 7 distinct objects out of 60), which Garage deduplicates per
  1 MiB block: with v1.3.1 Garage PUT looked 2x faster than it is.
  `scripts/uniqueness.py` checks it, `validate_loadgen.sh` runs it on every system.
* MinIO is built from the last upstream tag (`RELEASE.2025-10-15T17-29-55Z`), the
  repository is archived and the images are no longer published.
* Redundancy: Garage `replication_factor = 3`, SeaweedFS replication `002`
  (3 copies), MinIO erasure coding over 3 drives (EC 2+1, default parity).
  Defaults otherwise, not tuned.
* SeaweedFS: every node runs master (raft), volume, filer and S3 gateway; the master
  leader is elected and recorded in `meta.json` of each run.
