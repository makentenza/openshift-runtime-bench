# Metric catalog

Every benchmark emits results as single stdout lines of the form `RESULT_JSON {...}` with this
envelope (built by `image/scripts/common.sh: emit_result`):

```json
{"suite": "cpu", "test": "sysbench-cpu", "runtime": "kata", "node": "worker-1",
 "timestamp": "2026-07-04T10:15:00Z", "iteration": 1,
 "parameters": {"threads": 2, "duration": 30},
 "metrics": {"events_per_sec": 1234.5},
 "units": {"events_per_sec": "events/s"}}
```

The runner collects these lines from Job logs into
`results/<label>-<runtime>-<YYYYmmdd-HHMMSS>/<suite>.jsonl`. `suite` is one of
`cpu | memory | disk | network | app | startup | overhead | env`. `metrics` keys are numeric;
`units` maps each metric name to its unit; `parameters` records the knobs that produced the
number (threads, block size, target, io_mode, ...) — always check `parameters` before comparing
two results.

Interpretation baseline for the "why it matters" column: under kata each pod runs in a QEMU/KVM
guest. On a cloud instance that guest is an **L2** VM (host hypervisor = L0, the node's VM = L1,
kata's guest = L2 — nested virtualization). Pure user-space compute runs at native speed in the
guest; anything that triggers a **VM exit** (privileged instruction, I/O, some interrupts) is
where overhead concentrates, and under nested virt every L2 exit must round-trip through L0 to be
reflected to L1 — the *vmexit amplification* that makes exit-heavy workloads the sensitive ones.

## cpu suite (`run-cpu.sh` → `cpu.jsonl`)

| Test | Tool | Metrics (units) | Why it matters for kata / nested virt |
|---|---|---|---|
| `sysbench-cpu` | sysbench | prime-computation events/s (`events/s`), avg latency (`ms`) | Pure user-space integer compute: no syscalls, no exits. The guest executes it natively, so kata ≈ crun is the *expected* result. This is the control test — a significant delta here means something outside the runtime is wrong (CPU steal, frequency scaling, mis-pinned vCPUs), and it taints every other suite. |
| `stress-ng-matrix` | stress-ng | matrix-product bogo-ops/s (`bogo-ops/s`) | Cache- and TLB-pressure-heavy FP kernel. Guest memory accesses translate through **two-dimensional paging** (guest page tables + EPT), and under nested virt the EPT itself is composed/shadowed by L0 — a TLB miss in L2 can cost several times the page-walk memory dereferences of bare metal. TLB-miss-heavy loads are where nested paging shows up even in "pure compute". |
| `stress-ng-switch` | stress-ng | context switches/s (`switches/s`) | Context switches between guest processes are handled entirely inside the guest kernel — no exit per switch. But the surrounding machinery (timer interrupts, rescheduling IPIs between vCPUs) *is* intercepted, and each intercepted event pays the L2→L0→L1 amplified exit cost. High switch rates therefore degrade more under nested virt than raw compute does. |
| `stress-ng-syscall` | stress-ng | syscalls/s (`syscalls/s`) | The key architectural point: a syscall inside a kata pod lands in the **guest kernel** — it is a native ring transition, not a VM exit. Expect near-parity with crun. If this test shows a large delta, suspect vCPU contention or steal rather than syscall cost. Contrast with the disk/network suites, where the syscall's *backend* (I/O) does exit. |
| `stress-ng-fork` | stress-ng | forks/s (`forks/s`) | Process creation/teardown churns page tables (COW, mmap/munmap) and triggers TLB shootdowns across vCPUs. Every guest page-table update interacts with the second translation stage, and shootdown IPIs are intercepted — under nested virt both effects compound, making fork rate one of the more sensitive "CPU" metrics. |

## memory suite (`run-memory.sh` → `memory.jsonl`)

| Test | Tool | Metrics (units) | Why it matters for kata / nested virt |
|---|---|---|---|
| `sysbench-mem-*` (sequential and random × read and write; exact test names in the JSONL, variant recorded in `parameters`) | sysbench | throughput (`MiB/s`) | Raw guest-RAM bandwidth. Sequential access is TLB-friendly and should be near-native. Random access at large working sets misses the TLB constantly, and each miss pays the nested EPT walk — the seq-vs-random *gap* widening under kata is the fingerprint of two-dimensional paging cost. |
| `stress-ng-stream` | stress-ng | STREAM-like memory bandwidth (`MB/s`) | Classic add/copy/scale/triad bandwidth kernel. Sensitive to vCPU→pCPU placement and NUMA: the kata guest's vCPUs are host threads that the node scheduler may migrate, so bandwidth variance (not just the mean) is informative. Compare stdev across runtimes, not only averages. |
| `stress-ng-fault` | stress-ng | page faults/s (`faults/s`) | Minor faults are resolved inside the guest kernel, but *first-touch* of a page also triggers an EPT violation that the hypervisor must resolve (allocate/map host memory) — under nested virt this is a doubly-indirected fault path. Fault-heavy behavior (allocators, JIT warmup, mmap-churning apps) sees this cost; steady-state resident workloads do not. |

## disk suite (`run-disk.sh` → `disk.jsonl`)

Each fio test runs against **three storage targets**, distinguishable in `parameters`
(`target_mode`: `fs` for emptyDir and filesystem PVC, `block` for the block PVC):

- **emptyDir** and **filesystem PVC** — under crun: plain node filesystem (overlay/ext4/xfs).
  Under kata: guest VFS → **virtiofs** (FUSE-over-virtio) → `virtiofsd` on the host → node
  filesystem. Every I/O crosses the VM boundary *and* a host userspace daemon.
- **block PVC** (`volumeDevices`, device `/dev/bench-block`) — under kata the volume is attached
  as a **virtio-blk** disk: the guest kernel talks to a paravirtual block device, no host FUSE
  daemon in the path. This is the "thin" storage path and the fair comparison for raw device
  performance.

The three variants exist precisely to separate "kata is slower at storage" (rarely the whole
story) from "the virtiofs path is expensive" (usually the real finding).

| Test | Tool | Metrics (units) | Why it matters for kata / nested virt |
|---|---|---|---|
| `fio-randread-4k` | fio | IOPS (`iops`), bandwidth (`MiB/s`), completion latency mean/p99 (`us`) | Small random reads maximize the *per-I/O* fixed cost: each request is a virtio kick (VM exit) plus, on the fs path, a virtiofs FUSE round-trip through `virtiofsd`. Nothing amortizes it. Expect the largest relative kata deltas of the whole repo on the fs targets, and a much smaller one on virtio-blk. |
| `fio-randwrite-4k` | fio | IOPS (`iops`), bandwidth (`MiB/s`), latency mean/p99 (`us`) | Same per-I/O amplification as randread plus write-path semantics: on virtiofs, writes funnel through the host daemon and host page cache, so *where caching happens* differs between runtimes. Check `parameters.io_mode` — buffered results measure a different thing than O_DIRECT results. |
| `fio-seqread-1m` | fio | bandwidth (`MiB/s`) | Large sequential requests amortize the per-I/O exit cost over 1 MiB of payload — the delta should shrink dramatically vs 4k. If seq bandwidth is *identical* across runtimes, suspect you're hitting the cloud disk's throughput cap rather than measuring the runtime (see methodology). |
| `fio-seqwrite-1m` | fio | bandwidth (`MiB/s`) | As seq read, for the write path. Also stresses `virtiofsd`'s ability to keep the pipe full — a single host daemon thread pool sits between the guest and the disk on fs targets. |
| `fio-randrw-70-30-4k` | fio | read+write IOPS (`iops`), latencies (`us`) | The database-shaped mix. Read/write interleaving defeats simple queue-depth amortization and approximates what an OLTP-ish pod actually experiences under kata. |
| `fio-fsync-4k` | fio | fsync/fdatasync latency mean/p99 (`us`) | **The etcd-critical metric.** `fdatasync` must actually reach stable storage: under kata the flush traverses guest kernel → virtio → (virtiofsd on fs targets) → host kernel → device, and only then completes back through the same stack. Consensus systems (etcd, databases with WAL) are gated by p99 fsync latency, not IOPS — if you're deciding whether control-plane-adjacent workloads can run under kata, this row is the one to read. |

## network suite (`run-network.sh` → `network.jsonl`)

Both runtimes share the same CNI/OVN plumbing up to the pod boundary (veth pair on the node). Kata
adds a **virtio-net** device into the guest: packets cross the VM boundary via the virtio ring
(vhost or userspace backend), adding copies and exit/notification costs per packet batch. Clients
target the server **pod IP** directly — no Service object — so kube-proxy/OVN service DNAT never
enters the measured path.

| Test | Tool | Metrics (units) | Why it matters for kata / nested virt |
|---|---|---|---|
| `iperf3-tcp-p1` | iperf3 | throughput (`Gbit/s`), retransmits (`count`) | Single-stream TCP is latency- and per-packet-cost-sensitive: one flow can't hide the extra virtio-net hop behind parallelism. Retransmits distinguish "slower path" from "lossy path". |
| `iperf3-tcp-p4` | iperf3 | aggregate throughput (`Gbit/s`), retransmits (`count`) | Four parallel streams amortize per-packet costs and expose the *aggregate* ceiling. If p4 recovers most of the p1 gap, the overhead is per-flow/latency-shaped; if not, the virtio backend or instance NIC cap is the bottleneck. |
| `iperf3-tcp-reverse` | iperf3 | throughput (`Gbit/s`) | Server→client direction. Virtio TX and RX paths are asymmetric — guest-bound (RX) traffic requires the host to inject the data and notify the guest (interrupt injection is itself exit-mediated under nesting), so reverse mode often degrades differently than forward. |
| `iperf3-udp-1g` | iperf3 | throughput (`Mbit/s`), jitter (`ms`), loss (`%`) | Fixed-rate UDP at 1 Gbit/s. No TCP aggregation, GSO benefits, or retransmission masking — per-packet cost shows up directly as **loss and jitter**. Loss at a rate the crun pod sustains cleanly is a clear virtio-path signal. (The offered rate is a parameter; see methodology for why UDP numbers need care.) |
| `qperf-tcp-lat` | qperf | TCP round-trip latency (`us`) | Small-message RTT is the purest measure of *added per-packet latency*: every message pays the full guest→host→wire→host→guest path with nothing to amortize. This is typically the **largest relative regression** in the network suite under kata, and it's the number that matters for chatty RPC workloads — bulk-throughput parity does not imply latency parity. |
| `qperf-tcp-bw` | qperf | TCP bandwidth (`MB/s`) | Independent bandwidth measurement with a different tool and message-size regime — a cross-check on iperf3. If qperf and iperf3 disagree wildly, investigate before publishing either. |

## app suite (`run-app.sh` → `app.jsonl`)

nginx (port 8080) serves static objects; ApacheBench drives it from a client Job on the same node.
This is the end-to-end sanity layer: micro-benchmarks explain *why*, this suite shows *how much*
a real request path actually cares.

| Test | Tool | Metrics (units) | Why it matters for kata / nested virt |
|---|---|---|---|
| `ab-http-small` | ab → nginx | requests/s (`req/s`), latency mean/p50/p99 (`ms`) | Many small requests: connection handling and header parsing are guest-native syscalls (cheap under kata), but every request/response crosses the virtio-net boundary (expensive per-packet). The composite tells you what a latency-sensitive microservice would actually experience — expect the delta to track `qperf-tcp-lat` more than iperf3 throughput. |
| `ab-http-1m` | ab → nginx | requests/s (`req/s`), transfer rate (`MB/s`), latency (`ms`) | 1 MiB responses are throughput-dominated; results should converge toward `iperf3-tcp-p1` behavior. The small-vs-1M pair brackets real workloads between "per-request overhead dominates" and "bulk transfer dominates". |

## Externally measured suites

These cannot be self-measured by the workload — a pod cannot time its own VM boot or see the VMM's
memory from inside the guest. `scripts/measure-startup.sh` and `scripts/measure-overhead.sh` emit
the same RESULT_JSON envelope from the workstation side into `startup.jsonl` / `overhead.jsonl`.

| Test | Source | Metrics (units) | Why it matters for kata / nested virt |
|---|---|---|---|
| `pod-startup` (suite `startup`) | measure-startup.sh | create→Ready wall-clock (`s`) | crun startup = create namespaces/cgroups + exec. Kata startup = spawn QEMU, boot the guest kernel, start `kata-agent`, complete the runtime↔agent handshake, mount the rootfs/volumes via virtiofs, *then* start the container. Nested virt slows guest boot further (exit-heavy early boot). This dominates autoscaling, scale-from-zero, and CI-pod use cases. |
| `pod-deletion` (suite `startup`) | measure-startup.sh | delete→gone wall-clock (`s`) | Kata must tear down the VM (agent shutdown, QEMU exit, virtiofsd cleanup), not just kill a process tree. Matters for high-churn workloads and drain/upgrade timing. The startup pod sets `terminationGracePeriodSeconds: 0` so the measurement isn't a constant. |
| `per-pod-memory` (suite `overhead`) | measure-overhead.sh | incremental node memory per pod (`MB`): `memavailable_delta_mb_per_pod`, `vmm_rss_mb_per_pod`, `conmon_rss_mb_per_pod` | Each kata pod carries a fixed memory floor invisible to the app: QEMU/VMM RSS + guest kernel + `kata-agent` + `virtiofsd`. This floor — not CPU — usually caps kata pod **density** per node. Compare the empirical number against the declared `RuntimeClass` `overhead.podFixed` (what the scheduler accounts for); a gap between them means the scheduler's density math is wrong for your configuration. Measured node-side because part of the VMM cost may sit outside the container cgroup view (see [external-metrics.md](external-metrics.md)). |

## env suite (emitted by every run)

`common.sh: emit_env_info` prints one `suite=env, test=environment` result at the start of every
`run-*.sh` execution:

| Metric | Meaning under crun | Meaning under kata |
|---|---|---|
| `kernel` (uname -r) | The **node's** kernel (RHCOS) | The **guest** kernel shipped with kata — a different version string is direct evidence the workload is inside a VM |
| `nproc` | Node CPUs visible (modulo cgroup limits) | **Guest vCPUs** = kata `default_vcpus` + vCPUs hot-plugged to satisfy the CPU limit |
| `mem_total_kb` (/proc/meminfo MemTotal) | Node total memory | Guest memory = `default_memory` + memory sized from the limit |
| `hypervisor_flag` | Usually `1` on a cloud node (the node itself is a VM) — `0` on bare metal | `1` (the guest sees the hypervisor CPU flag) |

Why it exists: every performance claim in this repo depends on the assertion that the two runs
differ *only* in the runtime boundary. The env record is the in-band proof — check that kernel,
nproc, and MemTotal differ between crun and kata runs in exactly the expected way (guest kernel,
guest-sized CPU/memory) before believing any delta. It also catches mis-sized guests: if `nproc`
inside the kata pod doesn't reflect your `BENCH_CPU`, the comparison is not CPU-fair.

## Metrics only measurable from outside the pod

Node-side process trees (the actual QEMU/virtiofsd processes backing a pod), Prometheus per-pod
and node-level metrics, CPU **steal**, nested-virt verification, kata/CRI-O versions, density
probing, and cloud disk/NIC context are all workstation/cluster-side measurements — see
[external-metrics.md](external-metrics.md) for copy-pasteable commands.
