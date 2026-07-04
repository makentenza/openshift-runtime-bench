#!/usr/bin/env bash
# =============================================================================
# measure-startup.sh — externally measured pod startup and deletion latency.
#
# The runtime boundary is invisible from inside a pod, so startup cost must be
# measured from the workstation. For each of N sequential pods this records:
#   scheduled_s        PodScheduled lastTransitionTime - creationTimestamp
#   running_s          containerStatuses[0].state.running.startedAt - creation
#   ready_s            Ready condition lastTransitionTime - creationTimestamp
#   wallclock_ready_s  client-side create->Ready wall clock (sub-second)
#   deletion_s         client-side delete->gone wall clock (kata VM teardown
#                      shows up here)
# API timestamps have 1-second granularity; wallclock_ready_s is the precise
# measurement. Results land in results/<label>-<runtime>-<stamp>/startup.jsonl
# using the same RESULT_JSON envelope the in-pod suites emit.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/measure-startup.sh --runtime RUNTIME --node NODE [options]

Measure pod startup phases (scheduled/running/ready), a sub-second wall-clock
create->Ready time, and pod deletion time for N sequential pods on one node.

Required:
  --runtime RT    crun | kata | kata-remote | kata-cc
  --node NODE     node to pin the startup pods to

Options:
  --count N       number of pods to launch sequentially (default: 10)
  --label LABEL   run label for the results dir name, e.g. gcp (default: run)
  --namespace NS  namespace (default: runtime-bench)
  --podvm-instance-type TYPE
                  kata-remote only: pin the peer-pods pod-VM cloud instance type
                  (e.g. t3.large). Ignored for crun/kata.
  -h, --help      show this help

Notes:
  * API-derived phases (scheduled_s/running_s/ready_s) have 1-second timestamp
    granularity; wallclock_ready_s is the precise sub-second number.
  * Pre-pull the benchmark image on the node first (apply
    manifests/prepull-daemonset.yaml via run-suite.sh or manually), otherwise
    iteration 1 silently includes the image pull.
EOF
}

COUNT="${COUNT:-10}"

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime)   RUNTIME="${2:?--runtime needs a value}"; shift 2 ;;
    --node)      NODE_NAME="${2:?--node needs a value}"; shift 2 ;;
    --count)     COUNT="${2:?--count needs a value}"; shift 2 ;;
    --label)     RUN_LABEL="${2:?--label needs a value}"; shift 2 ;;
    --namespace) NAMESPACE="${2:?--namespace needs a value}"; shift 2 ;;
    --podvm-instance-type) POD_VM_INSTANCE_TYPE="${2:?--podvm-instance-type needs a value}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

# --- Preflight -----------------------------------------------------------------
require_cmds oc envsubst python3 jq

if [ -z "${RUNTIME}" ]; then
  usage >&2
  die "--runtime is required (crun|kata|kata-remote|kata-cc)"
fi
if [ -z "${NODE_NAME}" ]; then
  usage >&2
  warn "--node is required. Available nodes:"
  oc get nodes -o wide >&2 || warn "  (could not list nodes — are you logged in? try 'oc login')"
  die "--node is required"
fi
is_pos_int "${COUNT}" || die "--count must be a positive integer (got '${COUNT}')"

if ! oc whoami >/dev/null 2>&1; then
  die "not logged in to a cluster ('oc whoami' failed) — run 'oc login' first"
fi
check_node_exists "${NODE_NAME}" "--node"
derive_runtime_spec
verify_runtime_class "${RUNTIME}"

if ! oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  log "namespace '${NAMESPACE}' not found — creating it from manifests/namespace.yaml"
  apply_manifest "${MANIFEST_DIR}/namespace.yaml"
fi

log "tip: make sure ${BENCH_IMAGE} is pre-pulled on ${NODE_NAME} (see manifests/prepull-daemonset.yaml) — otherwise iteration 1 includes the image pull time"
warn "API-derived phase timings (scheduled_s/running_s/ready_s) have 1-second granularity; wallclock_ready_s is the precise sub-second measurement"

RUN_DIR="$(new_run_dir "${RUN_LABEL}" "${RUNTIME}")"
log "run directory: ${RUN_DIR}"
record_metadata "${RUN_DIR}"

STARTUP_JSONL="${RUN_DIR}/startup.jsonl"
: > "${STARTUP_JSONL}"

now_epoch() { python3 -c 'import time; print("%.3f" % time.time())'; }

# --- Measurement loop ------------------------------------------------------------
for (( i = 1; i <= COUNT; i++ )); do
  POD_NAME="bench-startup-${RUNTIME}-${i}"
  export POD_NAME
  log "[${i}/${COUNT}] measuring pod ${POD_NAME}"

  # Stale pod from an aborted earlier run must be fully gone before we start.
  oc -n "${NAMESPACE}" delete pod "${POD_NAME}" --ignore-not-found --wait=true >/dev/null 2>&1 || true

  t0="$(now_epoch)"
  apply_manifest "${MANIFEST_DIR}/startup/startup-pod.yaml" >/dev/null
  if ! oc -n "${NAMESPACE}" wait --for=condition=Ready "pod/${POD_NAME}" --timeout=300s >/dev/null; then
    warn "pod ${POD_NAME} did not become Ready within 300s — diagnostics follow"
    oc -n "${NAMESPACE}" describe pod "${POD_NAME}" >&2 || true
    oc -n "${NAMESPACE}" delete pod "${POD_NAME}" --ignore-not-found >/dev/null 2>&1 || true
    die "startup measurement aborted at iteration ${i}"
  fi
  t1="$(now_epoch)"

  pod_json="$(oc -n "${NAMESPACE}" get pod "${POD_NAME}" -o json)"

  t2="$(now_epoch)"
  if ! oc -n "${NAMESPACE}" delete pod "${POD_NAME}" --wait --timeout=120s >/dev/null; then
    warn "deletion of ${POD_NAME} exceeded 120s — the recorded deletion_s reflects the timeout"
  fi
  t3="$(now_epoch)"

  # Build the two RESULT_JSON envelope lines with python3 (no string concat).
  POD_JSON="${pod_json}" python3 - "$i" "$t0" "$t1" "$t2" "$t3" >> "${STARTUP_JSONL}" <<'PYEOF'
import datetime as dt
import json
import os
import sys

pod = json.loads(os.environ["POD_JSON"])
iteration = int(sys.argv[1])
t0, t1, t2, t3 = (float(a) for a in sys.argv[2:6])


def parse_ts(ts):
    return dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


created = parse_ts(pod["metadata"]["creationTimestamp"])


def condition_time(ctype):
    for cond in pod.get("status", {}).get("conditions", []):
        if cond.get("type") == ctype and cond.get("status") == "True":
            lt = cond.get("lastTransitionTime")
            if lt:
                return parse_ts(lt)
    return None


scheduled = condition_time("PodScheduled")
ready = condition_time("Ready")
running = None
statuses = pod.get("status", {}).get("containerStatuses", [])
if statuses:
    started_at = statuses[0].get("state", {}).get("running", {}).get("startedAt")
    if started_at:
        running = parse_ts(started_at)


def since_creation(t):
    return round((t - created).total_seconds(), 3) if t is not None else None


runtime = os.environ.get("RUNTIME", "")
node = os.environ.get("NODE_NAME", "")
now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
pod_name = pod["metadata"]["name"]

metrics = {
    "scheduled_s": since_creation(scheduled),
    "running_s": since_creation(running),
    "ready_s": since_creation(ready),
    "wallclock_ready_s": round(t1 - t0, 3),
}
metrics = {k: v for k, v in metrics.items() if v is not None}

print(json.dumps({
    "suite": "startup",
    "test": "pod-startup",
    "runtime": runtime,
    "node": node,
    "timestamp": now,
    "iteration": iteration,
    "parameters": {
        "pod": pod_name,
        "note": "API phases have 1s timestamp granularity; wallclock_ready_s is sub-second",
    },
    "metrics": metrics,
    "units": {k: "s" for k in metrics},
}, separators=(",", ":")))

print(json.dumps({
    "suite": "startup",
    "test": "pod-deletion",
    "runtime": runtime,
    "node": node,
    "timestamp": now,
    "iteration": iteration,
    "parameters": {"pod": pod_name},
    "metrics": {"deletion_s": round(t3 - t2, 3)},
    "units": {"deletion_s": "s"},
}, separators=(",", ":")))
PYEOF
done

log "wrote $(wc -l < "${STARTUP_JSONL}" | tr -d '[:space:]') result line(s) -> ${STARTUP_JSONL}"

# --- Summary table -----------------------------------------------------------------
python3 - "${STARTUP_JSONL}" <<'PYEOF'
import json
import statistics
import sys

samples = {}
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        for metric, value in rec.get("metrics", {}).items():
            samples.setdefault((rec.get("test", "?"), metric), []).append(float(value))

print()
print("Startup summary (seconds; API-derived phases have 1s granularity,")
print("wallclock_ready_s is the precise client-side measurement):")
print()
print(f"{'test':<14} {'metric':<20} {'n':>3} {'mean':>10} {'min':>10} {'max':>10}")
print("-" * 72)
for (test, metric), values in sorted(samples.items()):
    print(f"{test:<14} {metric:<20} {len(values):>3} "
          f"{statistics.mean(values):>10.3f} {min(values):>10.3f} {max(values):>10.3f}")
print()
PYEOF

log "done — compare against another runtime with:"
log "  python3 ${REPO_ROOT}/scripts/parse-results.py results/<baseline-run-dir> ${RUN_DIR}"
