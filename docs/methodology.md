# Methodology

The question this repo answers: *how much performance do I give up by running a pod under the
Kata runtime instead of crun, on this node, on this provider?* Everything below exists to make
sure the number you get answers that question and not a different one.

## Experimental controls

### Same node, same instance type

Kata-vs-crun deltas are small compared to node-to-node variation (different instance types,
different physical hosts, different NUMA layouts, noisy neighbors). Both runs **must** execute on
the same node — the suite enforces this by pinning every benchmark pod with
`nodeSelector: kubernetes.io/hostname: ${NODE_NAME}`. Never compare a crun run on node A against a
kata run on node B, even if the nodes are "identical" instance types.

For cross-provider work: keep the instance *class* comparable (same vCPU count, same memory,
same disk type tier), and compare **ratios** (kata/crun) rather than absolute numbers — see
[Statistics](#statistics).

### Guaranteed QoS everywhere

Every benchmark and server pod sets `requests == limits` for both CPU (`BENCH_CPU`, default 2)
and memory (`BENCH_MEMORY`, default 4Gi), placing it in the **Guaranteed** QoS class. Reasons:

- Burstable pods get CPU shares, not a defined allocation — throughput then depends on what else
  runs on the node at that moment, which is noise.
- Kata sizes the guest from the pod's resource spec (see below); without limits the guest gets
  only the configuration defaults and the comparison is no longer CPU/memory-fair.
- Guaranteed QoS is a precondition for CPU manager exclusive cores if you enable that (below).

### Pre-pull the image

Apply `manifests/prepull-daemonset.yaml` and wait for it before any measured run. Otherwise the
first Job on each node pays the image pull, which pollutes startup measurements and delays suite
wall-clock unpredictably. The startup suite in particular is meaningless if pull time is included:
`measure-startup.sh` measures create→Ready, and a cold pull can dominate it by an order of
magnitude.

### Iterations and interleaving

- `ITERATIONS` defaults to 3 — treat that as the floor, not the target. Each sub-test runs
  `DURATION` seconds (default 30) per iteration.
- Prefer **interleaved** runs over back-to-back blocks: `crun, kata, crun, kata` rather than
  `crun, crun, kata, kata`. Interleaving exposes drift — thermal effects, another tenant landing
  on the same physical host, background cluster activity — that block ordering silently folds
  into one runtime's numbers.
- Run dirs are timestamped (`results/<label>-<runtime>-<YYYYmmdd-HHMMSS>/`), so multiple runs per
  runtime accumulate side by side; feed any pair to `parse-results.py`.

### Quiesce the node

The target node should run nothing but the benchmark (plus unavoidable DaemonSets). Options:
cordon the node and drain user workloads, or use a dedicated node with a taint. Check with
`oc describe node <node>` (allocated resources, non-terminated pods) before starting. Monitor CPU
steal and node utilization *during* runs — commands in
[external-metrics.md](external-metrics.md#d-prometheus--promql-during-a-run).

## Kata VM sizing — know what the guest actually gets

Kata does not give the guest the whole node. The guest is sized from configuration defaults plus
the pod spec:

- **vCPUs** = `default_vcpus` (from the kata configuration, typically 1) + vCPUs hot-plugged to
  satisfy the pod's CPU limit. With `BENCH_CPU=2` you should see the corresponding vCPU count in
  the env record (`nproc`) of every kata run.
- **Memory** = `default_memory` + memory hot-plugged from the pod's memory limit. Again, verify
  via the env record's `mem_total_kb`.

Additionally, the RuntimeClass declares a per-pod overhead the scheduler accounts for:

```sh
oc get runtimeclass kata -o yaml | grep -A4 overhead
# overhead:
#   podFixed:
#     cpu: 250m
#     memory: 350Mi   (values vary by version/config)
```

Two consequences:

1. **Scheduling**: a kata pod consumes `requests + overhead.podFixed` of node allocatable. Density
   math that ignores this is wrong.
2. **Honesty check**: `measure-overhead.sh` produces the *empirical* per-pod memory floor; compare
   it to the declared `podFixed`. If the empirical number is larger, the node will hit memory
   pressure before the scheduler expects it to.

## CPU manager static policy (optional variable — keep it constant)

If the node's kubelet runs the CPU manager `static` policy, Guaranteed pods with **integer** CPU
requests get exclusive pinned cores. This changes results for **both** runtimes (less scheduler
interference, better cache locality) and interacts with kata vCPU placement. It is a legitimate
configuration to benchmark — but it is a *third variable*. Either leave it off for all runs or on
for all runs; never compare a pinned run against an unpinned one. Record which mode was active
alongside your results (it is visible in the kubelet config / node annotations, not in
`metadata.json`).

## Storage path taxonomy

This is the single most important thing to understand before reading disk numbers:

| Volume type | crun path | kata path |
|---|---|---|
| emptyDir | node filesystem directly | guest VFS → **virtiofs** (FUSE-over-virtio) → `virtiofsd` (host userspace) → node filesystem |
| PVC, `volumeMode: Filesystem` | node-mounted filesystem | same **virtiofs** path as emptyDir |
| PVC, `volumeMode: Block` | raw device into the container | **virtio-blk** paravirtual disk into the guest — no FUSE daemon, much thinner |

Expect the biggest kata deltas on the two virtiofs targets — that is a property of the shared-
filesystem path (per-I/O VM exits plus a host userspace daemon round-trip), not of "kata disks
being slow". The block PVC exists to prove the point: the same fio job on virtio-blk typically
lands far closer to crun. If your workload can use block volumes (databases often can), the
practical overhead may be much smaller than the emptyDir numbers suggest. This is why the suite
ships all three variants and why `disk.jsonl` results must always be grouped by
`parameters.target_mode` / volume variant before comparison.

### O_DIRECT on virtiofs

fio's usual defense against page-cache pollution is `direct=1` (O_DIRECT). Virtiofs does not
reliably support O_DIRECT (it depends on the virtiofsd cache configuration). `run-disk.sh`
therefore **probes** O_DIRECT support on the target and falls back to buffered I/O when the probe
fails, recording the mode actually used in `parameters.io_mode`. Rules:

- **Never compare a buffered result with an O_DIRECT result** — buffered 4k "IOPS" are largely
  page-cache hits and can exceed the physical device by 100x.
- When kata(virtiofs) falls back to buffered while crun runs O_DIRECT, the honest comparisons are
  buffered-vs-buffered (rerun crun accordingly) or the block-PVC variant where O_DIRECT works for
  both.

## Network path

Both runtimes share the CNI/OVN plumbing to the pod boundary: veth pair, OVN datapath, node NIC.
Kata inserts virtio-net between the veth and the workload — packets cross the VM boundary through
virtio rings with associated notifications/exits and copies. Consequences:

- **Latency degrades more than bulk throughput.** Large TCP transfers amortize per-packet costs
  via GSO/batching; a small-message round trip (`qperf-tcp-lat`) pays the full path both ways
  with nothing to amortize. Report both — throughput parity does not imply latency parity.
- Clients target the server **pod IP** directly (no Service object), keeping kube-proxy/OVN
  service DNAT out of the measured path. Keep `SERVER_RUNTIME` constant (default crun) so only
  the client side varies between compared runs.
- Same-node client/server measures the runtime data path without the physical network;
  cross-node includes NIC/fabric. Both are valid experiments — just don't mix them in one
  comparison. (`--server-node` controls this; default is the same node.)
- **UDP needs care.** `iperf3-udp-1g` offers a fixed 1 Gbit/s. If that rate is far below what the
  path can do, both runtimes show zero loss and the test is insensitive; if far above, both show
  massive loss and it's equally useless. The offered rate is recorded in `parameters` — when your
  environment is much faster or slower than 1 Gbit/s, rerun with an offered rate near the
  weaker path's capacity to make loss/jitter discriminating.

## Cloud-provider gotchas

- **Burstable instance types invalidate everything.** GCP `e2`/shared-core, AWS `t3`/`t4g`, Azure
  B-series throttle CPU by credit balance — a benchmark first drains credits, then measures the
  throttle. Use non-burstable families only (GCP `n2`/`c3`/`c7i`-equivalents, AWS `m6i`/`c6i`,
  Azure Dsv5 etc.).
- **Per-instance disk and network caps** scale with instance size on every cloud. If both
  runtimes saturate the cap you'll measure a runtime delta of ~zero regardless of the real
  overhead — suspiciously identical seq-throughput numbers are a cap, not parity. Size the
  instance so the runtime, not the cloud limit, is the bottleneck, and record the caps (instance
  docs) alongside results.
- **CPU steal from other tenants** shows up in node metrics (`mode="steal"` in
  `node_cpu_seconds_total` — see [external-metrics.md](external-metrics.md)). Nonzero steal during
  a run means another tenant on the physical host is eating your CPU; rerun. On nested-virt
  nodes, steal seen *inside* the node is L0 taking time from L1 — it hits kata guests and crun
  pods alike, but noisily.

## Startup measurement granularity

Kubernetes API timestamps (`.metadata.creationTimestamp`, condition `lastTransitionTime`) have
**one-second resolution**. crun pod startup is often sub-second, so API timestamps alone would
quantize it to 0s or 1s. `measure-startup.sh` therefore measures wall-clock from the workstation
(create issued → Ready observed via watch), which adds client/API latency but is consistent across
both runtimes and preserves sub-second differences. Use enough iterations (10+) for startup — the
distribution matters more than the mean, and scheduler placement adds jitter.

## Statistics

- Report **mean ± stdev** per test, with the iteration count. `parse-results.py` aggregates the
  `metrics` values across iterations within a run.
- Compare **kata/crun ratios** — within a node the absolute numbers are meaningful, across
  providers only the ratios are (different instance types, disks, NICs).
- **Rerun outliers.** A single wild iteration usually means interference (steal, background I/O,
  another pod). Investigate, quiesce, rerun — don't average interference into your conclusion,
  and don't silently drop points either; rerun the whole suite.
- **Never conclude from n=1.** One run of each runtime is a smoke test, not a result. Minimum
  publishable: 3 interleaved runs per runtime with consistent ratios.
- Check the env records first (guest kernel, vCPU count, MemTotal) — a beautiful dataset
  comparing a mis-sized guest against crun is a beautiful dataset about the wrong question.

## Pitfalls checklist

Run through this before quoting any number:

- [ ] Both runs on the **same node** (check `node` in the JSONL and `metadata.json`)?
- [ ] Non-burstable instance type (check `instance-type` in `metadata.json`)?
- [ ] Image pre-pulled before startup measurements?
- [ ] Env records sane — kata run shows guest kernel and expected vCPU/memory sizing?
- [ ] `parameters.io_mode` identical for every disk result pair being compared?
- [ ] Disk results grouped by volume variant (emptyDir / fs PVC / block PVC), never pooled?
- [ ] Same `SERVER_RUNTIME` and same server node placement across compared network/app runs?
- [ ] CPU manager policy constant across runs?
- [ ] CPU steal ≈ 0 during runs (node metrics)?
- [ ] Not saturating a cloud disk/NIC cap (suspiciously identical numbers)?
- [ ] ≥3 interleaved iterations/runs; outliers investigated, not averaged in?
- [ ] Cross-provider claims stated as ratios, not absolutes?
