#set page(
  header: [ _Marc Fuschino_ #h(1fr) MGL870 ],
  footer: [
    #context [ Page #counter(page).display() #h(1fr) ]
  ]
)
#set heading(numbering: "1.1.1.1")
#set par(justify: true)
#linebreak() #linebreak() #linebreak() #linebreak()
#align(center)[
  #set text(26pt)
  *Distributed Object Storage on Bad Hardware*
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

// RESULTS: written at the end.

= Context and Questions

Hardware is expensive, so many people build storage from old, mismatched machines:
a fast NVMe box next to an old laptop with a spinning disk and a weak link. Three S3
systems target this kind of use, each with a different design idea:

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

We never rank the systems. Each system is measured on identical nodes, then on
degraded nodes, and we report how much it loses.

= Background: Object Storage and S3

*What object storage is.* A classic file system (ext4, NTFS, APFS) stores files in a
tree of folders. A program can open a file, read a few bytes in the middle, change
them, append, rename, lock. Object storage is simpler. It stores *objects*: a blob of
bytes plus a little metadata, identified by a *key* (a name such as
`photos/2026/cat.jpg`) inside a *bucket* (a top level container). There is no real
folder tree: the slashes in a key are just characters. An object is written and read
as a whole; to change one byte, you upload the whole object again.

*The S3 API.* S3 is the object storage service of Amazon Web Services, and its HTTP
interface became the common language of object storage (AWS, S3 API reference). The
three systems we test all speak it. The main operations are:

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
)

Each request is signed with an access key and a secret key, so the server knows who
sends it. Large objects can be uploaded in parts (multipart upload).

*Why it fits a cluster.* Because objects are independent and written as a whole, a
system can spread them over many machines and keep several copies, without the hard
problems of a shared file system (locks, partial updates). Each node of the cluster
can act as a *gateway*: it receives S3 requests, finds which nodes hold the object,
and talks to them. Data is protected either by *replication* (several full copies on
different nodes) or by *erasure coding* (the object is cut into data pieces plus
parity pieces, so that any missing piece can be rebuilt from the others, like RAID).

= Test Bench

== Clusters

Each system runs as a cluster of three nodes, one container per node, all on one
machine.

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
)

We keep default settings. Tuning one system more than another would change the
result more than the hardware does. MinIO no longer publishes container images and
its repository is archived, so we build it from its last release tag.

The systems do not protect data the same way (full copies against erasure coding).
This is one more reason to compare each system only with itself.

== How a node is made slow

We do not use real slow machines. We limit each container with Linux kernel
features, which makes every condition exactly reproducible:

- *CPU*: cgroup `cpu.max`. Memory is fixed at 1 GB per node.
- *Disk*: cgroup `io.max`, which caps bytes per second and operations per second
  (IOPS) for reads and writes (Linux kernel docs, cgroup v2).
- *Network*: `tc netem` caps the outgoing rate and adds delay; incoming traffic is
  capped at the same rate (tc-netem man page).

A nominal node has 1 CPU, 25 MiB/s read, 40 MiB/s write, 800 read IOPS, 600 write
IOPS, and a 1 Gbit/s link with 1 ms delay.

*The total budget of the cluster never changes.* When a node is made $k$ times
slower, it gets $1 slash k$ of the nominal resources, and what it loses is shared
between the healthy nodes. Only the split changes. (Delay is the exception: a slow
node gets $k$ times the nominal delay.)

This makes Q3 easy to read, with two numbers defined precisely in the Method
section:

- the *ratio* $r$: the throughput of the degraded cluster divided by the throughput
  of the same cluster with identical nodes. $r = 1$ means no loss; $r = 0.25$ means the
  cluster keeps a quarter of its throughput;
- the *index* $W$, which tells which model the cluster follows.

If the cluster ran at the speed of its *average* node, $r$ would stay at 1, since the
total budget is the same. If it ran at the speed of its *weakest* node, $r$ would drop
to $1 slash k$ (for example 0.2 when one node is 5 times slower). $W$ places the
measured $r$ between these two cases.

== Load and measurements

The load comes from warp, an S3 benchmark tool (MinIO, warp). warp runs in its own
container with 2 CPU, outside the cluster budget. It keeps 8 requests in flight at
all times (8 parallel workers) and sends them to the three nodes in turn: node 1,
node 2, node 3, node 1, and so on. This is called *round robin*. It is what a simple
setup does in practice, for example *DNS round robin*, where one name (such as
`s3.home.lan`) points to the three addresses and each client picks the next one. The
client therefore never avoids a slow node by itself. warp records every request:
start, end, size, node and error.

== Software stack

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
    [cgroup v2, tc], [Kernel features that make a node slow.],
    [warp], [S3 load generator.],
    [Helper image], [Alpine Linux with fio, stress-ng, iperf3 and Python: calibration
      probes, resource sampler, a second S3 client (boto3) and data checks.],
    [Python and uv], [Analysis and figures (matplotlib) on the laptop. uv installs the
      libraries each script needs (Astral, uv).],
  ),
  caption: [Layers of the bench],
)

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

*Repeatability.* We ran each system five times on identical nodes. Results varied by
less than 5 % between runs, and the load was spread evenly over the nodes (within
7 %). SeaweedFS writes were the exception: they come in bursts while buffered data is
flushed to disk. Longer write runs (60 s) reduce this.

*Load generator.* warp is made by MinIO, one of the vendors we test, so we checked it
instead of trusting it. We read back the objects warp had written and compared their
SHA256 hashes. *warp versions 1.1.0 to 1.3.1 send almost identical objects*: with 8
workers, 60 objects written by versions 1.1.6 to 1.3.1 contained only 5 to 7 different
ones, and with a single worker all 52 objects written by v1.3.1 were identical. So each worker sends the same bytes
again and again. The random data generator itself did not change between v1.0.8 and
v1.1.0, so the regression comes from another part of the code; we did not find which. Garage removes
duplicate 1 MiB blocks, so it stored almost nothing and its writes looked twice as
fast as they are (48.5 instead of 24.1 MiB/s). MinIO and SeaweedFS do not remove
duplicates and were not affected. We use warp v1.0.8, which sends 100 different
objects out of 100.

A second client written with boto3 (AWS) agrees with warp within 10 % on Garage and
MinIO, once both send the same kind of request. Recent boto3 versions skip the
payload checksum by default, and this alone made Garage, which is limited by its CPU,
look 2.5 times faster. On SeaweedFS the two clients still differ by 30 to 47 %; we did
not find why. Our ratios always compare runs made with the same client, so they are
less affected than absolute numbers. Finally, the client never used more than a
quarter of its CPU, so it never limited the results.

= Method

== Sweeps

We start from a reference point: one node out of three, all resources 5 times
slower, 1 MiB objects. Then we change one thing at a time:

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
)

Each condition is measured twice: once for writes and once for reads.

- *Write run*: for 60 s, the client uploads new objects (PUT) as fast as the cluster
  accepts them.
- *Read run*: the client first uploads about 200 MiB of objects, then for 30 s
  downloads them again and again (GET). Only those 30 s are measured.

Writes get a longer run because some systems write in bursts (see SeaweedFS above).
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

We model such a disk for node 1 only, by stacking Linux block devices:

+ a sparse file on the VM disk, used as a block device (loop device);
+ *dm-delay* on top, which delays every read by 13 ms, every write by 2 ms (the
  write lands in the disk cache) and every flush by 20 ms (Linux kernel docs,
  dm-delay; Oracle Linux blog);
+ `io.max` on that device, capped at 150 reads and 200 writes per second: dm-delay
  delays operations in parallel, while a disk has a single head;
+ an ext4 file system, mounted as the volume of node 1.

The CPU and network of node 1 stay nominal. We checked the model with fio: 77 random
reads per second at 13 ms with one request at a time (a real 7200 rpm disk: 75 to 80),
149 per second with 16 requests in flight, and 38 synchronous writes per second.

Reads of recently written data would come from memory and never reach this disk.
During the read runs of this experiment, we therefore ask the kernel every second to
drop the page cache of each node (cgroup `memory.reclaim`), for the homogeneous
reference as well. Each condition is compared with identical nodes measured the same
way.

== How the numbers are computed

*Throughput of one run ($T_i$).* $T_i$ is the average speed seen by the client during
run $i$, in MiB/s: the amount of data successfully transferred, divided by the time
it took. warp logs every request; we ignore the first 3 s (warm up) and failed
requests. With $b_q$ the size of request $q$, $cal(R)_i$ the set of requests kept, and
$Delta t_i$ the measured duration:
$ T_i = (sum_(q in cal(R)_i) b_q) / (Delta t_i) $

*One condition ($T(c)$).* A condition $c$ fixes everything we control: system,
operation (PUT or GET), object size, which resource is slowed down, by how much, on
how many nodes, and which nodes the client talks to. It is run 3 times, and we keep
the middle value (the median), which ignores one unusually fast or slow run:
$ T(c) = "median"(T_1, T_2, T_3) $

*Ratio ($r$).* $c_0$ is the same condition with identical nodes: everything equal,
only the slowdown removed. The ratio is the share of throughput the cluster keeps:
$ r(c) = T(c) / T(c_0) $
For example, $r = 0.33$ means the cluster keeps a third of its speed. Because the total
budget is constant, $r$ can be above 1: the healthy nodes have more resources than in
the homogeneous cluster.

*Slowdown factor ($k$, written 2x, 5x, 10x).* The slow node gets $1 slash k$ of the
nominal CPU, disk and network: at 5x it has 0.2 CPU, 5 MiB/s of disk reads, 200 Mbit/s
of network, and 5 ms of delay instead of 1 ms.

*Index ($W$).* $W$ answers Q3 with one number: where does $r$ sit between "follows
the average node" ($r = 1$) and "follows the weakest node" ($r = 1 slash k$)?
$ W = (1 - r) / (1 - 1 slash k) $
$W = 0$: no loss, the cluster follows its average node. $W = 1$: the cluster is as slow
as its weakest node. $W$ between 0 and 1: in between. $W > 1$: even slower than its
weakest node. Example: at 5x, $r = 0.33$ gives $W = 0.67 slash 0.8 = 0.84$.

*Latency percentiles (p50, p99).* The latency of a request is the time between sending
it and receiving the full answer. Sort the latencies of all requests of a run: the
*p50* (median) is the value in the middle, so half of the requests were faster; the
*p99* is the value below which 99 % of the requests fall, so it describes the slowest
1 % (the "tail"). Users notice the tail: one page that loads slowly is enough. As for
throughput, we keep the median of the 3 runs.

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
  done.
+ Keep reading for 60 s, then check every object one last time.

The client only talks to the two nodes that are never killed. This way, a dead
gateway is not counted as a storage failure.

We run three scenarios, twice per system:

- identical nodes, one node killed;
- one slow node (all resources, 5 times slower), and that slow node is killed;
- one slow node, and a healthy node is killed. The slow node must then help rebuild.

A system is reliable here if every object stays readable while a node is dead, and
after the rebuild.

= Results

The 216 sweep runs all finished. The median difference between the three repetitions
of a point is 5 %, and only one request failed in total. In what follows, $r$ is the
median throughput of a condition divided by the median throughput on identical nodes
(same system, same operation, same object size).

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

== Q1 and Q3: the cluster follows its weakest node

@tab-s2 gives the ratio $r$ of each system when one node is 2, 5 or 10 times slower,
and @fig-s2 plots it. With one node 5 times slower, every system loses 61 to 82 % of
its throughput, even though the cluster has the same total resources. A cluster
that followed its average node would lose nothing. One that followed its weakest node
would lose 80 %. Our results are close to the second case: $W$ is 0.76 to 1.02 at 5x,
and 0.89 to 1.03 at 10x.

- MinIO writes follow the weakest node almost exactly ($W$ 1.01 to 1.03).
- Garage and SeaweedFS writes do a bit better at 2x and 5x ($W$ 0.69 to 0.83). For
  Garage, this margin disappears at 10x.
- Slow requests suffer much more than average ones. At 5x, the 99th percentile
  latency is 3 to 10 times higher, and up to 45 times for Garage reads at 10x.

The loss grows step by step with the slowdown. There is no sudden collapse.

#figure(image("../figures/s2_factor.png", width: 100%),
  caption: [S2: throughput compared with identical nodes, as one node gets slower.
  Dashed lines: the two models (average node, weakest node).])<fig-s2>

== S1: which resource matters most

#figure(image("../figures/s1_resource.png", width: 100%),
  caption: [S1: one resource of one node made 5 times slower.])<fig-s1>

It depends on the system and on the operation (@fig-s1):

- *Slow network* hurts all reads ($r$ 0.25 to 0.33): one third of the answers go
  through the slow link.
- *Slow disk* hurts all writes ($r$ 0.18 to 0.24) but not much the reads (MinIO 0.78,
  the others 1.0). Recently written data is read from memory, so the slow disk is not
  used (see Threats).
- *Slow CPU* shows the biggest design differences. SeaweedFS reads do not notice it
  (0.99) and Garage reads barely (0.86), but MinIO loses 70 % of its reads. This fits
  erasure coding, where every node helps rebuild each object, but we did not profile
  it. For writes, slow CPU hurts Garage most (0.26), probably because each node hashes
  and checks every block it stores.

== S3: losing the majority

A second slow node (two out of three) changes almost nothing: $r$ moves by 0.11 at
most (@fig-s3). With one slow node, the cluster already runs at the speed of that
node, so a second one has little left to take. We expected a well designed system to
avoid a single slow node while it still has a healthy majority. The sweeps do not
show this, and the next section explains why.

#figure(image("../figures/s3_nodes.png", width: 100%),
  caption: [S3: number of slow nodes out of three, all resources, 5x.])<fig-s3>

== S4: object size

No object size makes the loss smaller (@fig-s4). Large objects (8 MiB) follow the
weakest node on every system ($W$ 0.94 to 1.05). Small objects (16 KiB) are the worst
case for MinIO reads and for SeaweedFS ($W$ 1.08 to 1.16, worse than the weakest node).
SeaweedFS is designed for many small files, yet it loses 93 % of its small object
writes. Only MinIO small writes lose less ($r$ 0.37).

#figure(image("../figures/s4_size.png", width: 100%),
  caption: [S4: object size at the reference point (one node, all resources, 5x).
  Each ratio uses identical nodes at the same size.])<fig-s4>

== Gateway effect

In the sweeps the client sends one third of its requests to the slow node (round
robin, see Load and measurements). The slow node then answers slowly no matter
what the storage system does inside. To separate the two effects, we ran S2 again
with a client that only talks to the two healthy nodes. Its reference $c_0$ is
also measured with the client on the two healthy nodes, so the ratio only
measures what the slow node costs *inside* the cluster.

#figure(image("../figures/gateway.png", width: 100%),
  caption: [S2 with the client on all three nodes (dotted) and on the two healthy
  nodes only (solid).])<fig-gw>

#figure(
  table(
    columns: (auto, auto, auto, auto),
    inset: 5pt,
    align: (left, right, right, right),
    table.header([*$r$, all nodes → healthy nodes*], [*2x*], [*5x*], [*10x*]),
    [Garage GET], [0.77 → 1.19], [0.33 → 1.12], [0.07 → 1.25],
    [SeaweedFS GET], [0.62 → 1.03], [0.26 → 0.48], [0.13 → 0.24],
    [MinIO GET], [0.66 → 0.99], [0.24 → 0.41], [0.11 → 0.16],
    [Writes, all systems ($W$)], [0.70 to 1.03], [0.85 to 1.01], [0.85 to 1.00],
  ),
  caption: [Ratio $r$ with the client on all nodes, then on the healthy nodes only.],
)<tab-gw>

- *Garage reads* get *faster* than on identical nodes ($r$ 1.12 to 1.25) once the
  client avoids the slow node. Garage reads from the healthy nodes, which received the
  budget of the slow one. All of its read loss in the sweeps came from the gateway.
- *MinIO and SeaweedFS reads* recover at 2x, but still lose at 5x and 10x ($W$ 0.66
  to 0.93): their read path still waits for the slow node. For MinIO this fits erasure
  coding, where 2 of the 3 shards are needed to rebuild an object.
- *Writes* follow the weakest node on all systems, with or without the slow gateway.
  Every write must reach the nodes that store the copies, including the slow one.

So the answer to Q3 depends on the operation: writes follow the weakest node; reads
follow it too unless the client avoids the slow node, and then only Garage really
escapes it.

== An old hard disk in the cluster

Node 1 gets the modelled hard disk; its CPU and network stay nominal. We first found
that some writes looked *faster* with the hard disk (Garage small writes, $r = 1.42$).
The reason was not the disk: the hard disk node has its own file system, while the
other nodes share the file system of the VM disk, with a single journal. We therefore
added a control: the same stack (own file system, loop device, dm-delay) with 0 ms of
delay and the nominal IOPS. The effect of the hard disk alone is $T("hdd") slash T("control")$.

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
which fits its larger loss: it pays for durability at once. (SeaweedFS
  small writes at 1.17 are within the noise of these runs.)

So an old hard disk in a cluster mostly hurts *reads of small files*, which is the
typical load of a home server (documents, thumbnails, backups made of many small
files).

== Q2: node kill and rebuild

We ran 18 campaigns: 3 systems, 3 scenarios, 2 repetitions each.

*No data was lost.* In all 18 campaigns, all 500 objects were readable with one node
dead, and again after the rebuild, with the right SHA256.

#figure(
  table(
    columns: (auto, auto, auto, auto, auto),
    inset: 5pt,
    align: (left, left, right, right, right),
    table.header([*System*], [*Scenario*], [*Longest stall*], [*Rebuild*], [*Speed during rebuild*]),
    [Garage], [identical nodes], [0 s, 82 s], [652 to 663 s], [1.00 to 1.03],
    [Garage], [slow node killed], [0 s, 0 s], [678 to 690 s], [0.93 to 1.02],
    [Garage], [healthy node killed], [0 s, 68 s], [632 to 656 s], [0.98 to 1.02],
    [MinIO], [identical nodes], [0 s, 0 s], [38 s], [0.88 to 0.93],
    [MinIO], [slow node killed], [0 s, 0 s], [53 to 54 s], [1.54 to 1.70],
    [MinIO], [healthy node killed], [0 s, 41 s], [59 to 64 s], [0.81],
    [SeaweedFS], [identical nodes], [0 s, 0 s], [73 to 74 s], [0.91 to 0.94],
    [SeaweedFS], [slow node killed], [20 s, 0 s], [70 to 72 s], [2.19 to 2.44],
    [SeaweedFS], [healthy node killed], [50 s, 30 s], [67 to 88 s], [0.88 to 1.00],
  ),
  caption: [Node kill campaigns (2 repetitions per line). Stall: the longest time
  without a single answer to the client while the node is dead. Rebuild: from the
  replacement to the moment the new node holds its data. Speed during rebuild: median
  read throughput divided by the throughput before the kill.],
)<tab-kill>

#figure(image("../figures/kill_timelines.png", width: 100%),
  caption: [Read throughput seen by the client around a node kill (first repetition
  of each scenario).])<fig-kill>

*The service can freeze after a node dies.* In 6 of the 18 campaigns, the client got
no answer at all for 20 to 82 s right after the kill, although it only talks to the
surviving nodes (@tab-kill). The surviving nodes keep waiting for the dead one until
a timeout. A `docker kill` behaves like a power cut: the node does not close its
connections, its packets are simply lost. Whether a freeze happens depends on which
requests were in flight at that moment, so it varies between repetitions. It happened
on all three systems, most often when a *healthy* node died next to a slow one (4 of
6 campaigns).

*Rebuild time differs by a factor of 10.* MinIO and SeaweedFS rebuild 500 MiB in
about one minute. Garage takes about 11 minutes. Looking at the bytes on the new node
over time explains why: for about 10 minutes nothing arrives, then everything is copied
in about 40 s. Garage only learns which blocks the new node must hold when its
metadata tables run a full synchronisation, which happens every 10 minutes for tables
split between nodes (`ANTI_ENTROPY_INTERVAL`, Garage source code, `sharded.rs`). The
rebuild speed settings do not help: with 4 resync workers instead of 1 and no pause
between blocks (default: the worker sleeps twice as long as it works, `resync.rs`),
the rebuild still took 616 to 672 s. The client does not notice the Garage rebuild at
all (0.93 to 1.03), while MinIO and SeaweedFS lose up to 19 % and 12 % of their read
speed during their faster rebuild.

// RESULTS: Garage with an immediate `garage repair tables` after the replacement.

*Losing the slow node makes the cluster faster.* When the slow node dies, MinIO and
SeaweedFS read 1.7 to 3.5 times faster than before, while the node is dead
(@fig-kill). They were waiting for it. The replacement node gets the same limits, so
speed drops back once it rejoins. Garage reads barely change, because its reads did
not depend on the slow node in the first place (see the gateway effect).

= Threats to Validity

*One machine.* All nodes share one machine and one disk. Our limits create the
imbalance and we checked them, but other shared parts (memory bandwidth, the
virtual machine) are not controlled.

*Memory of the laptop.* The laptop has 8 GB and gave 6 GB to the virtual machine for
the main sweeps. macOS compressed or swapped part of that memory, which adds noise.
We then reduced the virtual machine to 4 GB (swap reads dropped from about 1700 to
under 100 per minute) and ran the homogeneous reference and the reference point
again. Throughput moved by 10 % at most and the ratios by 0.06 at most, so the
conclusions hold. Random order also spreads such noise over all conditions.

*Page cache.* Recently written data is often read from memory, not from the slow
disk. The 1 GB memory limit per node bounds this, but read results say more about CPU
and network than about disks.

*Slow disk model.* In the sweeps, `io.max` caps throughput and IOPS but adds no fixed
delay to each operation, so the "slow disk" there behaves like a busy SSD rather than
an old hard disk. The separate hard disk experiment adds that delay, but it is still a
model: no seek that depends on the distance, no SMR effects (shingled disks whose
writes collapse once their cache is full, iXsystems; Storage Disk Prices).

*Different designs.* The systems protect data differently, and SeaweedFS elects a
master leader (we record which node it is for each run). Our conclusions are about
design choices in this setting, not a verdict on products.

*Load generator.* We had to use an older warp, and the check with a second client is
not conclusive for SeaweedFS.

*End of rebuild.* "Done" means the bytes are back on the new node. It does not prove
every internal structure is repaired. The final data check covers what users see.

= Conclusion

// RESULTS

= References

#set par(hanging-indent: 1.5em)

Beaver, D., Kumar, S., Li, H. C., Sobel, J., Vajgel, P. _Finding a needle in Haystack:
Facebook's photo storage_. USENIX OSDI, 2010.

Amazon Web Services. _Amazon S3 API Reference_.
https://docs.aws.amazon.com/AmazonS3/latest/API/Welcome.html

Backblaze. _Backblaze Drive Stats for Q1 2026_.
https://www.backblaze.com/blog/backblaze-drive-stats-for-q1-2026/

Deuxfleurs. _Garage documentation: design goals and internals_. https://garagehq.deuxfleurs.fr

Gunawi, H. S. et al. _Fail-Slow at Scale: Evidence of Hardware Performance Faults in Large
Production Systems_. USENIX FAST, 2018.
https://people.cs.vt.edu/huaicheng/s/fast18-failslow-slides.pdf

abiosoft and contributors. _Colima: container runtimes on macOS with minimal setup_.
https://github.com/abiosoft/colima

Docker Inc. _Docker Engine and Docker Compose documentation_. https://docs.docker.com

Linux kernel documentation. _Control Group v2_ (cpu.max, memory.max, io.max,
memory.reclaim). https://docs.kernel.org/admin-guide/cgroup-v2.html

Linux kernel documentation. _dm-delay_. https://docs.kernel.org/admin-guide/device-mapper/delay.html

Linux kernel documentation. _Null block device driver_. https://docs.kernel.org/6.11/block/null_blk.html

Oracle Linux blog. _Emulating disk latency with dm-delay_.
https://blogs.oracle.com/linux/emulating-disk-latency-with-dm-delay

Linux man pages. _tc-netem(8): network emulator_. https://man7.org/linux/man-pages/man8/tc-netem.8.html

Axboe, J. _fio: flexible I/O tester_. https://github.com/axboe/fio

King, C. I. _stress-ng_. https://github.com/ColinIanKing/stress-ng

ESnet. _iperf3_. https://github.com/esnet/iperf

Amazon Web Services. _boto3, AWS SDK for Python_. https://github.com/boto/boto3

Astral. _uv: Python package and project manager_. https://github.com/astral-sh/uv

Hunter, J. D. _Matplotlib: A 2D Graphics Environment_. Computing in Science and Engineering,
9(3), 2007.

Showmetech. _Review: HD 1TB Western Digital Blue WD10EZEX_ (8.9 ms average seek, 4.2 ms
average latency, 150 MB/s). https://www.showmetech.com.br/review-hd-1tb-western-digital-blue-wd10ezex/

StorageReview. _HGST Travelstar 7K1000 review_ (about 128 random 4K IOPS).
https://www.storagereview.com/hgst_travelstar_7k1000_review

StorageReview. _Seagate Barracuda 7200.8 review_ (69.8 MB/s outer, 39.9 MB/s inner zone).
https://storagereview.com/review/seagate-barracuda-7200-8

iXsystems. _WD Red SMR drive compatibility with ZFS_. https://www.truenas.com/docs/hardware/notices/wdsmr

Storage Disk Prices. _SMR drive ZFS performance: why shingled drives destroy your pool_.
https://storagediskprices.com/smr-drive-zfs-performance/

Kleppmann, M., Riccomini, C. _Designing Data-Intensive Applications_. O'Reilly Media, 2026.

MinIO. _MinIO object storage documentation: deployment architecture and erasure coding_.
https://min.io/docs

MinIO. _Warp: S3 benchmarking tool_. https://github.com/minio/warp

SeaweedFS. _SeaweedFS documentation: architecture, replication and erasure coding_.
https://github.com/seaweedfs/seaweedfs
