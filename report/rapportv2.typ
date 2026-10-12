#import "@preview/merman:0.3.0": mermaid

#show raw.where(block: true): block.with(fill: luma(246), inset: 8pt, radius: 4pt, width: 100%)

#set page(
  header: [ _Marc Fuschino_ #h(1fr) MGL870 ],
  footer: [
    #context [ Page #counter(page).display() #h(1fr) ]
  ]
)
#set heading(numbering: "1.1.1.1)")
#set par(justify: true)
#linebreak() #linebreak() #linebreak() #linebreak()
#align(center)[
  #set text(20pt)
  #title("Distributed Object Storage on Bad Hardware")
]

#align(center)[
  #set text(24pt, weight: "semibold")
  MGL870 - Final Report
]
#align(center)[
  #set text(18pt)
  Made by Marc Fuschino
]
#linebreak()
#outline()
#pagebreak()

= Summary

Small clusters are often built from mismatched machines and/or relatively inexpensive hardware. We measured how three S3
systems, Garage, MinIO and SeaweedFS, behave when one of three nodes is slower than the
others, on a bench where the total resources of the cluster never change and only
their split between nodes does.

What we found:
- *The cluster follows its weakest node.* With one node five times slower, every
  system loses 61 to 82 % of its throughput, close to what the slowest node alone
  would allow. Writes always pay for the slow node. Reads are only unaffected using Garage, and
  only if the client does not send requests through the slow node.
- *An old hard disk kills small file reads.* With a modelled consumer hard disk on one
  node, small object reads drop to 3 % (MinIO) to 23 % (SeaweedFS) of their speed,
  while writes are barely affected, except on MinIO. This is to be expected of an HDD, whose head has to physically move to each piece of data.
- *A dead node loses no data but can freeze the service.* In 51 node kill campaigns,
  no object was ever lost, but the service often froze for 20 to 118 s. MinIO and
  SeaweedFS rebuild 500 MiB in about a minute; Garage waits about 10 minutes for its
  next metadata synchronisation.
- *The tools must be checked too.* Recent versions of warp, the reference S3
  benchmark, send almost identical objects, which made Garage look twice as fast.

= Context and Questions

Hardware is expensive, so many people build storage from old, mismatched machines: a
fast NVMe box next to an old laptop with a spinning disk and a weak link. Disks also
fail often enough that every cluster goes through rebuilds (Backblaze), and a part
can become slow long before it fails completely (Gunawi et al.). Three S3 systems
target this kind of use, each with a different design idea:
#figure(
image("img/ssd.png"),caption: [Price trend of a 4TB NVMe SSD from Apr. 2025 to Sept. 2026]
)
- *Garage* is built for cheap, mismatched nodes on slow links (Deuxfleurs).
- *MinIO* is built for identical machines in a datacenter (MinIO docs).
- *SeaweedFS* is built for many small files, with a central master for metadata
  (SeaweedFS docs).

Published benchmarks run them on identical machines. That is the one case where these
design ideas do not matter. We ask:

*Q1.* How much performance does each system lose when the nodes are not identical?

*Q2.* How long does a rebuild take after a node dies, and how slow is the service
during the rebuild?

*Q3.* Does the cluster run at the speed of its average node, or of its weakest node?

*We never rank the systems.* They do not even protect data the same way (full copies
against erasure coding). Each system is measured on identical nodes, then on degraded
nodes, and we report how much it loses.

= Background: Object Storage and S3

To understand what we measure, we first need to know what an S3 system does.

*What object storage is.* A classic file system (ext4, NTFS, APFS) stores files in a
tree of folders. A program can open a file, read a few bytes in the middle, change
them, append, rename, lock. Object storage is simpler. It stores *objects*: a blob of
bytes plus a little metadata, identified by a *key* (a name such as
`photos/2026/cat.jpg`) inside a *bucket* (a top level container). There is no real
folder tree: the slashes in a key are just characters. An object is written and read
as a whole; to change one byte, you upload the whole object again.

*The S3 API.* S3 is the object storage service of Amazon Web Services, and its HTTP
interface became the common language of object storage (AWS, S3 API reference). The
three systems we test all speak it. @tab-s3 lists the main operations; this study
uses PUT and GET.

#figure(
  table(
    columns: (auto, auto, 1fr),
    inset: 5pt,
    align: (left, left, left),
    table.header([*Operation*], [*HTTP request*], [*What it does*]),
    [PUT], [`PUT /bucket/key`], [upload a whole object (a write)],
    [GET], [`GET /bucket/key`], [download an object (a read)],
    [HEAD (or STAT)], [`HEAD /bucket/key`], [get the size and metadata only],
    [DELETE], [`DELETE /bucket/key`], [delete an object],
    [LIST], [`GET /bucket?list-type=2`], [list the keys of a bucket],
  ),
  caption: [Main S3 operations],
)<tab-s3>

*Why it fits a cluster.* Because objects are independent and written as a whole, a
system can spread them over many machines and keep several copies, without the hard
problems of a shared file system (locks, partial updates). Each node of the cluster
can act as a *gateway*: it receives S3 requests, finds which nodes hold the object,
and talks to them. Data is protected either by *replication* (several full copies on
different nodes) or by *erasure coding* (the object is cut into data pieces plus
parity pieces, so that any missing piece can be rebuilt from the others, like RAID)
(Kleppmann and Riccomini).

= Test Bench

This section describes how we build a cluster with one slow node, and how we checked
that the bench measures what we think it measures.

== Assumptions

We assume that:

- each system runs as *3 nodes on one machine*, one container per node;
- every system keeps its *default settings*: tuning one more than another would change
  the result more than the hardware does;
- *the total resources of the cluster are constant*: a slow node loses resources, the
  healthy nodes get them;
- the client sends its requests to the nodes *in turn* (round robin) and never avoids
  a slow node by itself;
- every object contains *unique random data*, so no system can save work by removing
  duplicates.

== Clusters

@tab-systems lists the versions and how each system protects data. MinIO no longer
publishes container images and its repository is archived, so we build it from its
last release tag.

#figure(
  table(
    columns: (auto, auto, 1fr),
    inset: 5pt,
    align: (left, left, left),
    table.header([*System*], [*Version*], [*Redundancy and roles*]),
    [Garage], [v2.4.1], [3 copies of each block, one zone per node],
    [MinIO], [RELEASE.2025-10-15], [erasure coding on 3 drives: 2 data + 1 parity (default)],
    [SeaweedFS], [4.48], [3 copies (replication 002); each node runs master, volume server, filer and S3 gateway],
  ),
  caption: [Systems under test. All other settings are defaults.],
)<tab-systems>

== How a node is made slow

We do not use real slow machines. We limit each container with Linux kernel
features, which makes every condition exactly reproducible:

- *CPU*: cgroup `cpu.max`. Memory is fixed at 1 GB per node.
- *Disk*: cgroup `io.max`, which caps bytes per second and operations per second
  (IOPS) for reads and writes (Linux kernel docs, cgroup v2).
- *Network*: `tc netem` caps the outgoing rate and adds delay; incoming traffic is
  capped at the same rate (tc-netem man page).

A nominal node has 1 CPU, 25 MiB/s read, 40 MiB/s write, 800 read IOPS, 600 write
IOPS, and a 1 Gbit/s link with 1 ms delay. *The total budget of the cluster never
changes.* When a node is made $k$ times slower, it gets $1 slash k$ of the nominal
resources, and what it loses is shared between the healthy nodes. (Delay is the
exception: a slow node gets $k$ times the nominal delay.) @fig-bench shows the result
at our reference point, $k = 5$.

#figure(
  mermaid(
    "
flowchart LR
  LG[warp client] --> N1[\"Node 1: 0.2 CPU, 5 MiB/s disk read, 200 Mbit/s\"]
  LG --> N2[\"Node 2: 1.4 CPU, 35 MiB/s disk read, 1.4 Gbit/s\"]
  LG --> N3[\"Node 3: 1.4 CPU, 35 MiB/s disk read, 1.4 Gbit/s\"]
  classDef weak fill:#fdecea,stroke:#c0392b
  classDef ok fill:#eafaf1,stroke:#27ae60
  class N1 weak
  class N2,N3 ok
",
    document-context: true,
    width: 70%,
  ),
  caption: [The bench at the reference point: node 1 is 5 times slower, and its lost
  resources go to nodes 2 and 3, so the cluster keeps 3 CPU in total. The nodes also
  talk to each other (replication, metadata), not drawn here.],
)<fig-bench>

Making node 1 five times slower comes down to the commands below (simplified from
`limits.sh`; the disk numbers are the major and minor numbers of the VM disk):

```bash
# CPU: 0.2 of a core
docker update --cpus 0.2 garage-node1
# Disk: 5 MiB/s read, 8 MiB/s write, 160 and 120 IOPS, in the container's cgroup
echo "253:16 rbps=5242880 wbps=8388608 riops=160 wiops=120" \
  > /sys/fs/cgroup/docker/<container id>/io.max
# Network, run inside the container's network namespace:
# 200 Mbit/s and 5 ms of delay on the way out, 200 Mbit/s on the way in
tc qdisc add dev eth0 root netem delay 5ms rate 200mbit
tc qdisc add dev eth0 handle ffff: ingress
tc filter add dev eth0 parent ffff: matchall action police rate 200mbit burst 1m drop
```

Because the budget is constant, Q3 becomes easy to read: a cluster that follows its
*average* node keeps its throughput, while a cluster that follows its *weakest* node
drops to $1 slash k$ of it. The ratio $r$ and the index $W$ that measure this are
defined in @sec-numbers.

== Load and measurements

The load comes from warp, an S3 benchmark tool (MinIO, warp). warp runs in its own
container with 2 CPU, outside the cluster budget. It keeps 8 requests in flight at
all times (8 parallel workers) and sends them to the three nodes in turn: node 1,
node 2, node 3, node 1, and so on. This is called *round robin*. It is what a simple
setup does in practice, for example *DNS round robin*, where one name (such as
`s3.home.lan`) points to the three addresses and each client picks the next one.
warp records every request: start, end, size, node and error.

== Software stack

@tab-stack shows the layers of the bench, from the laptop to the analysis.

#figure(
  table(
    columns: (auto, 1fr),
    inset: 5pt,
    align: (left, left),
    table.header([*Layer*], [*Role*]),
    [macOS laptop], [Apple M series, 8 cores, 8 GB. Runs the scripts and the analysis.],
    [Colima], [Runs a small Linux virtual machine (Ubuntu, kernel 6.8, 6 vCPU, 6 GB,
      15 GB disk) with Docker inside. We need it because containers and cgroup v2 limits
      exist only on Linux (Colima).],
    [Docker Compose], [One file per system describes its three nodes, their disks and
      their network (Docker docs).],
    [Helper image], [Alpine Linux with fio, stress-ng, iperf3 and Python: calibration
      probes, resource sampler, a second S3 client (boto3) and data checks.],
    [Python and uv], [Analysis and figures (matplotlib) on the laptop. uv installs the
      libraries each script needs (Astral, uv).],
  ),
  caption: [Layers of the bench],
)<tab-stack>

Every run follows the same steps:

+ `up.sh` starts an empty cluster and waits until it is healthy.
+ `limits.sh` applies the condition and saves it to `limits.json`.
+ `run_warp.sh` starts warp. At the same time, a sampler reads every second the CPU,
  memory, disk and network counters of each node and of the client.
+ `down.sh` deletes the cluster and its data.
+ `summarize.py` turns the raw data into one summary per run: throughput, latency
  percentiles (overall and per node) and resources per node.

A campaign is a list of runs in random order. Random order spreads slow periods of
the machine over all conditions instead of hitting one of them. Campaigns can be
stopped and restarted: finished runs are skipped. The raw data is kept, so every
number in this report can be traced back to the requests behind it.

== Checking the bench first

Before measuring the systems, we checked the bench itself.

*Limits.* Three probe containers got exactly the same limits as the nodes. We
measured them with fio (disk), stress-ng (CPU), iperf3 (network) and ping. The disk
limits held within 5 % in every condition, including the extreme one (two nodes
10 times slower, one node at 2.8 times the nominal). The network reached 92 to 96 %
of its rate. The measured round trip was about 1.4 times the configured delay, but
the ratios between nodes were kept. The CPU limit held within 5 %, except at 0.2 CPU
(85 % of the target). Our first disk budget was too high for the virtual disk, so we
lowered it: otherwise the machine, not our limits, would have set the speed.

*Repeatability.* To know how many repetitions we need, we first ran each system five
times on identical nodes. Results varied by less than 5 % between runs, and the load was spread evenly over the nodes (within
7 %). SeaweedFS writes were the exception: they come in bursts while buffered data is
flushed to disk, so write runs last 60 s instead of 30 s.

*Load generator.* warp is made by MinIO, one of the vendors we test, so we checked it
instead of trusting it. We read back the objects warp had written and compared their
SHA256 hashes:

```python
counts = collections.Counter()
for key in keys[:100]:                       # objects written by warp
    data = s3.get_object(Bucket="bench", Key=key)["Body"].read()
    counts[hashlib.sha256(data).digest()] += 1
print(len(counts), "distinct objects out of", sum(counts.values()))
```

*warp versions 1.1.0 to 1.3.1 send almost identical objects*: with 8 workers, 60
objects written by versions 1.1.6 to 1.3.1 (the ones we tested) contained only 5 to 7
different ones, and
with a single worker all 52 objects written by v1.3.1 were identical. Each worker sends
the same bytes again and again; we did not find which change in warp caused it.
Garage removes duplicate 1 MiB blocks, so it stored almost nothing and its writes
looked twice as fast as they are (48.5 instead of 24.1 MiB/s). We use warp v1.0.8,
which sends 100 different objects out of 100.

A second client written with boto3 (AWS) agrees with warp within 10 % on Garage and
MinIO, once both send the same kind of request: recent boto3 versions skip the payload
checksum by default, which alone made Garage, limited by its CPU, look 2.5 times
faster. On SeaweedFS the two clients still differ by 30 to 47 %. Finally, the client
never used more than a quarter of its CPU, so it never limited the results.

= Method

This section says what we measure and how each number is computed.

== Sweeps

We start from a reference point: one node out of three, all resources 5 times
slower, 1 MiB objects. Then we change one thing at a time, as listed in @tab-sweeps.

#figure(
  table(
    columns: (auto, auto, 1fr),
    inset: 5pt,
    align: (center, left, left),
    table.header([*Sweep*], [*Values*], [*Question*]),
    [S1], [CPU, disk, network, all three], [Which resource matters most?],
    [S2], [1, 2, 5, 10 times slower], [Is the loss gradual or sudden?],
    [S3], [0, 1 or 2 slow nodes], [Does losing the majority change things?],
    [S4], [16 KiB, 1 MiB, 8 MiB objects], [Does object size change the loss?],
  ),
  caption: [The four sweeps],
)<tab-sweeps>

Each condition is measured twice: once for writes and once for reads.

- *Write run*: for 60 s, the client uploads new objects (PUT) as fast as the cluster
  accepts them.
- *Read run*: the client first uploads about 200 MiB of objects, then for 30 s
  downloads them again and again (GET). Only those 30 s are measured.

Each run is repeated three times, in random order, each time on a new cluster. For S4
we also measure identical nodes at each object size, so we always compare the same
size.

== A modelled consumer hard disk

`io.max` caps throughput and IOPS, but every operation stays as fast as the SSD
underneath. A real hard disk is different: it is not slow at reading long files, it
is slow at *finding* data. A WD Blue 7200 rpm needs about 8.9 ms to move its head and
4.2 ms for the platter to turn, so about 13 ms per random access (Showmetech), and a
laptop disk is closer to 15 to 18 ms. This gives about 75 to 130 random reads per
second (StorageReview). Its cache absorbs writes, but a *flush* (fsync) must wait for
the platter.
*IOPS* (input/output operations per second) counts how many separate reads or writes
a disk can do each second, whatever their size. For small random accesses this is what
limits a disk; for long sequential files, throughput in MiB/s matters more.
@tab-hdd-model compares a real hard disk, our model, and a nominal node of the sweeps.

#figure(
  table(
    columns: (auto, auto, auto, auto),
    inset: 5pt,
    align: (left, right, right, right),
    table.header([*Measure*], [*Real 7200 rpm disk*], [*Our model (fio)*], [*Nominal node*]),
    [Time of one random read], [about 13 ms], [13 ms], [n/a (SSD)],
    [Random reads per second, one at a time], [75 to 130], [77], [800 (cap)],
    [Random reads per second, 16 in flight], [n/a], [149], [800 (cap)],
    [Synchronous writes per second], [n/a], [38], [600 (cap)],
    [Sequential read], [40 to 150 MB/s], [25 MiB/s (cap)], [25 MiB/s (cap)],
  ),
  caption: [A real consumer hard disk (Showmetech; StorageReview), our model measured
  with fio, and the limits of a nominal node. n/a: no published figure found.],
)<tab-hdd-model>

We give the hard disk to node 1 only. The question of this study is what *one* bad
node does to a cluster of good ones; a cluster made only of hard disks would be
another homogeneous cluster, compared with nothing. We build the disk by stacking
Linux block devices, as shown in @fig-hdd:

+ a sparse file on the VM disk, used as a block device (loop device);
+ *dm-delay* on top, which delays every read by 13 ms, every write by 2 ms (the
  write lands in the disk cache) and every flush by 20 ms (Linux kernel docs,
  dm-delay; Oracle Linux blog);
+ `io.max` on that device, capped at 150 reads and 200 writes per second: dm-delay
  delays operations in parallel, while a disk has a single head;
+ an ext4 file system, mounted as the volume of node 1.

#figure(
  mermaid(
    "
flowchart TB
  V[volume of node 1, ext4] --> T[io.max: 150 reads/s, 200 writes/s]
  T --> DD[dm-delay: read 13 ms, write 2 ms, flush 20 ms]
  DD --> LO[loop device]
  LO --> F[sparse file on the VM disk]
",
    document-context: true,
    width: 36%,
  ),
  caption: [The modelled hard disk of node 1, from the file system down to the real disk],
)<fig-hdd>

The core of the model is one device mapper table: read delay, write delay and flush
delay, each in milliseconds, on top of the loop device (from `hdd.sh`):

```bash
loop=$(losetup --direct-io=on -f --show hdd-node1.img)
size=$(blockdev --getsz $loop)
dmsetup create hdd-node1 --table "0 $size delay $loop 0 13 $loop 0 2 $loop 0 20"
```

The CPU and network of node 1 stay nominal. @tab-hdd-model shows the fio measurements
of the model.

Reads of recently written data would come from memory and never reach this disk.
During the read runs of this experiment, we therefore ask the kernel every second to
drop the page cache of each node (cgroup `memory.reclaim`), for the homogeneous
reference as well.

== How the numbers are computed <sec-numbers>

*Throughput of one run ($T_i$).* $T_i$ is the average speed seen by the client during
run $i$, in MiB/s: the amount of data successfully transferred, divided by the time
it took. warp logs every request; we ignore the first 3 s (warm up) and failed
requests. With $b_q$ the size of request $q$, $cal(R)_i$ the set of requests kept, and
$Delta t_i$ the measured duration:
$ T_i = (sum_(q in cal(R)_i) b_q) / (Delta t_i) $

*One condition ($T(c)$).* A condition $c$ fixes everything we control: system,
operation (PUT or GET), object size, which resource is slowed down, by how much, on
how many nodes, and which nodes the client talks to. It is run 3 times (the 5 runs of
the repeatability check showed that 3 are enough, since runs differ by less than 5 %),
and we keep the middle value (the median), which ignores one unusually fast or slow run:
$ T(c) = "median"(T_1, T_2, T_3) $

*Ratio ($r$).* $c_0$ is the same condition with identical nodes: everything equal,
only the slowdown removed. The ratio is the share of throughput the cluster keeps:
$ r(c) = T(c) / T(c_0) $
$r = 1$ means no loss; $r = 0.33$ means the cluster keeps a third of its speed. Because
the total budget is constant, $r$ can be above 1: the healthy nodes have more
resources than in the homogeneous cluster.

*Slowdown factor ($k$, written 2x, 5x, 10x).* The slow node gets $1 slash k$ of the
nominal CPU, disk and network: at 5x it has 0.2 CPU, 5 MiB/s of disk reads, 200 Mbit/s
of network, and 5 ms of delay instead of 1 ms.

*Index ($W$).* $W$ answers Q3 with one number: where does $r$ sit between "follows
the average node" ($r = 1$) and "follows the weakest node" ($r = 1 slash k$)?
$ W = (1 - r) / (1 - 1 slash k) $
$W = 0$: no loss, the cluster follows its average node. $W = 1$: the cluster is as slow
as its weakest node. $W$ between 0 and 1: in between. $W > 1$: even slower than its
weakest node.

*Latency percentiles (p50, p99).* The latency of a request is the time between sending
it and receiving the full answer. Sort the latencies of all requests of a run: the
*p50* (median) is the value in the middle, so half of the requests were faster; the
*p99* is the value below which 99 % of the requests fall, so it describes the slowest
1 % (the "tail"). Users notice the tail: one page that loads slowly is enough. As for
throughput, we keep the median of the 3 runs.

=== Worked example

To make these definitions concrete, here is how one number of @tab-s2 is obtained:
Garage, GET, 1 MiB objects, node 1 five times slower on all resources.

*1. Raw data.* warp logs one line per request (start time, end time, size, node,
duration, error). Here are two of them, from the first run: one request answered by
node 2 in 39 ms, one by node 3 in 37 ms (some columns left out):

```
op   bytes    endpoint                  duration_ns  error
GET  1048576  http://garage-node2:3900  39202434
GET  1048576  http://garage-node3:3900  37270406
```

The size is in bytes: 1048576 bytes = 1024 × 1024 = 1 MiB, the object size of this
example. Small objects (16 KiB = 16384 bytes) are only used in S4 and in the hard disk
experiment.

*2. One run.* After the 3 s of warm up, the first run moved 1845 MiB in 27.2 s, so
$T_1 = 1845 slash 27.2 approx 67.7$ MiB/s. The two other runs give 67.3 and 67.6 MiB/s.

*3. One condition.* $T(c) = "median"(67.7, 67.3, 67.6) = 67.6$ MiB/s.

*4. The reference.* The same three runs with identical nodes give 204.9, 201.5 and
214.2 MiB/s, so $T(c_0) = 204.9$ MiB/s.

*5. Ratio and index.* $r = 67.6 slash 204.9 = 0.33$, and with $k = 5$:
$W = (1 - 0.33) slash (1 - 0.2) = 0.84$. Garage reads are much closer to the weakest
node model ($W = 1$) than to the average node model ($W = 0$).

== Node kill campaigns

Each campaign follows these steps:

+ Start a new cluster and write 500 objects of 1 MiB of random data. Keep the SHA256
  of each object.
+ Read the objects continuously.
+ After 60 s, kill one node and delete its disk.
+ 60 s later, read back every object and check its SHA256.
+ Replace the dead node with an empty one and apply the procedure each system
  documents. Garage needs a new layout, and must be told the old node is gone for good
  (Deuxfleurs). MinIO repairs the new drive on its own. SeaweedFS needs an operator to
  run `volume.fix.replication` (SeaweedFS docs).
+ Wait until the new node holds 95 % of the bytes of the other nodes: the rebuild is
  done. We do not wait for 100 %, because the old nodes also hold things the new one
  never gets back, such as their metadata history and logs, so 100 % might never be
  reached. The final data check then confirms that every object is there.
+ Keep reading for 60 s, then check every object one last time.

The client only talks to the two nodes that are never killed. This way, a dead
gateway is not counted as a storage failure.

We run three scenarios, at least twice per system:

- identical nodes, one node killed;
- one slow node (all resources, 5 times slower), and that slow node is killed;
- one slow node, and a healthy node is killed. The slow node must then help rebuild.

A system is reliable here if every object stays readable while a node is dead, and
after the rebuild.

= Results

The 216 sweep runs all finished. The median difference between the three repetitions
of a point is 5 %, and only one request failed in total.

== Q1 and Q3: the cluster follows its weakest node

We first want to know how much a single slow node costs, and which model the cluster
follows. *The cluster behaves close to its weakest node.* @tab-s2 gives the ratio $r$
for each system and slowdown, and @fig-s2 plots it. At 5x, $r$ is between 0.18 and
0.39: every system keeps only 18 to 39 % of its throughput, so it loses 61 to 82 %.

#figure(
  table(
    columns: (auto, auto, auto, auto, auto),
    inset: 5pt,
    align: (left, right, right, right, right),
    table.header([*System, op*], [*Identical nodes $T(c_0)$*], [*$r$, node 2x slower*], [*$r$, 5x slower*], [*$r$, 10x slower*]),
    [Garage PUT], [36 MiB/s], [0.58], [0.39], [0.09],
    [Garage GET], [205 MiB/s], [0.77], [0.33], [0.07],
    [MinIO PUT], [71 MiB/s], [0.49], [0.18], [0.09],
    [MinIO GET], [151 MiB/s], [0.66], [0.24], [0.11],
    [SeaweedFS PUT], [21 MiB/s], [0.65], [0.34], [0.20],
    [SeaweedFS GET], [155 MiB/s], [0.62], [0.26], [0.13],
  ),
  caption: [One node out of three slowed down on all resources, 1 MiB objects. If the
  cluster followed its weakest node, $r$ would be 0.50, 0.20 and 0.10.],
)<tab-s2>

#figure(image("../figures/s2_factor.png", width: 100%),
  caption: [S2: throughput compared with identical nodes, as one node gets slower.
  Dashed lines: the two models (average node, weakest node).])<fig-s2>

A cluster that followed its average node would keep $r = 1$; one that followed its
weakest node would drop to $r = 1 slash k$: 0.50 at 2x, 0.20 at 5x, 0.10 at 10x.

- MinIO writes match the weakest node almost exactly: $r$ = 0.49, 0.18 and 0.09.
- Garage and SeaweedFS writes do a bit better at 2x and 5x ($r$ 0.58 to 0.65 at 2x,
  0.34 to 0.39 at 5x). For Garage, this margin disappears at 10x ($r$ = 0.09).
- Slow requests suffer much more than average ones. At 5x, the 99th percentile
  latency is 3 to 10 times higher, and up to 45 times for Garage reads at 10x.

The curves of @fig-s2 also show that the loss grows step by step with the slowdown:
there is no sudden collapse.

== S1: which resource matters most

Next we slow down one resource at a time. *It depends on the operation*: a slow
network hurts every read, a slow disk every write, and a slow CPU separates the
designs. @fig-s1 shows the ratio for each resource.
#figure(image("../figures/s1_resource.png", width: 100%),
  caption: [S1: one resource of one node made 5 times slower.])<fig-s1>

- *Slow network* hurts all reads ($r$ 0.25 to 0.33): one third of the answers go
  through the slow link.
- *Slow disk* hurts all writes ($r$ 0.18 to 0.24) but not much the reads (MinIO 0.78,
  the others 1.0): recently written data is read from memory, so the slow disk is
  barely used. The hard disk experiment below removes this effect.
- *Slow CPU* shows the biggest design differences. SeaweedFS reads do not notice it
  (0.99) and Garage reads barely (0.86), but MinIO loses 70 % of its reads. This fits
  erasure coding, where every node helps rebuild each object, but we did not profile
  it. For writes, slow CPU hurts Garage most (0.26), probably because each node hashes
  and checks every block it stores.

== S3: losing the majority

We expected a well designed system to avoid a single slow node while it still has a
healthy majority, and to suffer only when the majority is lost. *A second slow node
changes almost nothing*: $r$ moves by 0.11 at most (@fig-s3). With one slow node, the
cluster already runs at the speed of that node, so a second one has little left to
take. The gateway effect, below, explains why.

#figure(image("../figures/s3_nodes.png", width: 100%),
  caption: [S3: number of slow nodes out of three, all resources, 5x.])<fig-s3>

== S4: object size

SeaweedFS claims to be good at small files, so we test if object size changes the
loss. *No object size makes the loss smaller* (@fig-s4). Large objects (8 MiB) follow
the weakest node on every system ($W$ 0.94 to 1.05). Small objects (16 KiB) are the
worst case for MinIO reads and for SeaweedFS ($W$ 1.08 to 1.16, worse than the
weakest node). SeaweedFS loses 93 % of its small object writes. Only MinIO small writes
lose less ($r$ 0.37).

#figure(image("../figures/s4_size.png", width: 100%),
  caption: [S4: object size at the reference point (one node, all resources, 5x).
  Each ratio uses identical nodes at the same size.])<fig-s4>

== Gateway effect

In the sweeps the client sends one third of its requests to the slow node. The slow
node then answers slowly no matter what the storage system does inside. To separate
the two effects, we ran S2 again with a client that only talks to the two healthy
nodes, as shown in @fig-gw-schema. Its reference $c_0$ is also measured with the client
on the two healthy nodes, so the ratio only measures what the slow node costs
*inside* the cluster.

#figure(
  grid(
    columns: (1fr, 1fr),
    gutter: 12pt,
    mermaid("
flowchart LR
  C[Client] --> N1[Node 1 slow]
  C --> N2[Node 2]
  C --> N3[Node 3]
  classDef weak fill:#fdecea,stroke:#c0392b
  class N1 weak
", document-context: true, width: 72%),
    mermaid("
flowchart LR
  C[Client] --> N2[Node 2]
  C --> N3[Node 3]
  N2 -.-> N1[Node 1 slow]
  classDef weak fill:#fdecea,stroke:#c0392b
  class N1 weak
", document-context: true, width: 100%),
  ),
  caption: [Left: the sweeps, where the slow node is also a gateway. Right: the gateway
  test, where the client only uses healthy nodes; the slow node is only reached by the
  other nodes, inside the cluster (dotted link).],
)<fig-gw-schema>

*Writes always follow the weakest node*; reads only escape it on Garage, and only when
the client avoids the slow node. @fig-gw compares the two setups.

#figure(image("../figures/gateway.png", width: 100%),
  caption: [S2 with the client on all three nodes (dotted) and on the two healthy
  nodes only (solid).])<fig-gw>

- *Garage reads* get *faster* than on identical nodes ($r$ 1.12 to 1.25, against 0.07
  to 0.77 through the slow gateway). Garage reads from the healthy nodes, which
  received the budget of the slow one. All of its read loss in the sweeps came from
  the gateway. The reason is in its code: to read, a Garage node only asks as many
  nodes as it needs, choosing itself first, then the nodes with the lowest latency
  (`request_order` in `src/rpc/rpc_helper.rs`). With 3 copies on 3 nodes, a healthy
  gateway already holds every block, and the metadata it needs from a second node
  comes from the other healthy one, which answers faster. It never has to wait for the
  slow node.
- *MinIO and SeaweedFS reads* recover at 2x, but still lose at 5x and 10x ($r$ 0.16 to
  0.48, $W$ 0.66 to 0.93): their read path still waits for the slow node. For MinIO
  this fits erasure coding, where 2 of the 3 shards are needed to rebuild an object.
- *Writes* follow the weakest node on all systems, with or without the slow gateway
  ($W$ 0.70 to 1.03). Every write must reach the nodes that store the copies, including
  the slow one.

== An old hard disk in the cluster

We now replace the slow disk of the sweeps by the modelled hard disk on node 1. *An
old hard disk mostly hurts reads of small files.*

We first found that some writes looked *faster* with the hard disk (Garage small
writes, $r = 1.42$). The reason was not the disk: the hard disk node has its own file
system, while the other nodes share the file system of the VM disk, with a single
journal. We therefore added a control: the same stack (own file system, loop device,
dm-delay) with 0 ms of delay and the nominal IOPS. In this section the ratio
compares the hard disk with that control instead of with identical nodes:
$ r_"hdd" = T("hdd") / T("control") $
where the control plays the role of $c_0$. @tab-hdd gives $r_"hdd"$.

#figure(
  table(
    columns: (auto, auto, auto, auto, auto),
    inset: 5pt,
    align: (left, right, right, right, right),
    table.header([*System*], [*GET 16 KiB*], [*GET 1 MiB*], [*PUT 16 KiB*], [*PUT 1 MiB*]),
    [Garage], [0.19], [0.22], [1.02], [0.91],
    [MinIO], [0.03], [0.17], [0.52], [0.74],
    [SeaweedFS], [0.23], [0.98], [1.17], [0.95],
  ),
  caption: [Throughput with a hard disk on node 1, divided by the control (same stack,
  no delay). Reads drop the page cache every second, so they reach the disks. 3 runs
  per value.],
)<tab-hdd>

- *Reads suffer, small objects most.* With one hard disk out of three, Garage keeps
  about a fifth of its reads, and MinIO only 3 % of its small object reads. The 99th
  percentile latency of reads grows 5 to 10 times on Garage and MinIO, and 27 times
  for SeaweedFS small objects.
- *SeaweedFS reads large objects at full speed* (0.98). This fits its design, taken
  from Facebook's Haystack: objects are appended to large volume files and found with
  an index in memory, so reading an object costs one disk access followed by a long
  sequential read (Beaver et al.; SeaweedFS docs). Garage stores each 1 MiB block in
  its own file, and MinIO splits each object into shards plus a metadata file, which
  costs more random accesses. We did not trace the disk accesses to prove it.
- *Writes barely notice the hard disk*, except on MinIO (0.52 and 0.74). Writes land in
  the disk cache and in the page cache first, and Garage and SeaweedFS do not force
  them to the platter by default. MinIO syncs its writes to disk before answering,
  which fits its larger loss: it pays for durability at once. (SeaweedFS small writes
  at 1.17 are within the noise of these runs.)

Small files are the typical load of a home server (documents, thumbnails, backups
made of many small files).

== Q2: node kill and rebuild

Finally we kill nodes, to see what the user loses and how long the cluster stays with
one copy less. *No data was lost* in 51 campaigns, but the service often froze, and
Garage rebuilds ten times slower than the others. @tab-freeze counts the freezes, that
is the campaigns in which the client got no answer at all for 10 s or more while the
node was dead (for Garage this includes the rebuild tests below, which are identical
until the replacement). @tab-rebuild-time gives the rebuild time, from the replacement
until the new node holds its data, and the read speed during the rebuild divided by
the speed before the kill (not counting the campaigns where the slow node died, where
reads got faster, see below). @fig-kill shows the read throughput around a kill.

#let bad = rgb("#fdecea")
#let mid = rgb("#fff4e0")
#let good = rgb("#eafaf1")

#figure(
  table(
    columns: (auto, auto, auto, auto),
    inset: 5pt,
    align: (left, center, center, center),
    table.header([*System*], [*Identical nodes*], [*Slow node killed*], [*Healthy node killed*]),
    [Garage], table.cell(fill: bad)[5 of 6], table.cell(fill: good)[0 of 6], table.cell(fill: bad)[7 of 9],
    [MinIO], table.cell(fill: good)[0 of 2], table.cell(fill: good)[0 of 2], table.cell(fill: mid)[2 of 5],
    [SeaweedFS], table.cell(fill: good)[0 of 2], table.cell(fill: mid)[1 of 2], table.cell(fill: bad)[4 of 5],
  ),
  caption: [Campaigns in which the service froze for 10 s or more],
)<tab-freeze>

#figure(
  table(
    columns: (auto, auto, auto),
    inset: 5pt,
    align: (left, center, center),
    table.header([*System*], [*Rebuild time*], [*Read speed during rebuild*]),
    [Garage], table.cell(fill: bad)[632 to 690 s], table.cell(fill: good)[0.93 to 1.03],
    [MinIO], table.cell(fill: good)[38 to 64 s], table.cell(fill: mid)[0.81 to 0.93],
    [SeaweedFS], table.cell(fill: good)[67 to 103 s], table.cell(fill: mid)[0.88 to 1.00],
  ),
  caption: [Rebuild of 500 MiB with default settings],
)<tab-rebuild-time>

#figure(image("../figures/kill_timelines.png", width: 100%),
  caption: [Read throughput around a node kill (first repetition of each scenario)])<fig-kill>

*No data was lost.* In every campaign, all 500 objects were readable with one node
dead, and again after the rebuild, with the right SHA256.

*The service can freeze after a node dies.* The client sometimes got no answer at all
for up to two minutes, although it only talks to the surviving nodes. The surviving
nodes keep waiting for the dead one until a timeout: a `docker kill` behaves like a
power cut, the node does not close its connections and its packets are simply lost.
Freezes happened on all three systems, most often when a healthy node died next to a
slow one (@tab-freeze). For Garage, it depends on which node dies: it froze in 12 of the
15 campaigns where node 3 died, and in none of the 6 where node 1 died. We did not
find why.

*Garage waits about 10 minutes before rebuilding.* The bytes on the new node over time
show why its rebuild is slow: for about 10 minutes nothing arrives, then everything is
copied in about 40 s. Garage only learns which blocks the new node must hold when its
metadata tables run a full synchronisation, every 10 minutes for tables split between
nodes (Garage source code, simplified):

```rust
// src/table/replication/sharded.rs
const ANTI_ENTROPY_INTERVAL: Duration = Duration::from_secs(10 * 60);
// src/block/resync.rs: default rebuild settings
const INITIAL_RESYNC_TRANQUILITY: u32 = 2;   // sleep twice the time spent working
ResyncPersistedConfig { n_workers: 1, tranquility: INITIAL_RESYNC_TRANQUILITY }
```

Garage's rebuild speed settings do not help: with 4 workers instead of 1 and no pause
between blocks, the rebuild still took 616 to 672 s. Asking for the synchronisation
at once (`garage repair tables`, then `garage repair blocks`) worked in 3 of 6
campaigns (90 % of the data back within 59 to 95 s) and did nothing in the 3 others;
we suspect the repair sometimes starts before the new node has accepted the new
layout, but we did not check it.

*A fast rebuild is paid by the users*: MinIO and SeaweedFS have all their copies
back after about a minute but slow reads by up to 19 % meanwhile (32 % for Garage with
an immediate repair), while the default Garage rebuild is invisible to the client but
leaves the data with one copy less for more than 10 minutes.

*Losing the slow node makes the cluster faster.* When the slow node dies, MinIO and
SeaweedFS read 1.7 to 3.5 times faster than before, while the node is dead
(@fig-kill): they were waiting for it. The replacement node gets the same limits, so
speed drops back once it rejoins. Garage reads barely change, because they did not
depend on the slow node in the first place (see the gateway effect).

*With the hard disk.* We also ran 12 campaigns with node 1 on the modelled hard disk
and the page cache dropped all the time, so that the hard disk must serve the
rebuild. Data was again never lost. Only MinIO clearly rebuilt slower (154 to 196 s
instead of 109 to 120 s); for Garage and SeaweedFS the difference stayed within the
spread of the repetitions.

= Threats to Validity

*One machine.* All nodes share one machine and one disk. Our limits create the
imbalance and we checked them, but other shared parts (memory bandwidth, the virtual
machine) are not controlled.

*The laptop swapped part of the VM memory.* The laptop has 8 GB and gave 6 GB to the
virtual machine for the main sweeps; macOS compressed or swapped part of it, which adds
noise. We reduced the virtual machine to 4 GB (swap reads dropped from about 1700 to
under 100 per minute) and ran the homogeneous reference and the reference point again:
throughput moved by 10 % at most and the ratios by 0.06 at most.

*The slow disk of the sweeps is not a hard disk.* It caps throughput but adds no delay
to each operation, and reads often come from memory (see S1). The hard disk experiment
adds that delay, but it is still a model: no seek that depends on the distance, and no
SMR effects, the shingled disks whose writes collapse once their cache is full
(iXsystems; Storage Disk Prices).

*The second client disagrees on SeaweedFS.* warp had to be pinned to an older version,
and the second client differs from it by 30 to 47 % on SeaweedFS. If one client
measures SeaweedFS, say, 30 % too fast, it does so on identical nodes and on degraded
nodes alike, and the error cancels out in $r = T(c) slash T(c_0)$, like a scale that
weighs everything 30 % too heavy still gives the right ratio between two weights. This
only holds if the error is the same in both conditions, which we could not check, so
absolute numbers for SeaweedFS should be read with care.

*"Rebuilt" means the bytes are back.* It does not prove every internal structure is
repaired. The final data check covers what users see.

= Conclusion

*Q1.* Every system loses most of its speed when one node is slower, even with the
same total resources, and the loss grows smoothly with the slowdown.

*Q2.* No data was lost in any campaign. The price of a dead node is availability, not
durability: the service can freeze for up to two minutes, and the rebuild takes about
a minute or, for Garage, more than ten.

*Q3.* Mostly the weakest node. Writes always follow it, because every copy must be
written. Reads depend on the design and on the client.

@tab-verdict checks each design claim against our measurements.

#figure(
  table(
    columns: (auto, auto, 1fr),
    inset: 6pt,
    align: (left, center, left),
    table.header([*Claim*], [*Verdict*], [*Why*]),
    [Garage handles mismatched nodes], table.cell(fill: mid)[partly],
      [reads avoid the slow node, but only if clients avoid it too; writes still wait for it],
    [MinIO needs identical machines], table.cell(fill: good)[yes],
      [it follows its weakest node most closely, and loses most with a hard disk],
    [SeaweedFS is good at small files], table.cell(fill: bad)[no, here],
      [with a weak node, small files lose more than large ones; only large reads stay fast on a hard disk],
  ),
  caption: [Design claims against our measurements (this setup only)],
)<tab-verdict> 

For someone building storage from old machines, three practical lessons follow. Do not
use the weakest machine as an entry point for clients. Avoid putting an old hard disk
in a cluster that serves many small files. And test failures with your own hardware
and load before trusting a system, because the numbers published on identical
machines do not apply.

*Future work.* Real mismatched machines instead of limits; shingled (SMR) hard disks;
more than three nodes, where a weak node is a smaller share of the cluster; and the
open questions of this study: why Garage freezes only when some nodes die, why its
repair works only half of the time, and why the second client disagrees with warp on
SeaweedFS.

= References

#set par(hanging-indent: 1.5em)

Amazon Web Services. _Amazon S3 API Reference_.
https://docs.aws.amazon.com/AmazonS3/latest/API/Welcome.html

Amazon Web Services. _boto3, AWS SDK for Python_. https://github.com/boto/boto3

Astral. _uv: Python package and project manager_. https://github.com/astral-sh/uv

Axboe, J. _fio: flexible I/O tester_. https://github.com/axboe/fio

Backblaze. _Backblaze Drive Stats for Q1 2026_.
https://www.backblaze.com/blog/backblaze-drive-stats-for-q1-2026/

Beaver, D., Kumar, S., Li, H. C., Sobel, J., Vajgel, P. _Finding a needle in Haystack:
Facebook's photo storage_. USENIX OSDI, 2010.

abiosoft and contributors. _Colima: container runtimes on macOS with minimal setup_.
https://github.com/abiosoft/colima

Deuxfleurs. _Garage documentation: design goals and internals_. https://garagehq.deuxfleurs.fr

Docker Inc. _Docker Engine and Docker Compose documentation_. https://docs.docker.com

ESnet. _iperf3_. https://github.com/esnet/iperf

Gunawi, H. S. et al. _Fail-Slow at Scale: Evidence of Hardware Performance Faults in Large
Production Systems_. USENIX FAST, 2018.
https://people.cs.vt.edu/huaicheng/s/fast18-failslow-slides.pdf

Hunter, J. D. _Matplotlib: A 2D Graphics Environment_. Computing in Science and Engineering,
9(3), 2007.

iXsystems. _WD Red SMR drive compatibility with ZFS_. https://www.truenas.com/docs/hardware/notices/wdsmr

King, C. I. _stress-ng_. https://github.com/ColinIanKing/stress-ng

Kleppmann, M., Riccomini, C. _Designing Data-Intensive Applications_. O'Reilly Media, 2026.

Linux kernel documentation. _Control Group v2_ (cpu.max, memory.max, io.max,
memory.reclaim). https://docs.kernel.org/admin-guide/cgroup-v2.html

Linux kernel documentation. _dm-delay_. https://docs.kernel.org/admin-guide/device-mapper/delay.html

Linux man pages. _tc-netem(8): network emulator_. https://man7.org/linux/man-pages/man8/tc-netem.8.html

MinIO. _MinIO object storage documentation: deployment architecture and erasure coding_.
https://min.io/docs

MinIO. _Warp: S3 benchmarking tool_. https://github.com/minio/warp

Oracle Linux blog. _Emulating disk latency with dm-delay_.
https://blogs.oracle.com/linux/emulating-disk-latency-with-dm-delay

SeaweedFS. _SeaweedFS documentation: architecture, replication and erasure coding_.
https://github.com/seaweedfs/seaweedfs

Showmetech. _Review: HD 1TB Western Digital Blue WD10EZEX_ (8.9 ms average seek, 4.2 ms
average latency, 150 MB/s). https://www.showmetech.com.br/review-hd-1tb-western-digital-blue-wd10ezex/

StorageReview. _HGST Travelstar 7K1000 review_ (about 128 random 4K IOPS).
https://www.storagereview.com/hgst_travelstar_7k1000_review

StorageReview. _Seagate Barracuda 7200.8 review_ (69.8 MB/s outer, 39.9 MB/s inner zone).
https://storagereview.com/review/seagate-barracuda-7200-8

Storage Disk Prices. _SMR drive ZFS performance: why shingled drives destroy your pool_.
https://storagediskprices.com/smr-drive-zfs-performance/
