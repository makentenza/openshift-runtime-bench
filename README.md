# openshift-runtime-bench

Measure the performance delta of running the **same workload** on the **same OpenShift node**
under (a) the **Kata Containers** runtime — each pod inside a QEMU/KVM lightweight VM, which on
cloud providers usually means **nested virtualization** — versus (b) **crun**, OpenShift's default
OCI runtime. The suite is provider-agnostic: run it unchanged on GCP, AWS, Azure, or bare metal
and compare the kata/crun **ratio** per provider. It ships one benchmark container image with all
tools baked in, `envsubst`-templated OpenShift manifests, workstation orchestration scripts, and
methodology documentation so the numbers you get are defensible.

## What gets measured

| Suite | Tools | Key metrics | Output file |
|---|---|---|---|
| `cpu` | sysbench, stress-ng | prime events/s; matrix, context-switch, syscall, fork bogo-ops/s | `cpu.jsonl` |
| `memory` | sysbench, stress-ng | memory bandwidth MiB/s (seq/random, read/write); STREAM-like bandwidth; page faults/s | `memory.jsonl` |
| `disk` | fio | 4k random read/write IOPS + latency, 1M sequential MB/s, 70/30 mixed, fsync latency — each across **emptyDir**, **filesystem PVC**, and **block PVC** | `disk.jsonl` |
| `network` | iperf3, qperf | TCP throughput (1 and 4 streams, reverse), UDP throughput/jitter/loss at 1 Gbit/s, TCP round-trip latency, TCP bandwidth | `network.jsonl` |
| `app` | nginx + ApacheBench | HTTP requests/s and latency for a small object and a 1 MiB object | `app.jsonl` |
| startup *(measured externally)* | `scripts/measure-startup.sh` | pod create→Ready seconds, pod deletion seconds | `startup.jsonl` |
| overhead *(measured externally)* | `scripts/measure-overhead.sh` | per-pod incremental memory MiB (the density floor) | `overhead.jsonl` |
| `env` *(emitted by every suite)* | `image/scripts/common.sh` | kernel version, nproc, MemTotal, hypervisor CPU flag — proof of the runtime boundary (guest vs host view) | embedded in each suite's `.jsonl` |

Full metric catalog with per-test rationale: [docs/metrics.md](docs/metrics.md).
Metrics you can only observe from outside the pod: [docs/external-metrics.md](docs/external-metrics.md).

## How it works

One container image ([image/Containerfile](image/Containerfile)) contains every benchmark tool and
a `run-<suite>.sh` entrypoint per suite. Manifests under [manifests/](manifests/) are `envsubst`
templates; [scripts/lib.sh](scripts/lib.sh) renders them with an explicit variable allowlist and
applies them. Benchmark scripts print machine-readable results to stdout as single lines of the
form `RESULT_JSON {...}`; the runner collects them from the Job logs:

```
oc logs job/<name> | grep '^RESULT_JSON ' | sed 's/^RESULT_JSON //' > results/<run-dir>/<suite>.jsonl
```

```
workstation                                 OpenShift cluster
-----------                                 -----------------------------------------
scripts/run-suite.sh
  |-- render manifests (envsubst) --------> Jobs / server Deployments, pinned to the
  |                                         target node via nodeSelector
  |                                           +- bench pod (crun, or kata VM)
  |                                           |    runs image/scripts/run-*.sh
  |                                           |    stdout: RESULT_JSON {...}
  |                                           +- iperf3 / nginx server pod
  |                                                (clients hit the pod IP directly)
  |-- oc logs job/... | grep RESULT_JSON
  v
results/<label>-<runtime>-<YYYYmmdd-HHMMSS>/
  +- cpu.jsonl memory.jsonl disk.jsonl network.jsonl app.jsonl
  +- metadata.json   (node, instance type, zone, kernel, kubelet, runtime versions)
  v
scripts/parse-results.py <crun-run-dir> <kata-run-dir>
  -> per-test mean +/- stdev and kata/crun ratio table
```

Design decisions that keep the comparison honest (details in
[docs/methodology.md](docs/methodology.md)):

- Both runtimes run on the **same node** (`nodeSelector` on `kubernetes.io/hostname`).
- All benchmark and server pods are **Guaranteed QoS** (`requests == limits`).
- Network/app clients target the **server pod IP** directly — no Service, so kube-proxy/OVN
  service DNAT stays out of the measured path.
- Jobs use `backoffLimit: 0` and `restartPolicy: Never` — a failed run fails loudly instead of
  silently retrying into your statistics.
- Everything runs under the **restricted-v2 SCC**: no privileged pods, no hostPath, arbitrary UID.

## Prerequisites

Cluster:

- OpenShift **4.12+**.
- **OpenShift sandboxed containers** (or upstream Kata Containers) installed, providing a
  `RuntimeClass` named `kata` (also supported: `kata-remote`, `kata-cc`).
- On cloud providers: **nested virtualization enabled** on the target node — verify with the
  commands in [docs/external-metrics.md](docs/external-metrics.md#a-verify-nested-virt--kata-readiness-on-a-node)
  before trusting any kata result.
- `cluster-admin` or equivalent rights to create a namespace, Jobs, PVCs, and (optionally) a
  BuildConfig.

Workstation (macOS or Linux):

- `oc`, `envsubst` (from gettext), `python3`, `jq`. `scripts/lib.sh` checks these and fails with
  an actionable message if one is missing.

## Build the image

### Option A — in-cluster build (recommended: no registry credentials needed)

```sh
NAMESPACE=runtime-bench envsubst '${NAMESPACE}' < manifests/namespace.yaml | oc apply -f -
NAMESPACE=runtime-bench envsubst '${NAMESPACE}' < manifests/build/build.yaml | oc apply -f -
oc -n runtime-bench start-build runtime-bench --follow
```

The default `BENCH_IMAGE`
(`image-registry.openshift-image-registry.svc:5000/runtime-bench/runtime-bench:latest`) already
points at the resulting ImageStream in the internal registry — no further configuration needed.

### Option B — local build and push

```sh
podman build -t quay.io/<you>/runtime-bench:latest image/
# On Apple Silicon, cross-build for the cluster architecture:
#   podman build --platform linux/amd64 -t quay.io/<you>/runtime-bench:latest image/
podman push quay.io/<you>/runtime-bench:latest
export BENCH_IMAGE=quay.io/<you>/runtime-bench:latest
```

## Pre-pull the image

Image pull time must not pollute startup measurements (and slows every first Job). Pre-pull onto
all nodes with the DaemonSet, wait for it, then remove it:

```sh
NAMESPACE=runtime-bench \
BENCH_IMAGE="${BENCH_IMAGE:-image-registry.openshift-image-registry.svc:5000/runtime-bench/runtime-bench:latest}" \
  envsubst '${NAMESPACE} ${BENCH_IMAGE}' < manifests/prepull-daemonset.yaml | oc apply -f -
oc -n runtime-bench rollout status daemonset/bench-prepull
oc -n runtime-bench delete daemonset/bench-prepull
```

## Quickstart

Run the full suite for both runtimes on the same node, then compare:

```sh
cp scripts/env.example.sh scripts/env.sh   # optional: set persistent defaults

# Baseline: crun (cluster default runtime, no runtimeClassName)
./scripts/run-suite.sh --runtime crun --node <node-name> --label gcp

# Same node, same workload, kata runtime
./scripts/run-suite.sh --runtime kata --node <node-name> --label gcp

# Compare the two run directories
./scripts/parse-results.py results/gcp-crun-<YYYYmmdd-HHMMSS> results/gcp-kata-<YYYYmmdd-HHMMSS>
```

Each run creates `results/<label>-<runtime>-<YYYYmmdd-HHMMSS>/` containing one `.jsonl` file per
suite plus `metadata.json` (node, instance type, region/zone, kernel, OS image, container runtime,
kubelet version). For statistically meaningful results run each runtime at least twice,
interleaved (`crun, kata, crun, kata`) — see [docs/methodology.md](docs/methodology.md).

## Startup latency & per-pod overhead

These are measured **from outside** the pod — a workload cannot time its own VM boot or see the
VMM's memory:

```sh
# Pod create->Ready and deletion latency (repeat for both runtimes)
./scripts/measure-startup.sh --runtime crun --node <node-name> --label gcp
./scripts/measure-startup.sh --runtime kata --node <node-name> --label gcp

# Per-pod incremental memory (VMM + guest kernel floor under kata)
./scripts/measure-overhead.sh --runtime crun --node <node-name> --label gcp
./scripts/measure-overhead.sh --runtime kata --node <node-name> --label gcp
```

Startup uses the fixed-size pod template `manifests/startup/startup-pod.yaml` (500m/512Mi,
`terminationGracePeriodSeconds: 0`); overhead scales sleep pods and reads node-side memory, which
catches VMM cost that per-container cgroup metrics can miss. Background:
[docs/external-metrics.md](docs/external-metrics.md).

## Comparing cloud providers

1. Run the **identical** suite on each cluster, tagging runs per provider:
   `--label gcp`, `--label aws`, `--label azure`, `--label metal`.
2. Keep instance size comparable across providers (same vCPU/memory class), and never use
   burstable instance types (see methodology).
3. Compare the **kata/crun ratio per provider**, not absolute numbers across providers — different
   instance types, disks, and NICs make absolute cross-provider numbers meaningless. The ratio
   isolates the runtime overhead, which is the thing that varies with each provider's nested-virt
   implementation.
4. `metadata.json` in each run directory records the instance type and topology labels so runs
   remain attributable later.

## Repo layout

```
openshift-runtime-bench/
├── README.md
├── LICENSE                      Apache-2.0
├── .gitignore
├── docs/
│   ├── metrics.md               metric catalog: every sub-test, units, why it matters
│   ├── methodology.md           experimental design, fairness rules, pitfalls
│   └── external-metrics.md      node-side and Prometheus measurements, verification commands
├── image/
│   ├── Containerfile            single benchmark image (Fedora + all tools)
│   └── scripts/
│       ├── common.sh            log/emit_result/emit_env_info — the RESULT_JSON protocol
│       ├── run-cpu.sh
│       ├── run-memory.sh
│       ├── run-disk.sh
│       ├── run-network.sh       MODE=server also runs iperf3 + qperf listeners
│       └── run-app.sh
├── manifests/                   envsubst templates (rendered by scripts/lib.sh)
│   ├── namespace.yaml
│   ├── prepull-daemonset.yaml
│   ├── build/build.yaml         ImageStream + BuildConfig
│   ├── jobs/
│   │   ├── cpu-job.yaml
│   │   ├── memory-job.yaml
│   │   ├── disk-emptydir-job.yaml
│   │   ├── disk-pvc-job.yaml    PVC (Filesystem) + Job
│   │   ├── disk-block-job.yaml  PVC (Block) + Job
│   │   ├── network-client-job.yaml
│   │   └── app-client-job.yaml
│   ├── servers/
│   │   ├── iperf3-server.yaml   iperf3 :5201 + qperf :19765, no Service (pod IP)
│   │   └── nginx-server.yaml    nginx :8080, no Service (pod IP)
│   └── startup/
│       └── startup-pod.yaml
├── scripts/                     workstation orchestration (macOS + Linux)
│   ├── env.example.sh           copy to scripts/env.sh for local defaults (gitignored)
│   ├── lib.sh                   prereq checks, template rendering, log collection, metadata
│   ├── run-suite.sh
│   ├── measure-startup.sh
│   ├── measure-overhead.sh
│   └── parse-results.py
└── results/                     run output (gitignored)
```

## Flags reference — `run-suite.sh`

| Flag | Template variable | Default | Meaning |
|---|---|---|---|
| `--runtime` | `RUNTIME` | — (required) | `crun`, `kata`, `kata-remote`, or `kata-cc`. `crun` means **no** `runtimeClassName` (cluster default runtime); anything else is injected as `runtimeClassName: <value>` at pod-spec level. Also used as a label value and in resource/run-dir names. |
| `--node` | `NODE_NAME` | — (required) | Target node for the benchmark pods (`nodeSelector` on `kubernetes.io/hostname`). |
| `--label` | — | `run` | Free-form run tag (e.g. `gcp`, `aws`); first component of the run directory name. |
| `--benchmarks` | — | all | Comma-separated subset of `cpu,memory,disk,network,app`. |
| `--pvc` | — | off | Also run the disk suite against a **Filesystem** PVC (`disk-pvc.jsonl`). |
| `--block` | — | off | Also run the disk suite against a raw **Block** PVC (`disk-block.jsonl`). |
| `--storage-class` | `STORAGE_CLASS_SPEC` | cluster default | StorageClass for the `--pvc`/`--block` PVCs. |
| `--server-runtime` | `SERVER_RUNTIME` | `crun` | Runtime of the iperf3/nginx **server** pods. Keep constant across compared runs so only the client side varies. |
| `--server-node` | `SERVER_NODE_NAME` | same as `--node` | Node for the server pods. Same node measures the runtime data path without physical NIC/fabric effects; a different node includes them. |
| `--namespace` | `NAMESPACE` | `runtime-bench` | Namespace for all benchmark resources. |
| `--iterations` | `ITERATIONS` | `3` | Iterations per sub-test inside the pod. |
| `--duration` | `DURATION` | `30` | Seconds per sub-test iteration. |
| `--keep` | — | off | Keep jobs/servers/PVCs after collection instead of deleting them. |

Knobs without a dedicated flag are environment variables (set them in `scripts/env.sh`, see
`scripts/env.example.sh`): `BENCH_IMAGE` (benchmark image reference), `BENCH_CPU` (CPU request
**and** limit, also exported to pods as `THREADS`; default `2`), `BENCH_MEMORY` (memory request
and limit; default `4Gi`), `PVC_SIZE` (default `10Gi`). Every flag also has an env equivalent;
command-line flags win. `measure-startup.sh` and `measure-overhead.sh` accept the same
`--runtime/--node/--label/--namespace` core flags; run each with `--help` for their specific
options (e.g. `--count`, `--settle`).

## Caveats — read before quoting numbers

- **emptyDir and filesystem PVCs traverse virtiofs under kata** but plain host filesystem under
  crun — this is where the biggest deltas live, and it is a *storage-path* difference, not raw
  disk speed. Block PVCs (virtio-blk) are the thin-path comparison. Details in
  [docs/methodology.md](docs/methodology.md#storage-path-taxonomy).
- **O_DIRECT may not work on virtiofs.** `run-disk.sh` probes and falls back to buffered I/O,
  recording the actual mode in `parameters.io_mode` — never compare results with different
  `io_mode` values.
- **Burstable instance types (GCP e2, AWS T-series, Azure B-series) invalidate results.**
- Per-instance **disk and network caps** can be the bottleneck instead of the runtime — size the
  instance so the runtime is what saturates first.
- Never conclude from **n=1**; interleave runs and report mean ± stdev
  ([docs/methodology.md](docs/methodology.md#statistics)).
- Compare **ratios** across providers, absolute numbers only within a single node.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
