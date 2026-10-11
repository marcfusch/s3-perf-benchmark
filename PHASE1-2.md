# Phases 1 and 2 (Sep. 29 to Oct. 26): status

Raw data in `results/` (pilot-1, calib-1, loadgen-2, reference-1, reference-sw90).

## Phase 1: deploy, scripted limits, first pilot

Done. The three clusters start from scratch with `up.sh`, the limits are applied
with `limits.sh`, one run is `run_warp.sh`, the pilot is `pilot.sh`.

Pilot (`results/pilot-1/pilot.csv`, 30 s runs, 1 MiB objects, concurrency 8). It
was run with the first disk budget (80 MiB/s read), lowered since, so it only
validates the chain. It already shows the expected signal on GET with one node
at CPU/5:

| system | GET homogeneous | GET cpu 5x, 1 node |
|---|---|---|
| Garage | 207 MiB/s | 13 MiB/s |
| MinIO | 115 MiB/s | 9 MiB/s |
| SeaweedFS | 112 MiB/s | 78 MiB/s |

Problems found and fixed during deployment:

* MinIO images are no longer published: built from the source tag.
* SeaweedFS filers crash when they start before their peers: restart policy and a stricter readiness check.
* Garage: a bucket created by warp on a brand new cluster is not visible to the first uploads: the init script creates it.
* warp records the uploads of its preparation phase: the analysis now starts at the first request of the measured phase.

## Phase 2: instrumentation

`sample.py` reads every second, per container, the cgroup counters (CPU used,
CPU throttling, memory, disk bytes and IOs on the benchmark disk) and the eth0
counters of the container. `summarize.py` produces per run: throughput and
latency p50/p90/p99 per op and per node, mean cores per node, CPU imbalance
between nodes, network bytes sent by the nodes per useful byte.

## Phase 2: calibration of the limits (`results/calib-1/calibration.md`)

Three probe containers get the exact same treatment as the nodes.

* Disk (io.max): within 5 % of the limit in every condition, including the extreme point (10x, 2 nodes).
* Network (netem + policing): 92 to 96 % of the rate; 86 % on ingress at 2.8 Gbit/s.
* RTT: about 1.3 to 1.4 x the configured delay (1 ms gives 1.44 ms, 10 ms gives 13.4 ms). Ratios between nodes are preserved.
* CPU: within 5 % at 1 and 1.4 cores, 0.85 of the target at 0.2 core (CFS quantisation at small quotas).
* Homogeneous condition: spread between the three probes at most 4 %.

The first raw measurement showed that the VM disk could not deliver the first
nominal budget (about 55 MiB/s read per probe with 3 probes in parallel, below
the 80 MiB/s nominal). The budget was lowered to 25 MiB/s read, 40 MiB/s write,
800 / 600 IOPS per node, so the limits and not the host set the pace.

## Phase 2: validation of the load generator (`results/loadgen-2/loadgen.md`)

* **warp v1.1.0 to v1.3.1 send nearly identical objects** (v1.3.1: 1 to 5 distinct objects out of 60).
  Garage deduplicates by 1 MiB block, so its PUT looked 2x faster (48.5 vs 24.1 MiB/s).
  warp is pinned to v1.0.8: 100/100 distinct objects on the three systems.
* The client is never the bottleneck: at most 0.25 core used out of 2, never throttled.
* Byte accounting: client NIC traffic / warp payload = 1.00 to 1.02.
* Second client (boto3), same request shape (signed payload, no CRC), same working set:

| system | PUT s3load/warp | GET s3load/warp |
|---|---|---|
| Garage | 0.93 | 0.98 |
| MinIO | 1.00 | 0.91 |
| SeaweedFS | 1.47 | 0.70 |

  Garage and MinIO agree within 10 %. Recent botocore does not hash the payload by
  default, which made Garage (CPU bound) look 2.5x faster: the request shape is a
  variable in itself. SeaweedFS still differs while median latencies are equal;
  open point, to look at before the sweeps (its PUT is very noisy, see below).

## Phase 2: homogeneous reference (`results/reference-1/reference.md`)

5 repetitions x 3 systems x 3 workloads, random order, fresh cluster each run, 30 s.

* Run to run CV at most 5 % everywhere except SeaweedFS PUT (20.7 %).
* Homogeneity: spread of requests between endpoints at most 7 %, CPU spread between nodes at most 6 %.
* 0 errors.
* SeaweedFS PUT goes by bursts (about 60 MiB/s, then stalls of several seconds while
  buffered writes are flushed under the disk limit). With 90 s runs the CV drops
  to about 9 % (19.1, 19.5, 22.3 MiB/s).

Median throughput of the reference:

| system | PUT | GET | mixed (GET part) |
|---|---|---|---|
| Garage | 35.6 MiB/s | 215.8 MiB/s | 89.7 MiB/s |
| MinIO | 69.7 MiB/s | 152.6 MiB/s | 94.9 MiB/s |
| SeaweedFS | 21.4 MiB/s | 155.7 MiB/s | 64.2 MiB/s |

## Decisions for the sweeps (Oct. 27 onward)

* 3 repetitions per point is enough to detect a 10 % change for every case except SeaweedFS PUT.
* PUT runs last 90 s on every system (same duration for all, needed for SeaweedFS).
* Degraded nodes are always node1 then node2; for SeaweedFS the master leader is recorded per run.
