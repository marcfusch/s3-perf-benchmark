// Seminar slides. Compile from bench/report: typst compile --root .. slides.typ
#set page(width: 25.4cm, height: 14.29cm, margin: (x: 1.6cm, y: 1.2cm),
  footer: context [#set text(9pt, fill: luma(110)); Marc Fuschino, MGL870 #h(1fr) #counter(page).display()])
#set text(size: 17pt)
#set par(justify: false)
#show heading.where(level: 1): it => { pagebreak(weak: true); text(24pt, weight: "bold", it.body); v(0.4em) }

#let slide(title, body) = [= #title
#body]
#let note(body) = text(13pt, fill: luma(90), body)
#let big(body) = text(26pt, weight: "bold", body)

// 1
#align(center + horizon)[
  #text(30pt, weight: "bold")[Distributed Object Storage on Bad Hardware]
  #v(0.6em)
  #text(18pt)[Garage, MinIO and SeaweedFS on mismatched nodes]
  #v(1.2em)
  #text(15pt)[Marc Fuschino, MGL870]
]

#slide[The problem][
  - Hardware got expensive: an 8 TB SSD went from about 200 to 360 dollars in a year.
  - So home and small clusters are built from *old, mismatched machines*: a fast
    NVMe box next to an old laptop with a hard disk and a weak link.
  - People still want storage that keeps working when a machine dies.
  #v(0.5em)
  Benchmarks test storage systems on *identical* machines. \
  That is the one case that does not happen here.
]

#slide[Three systems, three design ideas][
  #table(columns: (auto, 1fr), inset: 8pt, stroke: none,
    [*Garage*], [cheap, mismatched nodes, slow links],
    [*MinIO*], [identical machines in a datacenter, erasure coding],
    [*SeaweedFS*], [many small files, central master for metadata],
  )
  #v(0.5em)
  All three speak *S3*: objects (blobs + key) in buckets, over HTTP. \
  PUT = upload a whole object, GET = download it.
]

#slide[Questions][
  *Q1.* How much does each system lose when nodes are not identical?

  *Q2.* How long does a rebuild take after a node dies, and how slow is the service meanwhile?

  *Q3.* Does the cluster run at the speed of its *average* node, or of its *weakest* node?

  #v(0.6em)
  #note[We never rank systems: each one is compared with itself on identical nodes.]
]

#slide[The bench][
  - 3 nodes per system, one container each, on one machine (Linux VM, cgroup v2).
  - A node is made $k$ times slower with kernel limits: CPU (`cpu.max`), disk
    (`io.max`), network (`tc netem`).
  - *The total budget never changes*: what the slow node loses goes to the others.
  - Load: warp, 8 parallel requests, round robin over the nodes.
  #v(0.4em)
  $ r = T("degraded") / T("identical nodes") #h(2em) W = (1 - r) / (1 - 1 slash k) $
  #note[$W = 0$: follows the average node. $W = 1$: follows the weakest node.]
]

#slide[First, check the bench: warp was lying][
  warp (made by MinIO) versions 1.1.0 to 1.3.1 send *almost identical objects*: \
  one distinct object per worker.
  #v(0.4em)
  Garage removes duplicate blocks, so it stored almost nothing:
  #align(center, big[Garage writes looked 2x faster (48.5 vs 24.1 MiB/s)])
  #v(0.4em)
  Fix: pin warp v1.0.8, and check that every object is distinct (100/100). \
  #note[Also checked: limits within 5 % (fio, iperf3, stress-ng), run to run noise below 5 %.]
]

#slide[Q1 and Q3: the cluster follows its weakest node][
  #align(center, image("../figures/s2_factor.png", height: 72%))
  #note[One node of three made $k$ times slower, total budget unchanged. At 5x every system loses 61 to 82 %.]
]

#slide[Which resource hurts][
  #align(center, image("../figures/s1_resource.png", height: 72%))
  #note[Slow network hurts all reads, slow disk all writes. Slow CPU splits the designs: SeaweedFS reads 0.99, MinIO reads 0.30.]
]

#slide[But who is really slow: the gateway effect][
  #align(center, image("../figures/gateway.png", height: 70%))
  #note[Solid: the client avoids the slow node. Garage reads get *faster* than on identical nodes. Writes always follow the weakest node.]
]

#slide[An old hard disk in the cluster][
  // RESULTS: HDD sweep (13 ms per access, 150 IOPS)
  - Modelled consumer HDD: 13 ms per random read, about 150 IOPS, write cache.
  - Reads: small objects collapse (MinIO keeps 1 %, Garage 16 %, SeaweedFS 24 %).
  - Writes barely notice it, thanks to caches, except MinIO, which syncs to disk.
]

#slide[Q2: a node dies][
  #align(center, image("../figures/kill_timelines.png", height: 74%))
]

#slide[Q2: what the user sees][
  - *No data lost*: 500/500 objects readable in all 18 campaigns.
  - *But the service can freeze*: no answer at all for 20 to 82 s after the kill,
    in 6 of 18 campaigns, on all three systems.
  - *Rebuild*: about 1 min for MinIO and SeaweedFS, 11 min for Garage, which
    rebuilds slowly on purpose and stays invisible to the client.
  - Killing the *slow* node makes MinIO and SeaweedFS 1.7 to 3.5x faster.
  // RESULTS: Garage with a faster resync
]

#slide[Takeaways][
  + A cluster of mismatched nodes runs close to the speed of its *weakest* node,
    even with the same total resources.
  + Writes always pay for the slow node. Reads only escape it if the system routes
    around it (Garage) *and* the client does not use it as a gateway.
  + An old hard disk kills small object reads.
  + Losing a node loses no data, but can freeze the service for a minute.
  #v(0.4em)
  #note[Check a design assumption against the hardware you own, before choosing a system.]
]

#slide[Limits][
  - One machine: the imbalance comes from kernel limits, not real hardware.
  - The laptop swapped part of the VM memory; rerunning with less memory moved ratios by 0.06 at most.
  - Default settings only (plus one labelled Garage tuning test).
  - The second client disagrees with warp on SeaweedFS (30 to 47 %), still unexplained.
  #v(0.6em)
  #align(center)[Code and raw data: #link("https://github.com/marcfusch/s3-perf-benchmark")]
]
