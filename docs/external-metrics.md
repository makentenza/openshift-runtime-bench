# External metrics — what the workload cannot self-measure

A pod cannot time its own VM boot, see the VMM's memory, or observe CPU steal on the node.
Everything on this page is measured from the workstation or the cluster side. Commands are
copy-pasteable; replace `<node>` with the target node name and adjust `runtime-bench` if you
changed `NAMESPACE`.

## (a) Verify nested virt / kata readiness on a node

Run this **before** any kata benchmark on a cloud node. If `/dev/kvm` is missing, kata pods
either won't start or will fall back to a much slower configuration — either way your numbers
are garbage.

```sh
oc debug node/<node> -- chroot /host sh -c 'ls -l /dev/kvm; grep -m1 -oE "vmx|svm" /proc/cpuinfo; cat /sys/module/kvm_intel/parameters/nested 2>/dev/null'
```

Expected on a kata-ready node:

- `/dev/kvm` exists (character device, usually group `kvm`),
- `vmx` (Intel) or `svm` (AMD) present in the node's CPU flags — on a cloud instance this means
  the provider exposes virtualization extensions to the node VM, i.e. nested virt is enabled,
- `nested: 1`/`Y` if the node itself will run nested guests via kvm_intel (AMD:
  `/sys/module/kvm_amd/parameters/nested`).

And confirm the RuntimeClass exists:

```sh
oc get runtimeclass
# NAME          HANDLER       AGE
# kata          kata          ...
```

Provider notes: GCP requires the nested-virt license/flag on the image or instance (RHCOS GCP
images generally ship it); AWS only supports nested virt on `*.metal` instances; Azure requires
v3+ series with nested support. Verify empirically with the command above — provider
documentation describes intent, `/dev/kvm` describes reality.

## (b) Capture versions

Record these with every result set you keep (they explain future discrepancies):

```sh
# Kata runtime and CRI-O on the node
oc debug node/<node> -- chroot /host sh -c 'kata-runtime version; crio version; uname -r'

# OpenShift sandboxed containers operator version
oc get csv -n openshift-sandboxed-containers-operator

# Cluster/client versions
oc version
```

`metadata.json` in each run directory already stores the node's `kernelVersion`, `osImage`,
`containerRuntimeVersion`, and `kubeletVersion`; the commands above add the kata runtime and
operator versions, which are not exposed via node status.

## (c) Node-side view of a running benchmark

While a kata benchmark Job runs, look at the node to see the VM that backs the pod:

```sh
oc debug node/<node> -- chroot /host sh -c 'ps aux' | grep -E 'qemu|virtiofsd'
```

You should see one `qemu-kvm` (or `qemu-system-x86_64`) process per kata pod, plus a
`virtiofsd` process serving its shared filesystem. The QEMU command line shows the actual guest
sizing (`-smp`, `-m`) — cross-check it against your `BENCH_CPU`/`BENCH_MEMORY` and the in-pod env
record. During a crun run the same grep returns nothing: the workload is just a process tree.

Container-level runtime stats from CRI-O:

```sh
oc debug node/<node> -- chroot /host sh -c 'crictl ps --name bench -o json | head -50'
oc debug node/<node> -- chroot /host sh -c 'crictl stats'
```

`crictl stats` reports per-container CPU/memory as CRI-O sees them — useful, but read the caveat
in section (d) about what the container cgroup does and doesn't contain under kata.

## (d) Prometheus / PromQL during a run

Use the OpenShift console (**Observe → Metrics**) or `oc adm top pod -n runtime-bench` /
`oc adm top node` for spot checks. PromQL for the interesting series:

Per-pod CPU usage (cores) in the benchmark namespace:

```promql
sum(rate(container_cpu_usage_seconds_total{namespace='runtime-bench'}[2m])) by (pod)
```

Per-pod memory working set:

```promql
container_memory_working_set_bytes{namespace='runtime-bench'}
```

Node-level CPU by mode — **watch `steal`**:

```promql
sum by (mode) (rate(node_cpu_seconds_total{instance=~'<node>.*'}[2m]))
```

Nonzero `steal` means the underlying hypervisor (the cloud, on a nested-virt node) is taking CPU
away from the node — the classic noisy-neighbor / nested-virt tell. Any measurable steal during a
benchmark run invalidates that run; rerun it.

Node-side disk and network activity during runs (confirms which device the I/O actually hits and
whether something else is competing):

```promql
rate(node_disk_written_bytes_total{instance=~'<node>.*'}[2m])
rate(node_disk_reads_completed_total{instance=~'<node>.*'}[2m])
rate(node_network_transmit_bytes_total{instance=~'<node>.*'}[2m])
rate(node_network_receive_bytes_total{instance=~'<node>.*'}[2m])
```

Cluster-wide pod startup evidence (complements `measure-startup.sh`):

```promql
histogram_quantile(0.99, sum(rate(kubelet_pod_start_duration_seconds_bucket[10m])) by (le))
```

**Important caveat for kata:** depending on the kata/CRI-O version and sandbox cgroup
configuration, part of the VMM cost (QEMU threads, `virtiofsd`) may live **outside** the
container's cgroup as cadvisor reports it — `container_*` series can under-count what a kata pod
really costs the node. Always cross-check cadvisor numbers against node-side process RSS
(`ps` from section (c)); that cross-check is exactly what `scripts/measure-overhead.sh`
automates, which is why per-pod overhead is measured node-side rather than from Prometheus.

## (e) Density — how many kata pods fit on a node

The per-pod kata floor is roughly: `RuntimeClass overhead.podFixed` (what the scheduler reserves)
vs the *empirical* VMM + guest-kernel + virtiofsd memory (what the node actually loses).
`measure-overhead.sh` gives the empirical number per pod; for the node-level picture:

1. Scale sleep pods using the startup pod template (`manifests/startup/startup-pod.yaml` renders
   one pod per `POD_NAME`) until the node shows memory pressure.
2. Watch node available memory while scaling:

```sh
oc debug node/<node> -- chroot /host sh -c 'grep MemAvailable /proc/meminfo'
```

```promql
node_memory_MemAvailable_bytes{instance=~'<node>.*'}
```

3. The slope of MemAvailable vs pod count is the true per-pod cost; the x-intercept region is
   your practical density limit. Compare against the scheduler's view
   (`oc describe node <node>` → allocated resources) to see whether `overhead.podFixed` is
   honest for your configuration.

For large-scale density and startup-storm testing beyond this repo's scope (hundreds of pods,
churn patterns, control-plane impact), use
[kube-burner](https://github.com/kube-burner/kube-burner) — this repo's startup/overhead scripts
are deliberately small and node-focused.

## (f) Capturing cloud context

Instance type, region, and zone are recorded automatically in each run's `metadata.json` (from
the node labels `node.kubernetes.io/instance-type`, `topology.kubernetes.io/region`,
`topology.kubernetes.io/zone`). Additionally capture:

The StorageClass and provisioner behind the disk-suite PVCs:

```sh
oc get sc
oc get pvc -n runtime-bench -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,MODE:.spec.volumeMode
```

Disk **type** matters as much as size: `pd-ssd` vs `pd-balanced` (GCP), `gp3` vs `io2` (AWS),
Premium vs Standard SSD (Azure) have different IOPS/throughput baselines and per-size caps. Two
providers compared with different disk tiers are not comparable at all — record the StorageClass
parameters (`oc get sc <name> -o yaml`) next to your results, and check the provider's published
per-instance and per-disk caps before interpreting any disk number that looks suspiciously flat
across runtimes (see [methodology.md](methodology.md#cloud-provider-gotchas)).
