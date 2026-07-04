#!/usr/bin/env bash
# =============================================================================
# measure-overhead.sh — externally measured per-pod NODE-side memory cost.
#
# Pod-level (cgroup/cadvisor) metrics do not show everything a pod costs the
# node: under kata each pod carries a VMM (qemu) and a virtiofsd process plus
# a guest kernel; under crun the per-pod extra is essentially one conmon.
# This script measures that from the node itself:
#
#   1. snapshot BEFORE: node MemAvailable + summed RSS of qemu / virtiofsd /
#      conmon processes (via `oc debug node/... chroot /host`)
#   2. create N identical sleep pods (manifests/startup/startup-pod.yaml,
#      500m/512Mi Guaranteed) pinned to the node, wait until Ready
#   3. wait SETTLE_S seconds for allocations to settle
#   4. snapshot AFTER, then compute per-pod deltas:
#        memavailable_delta_mb_per_pod   (whole-node view, includes everything)
#        vmm_rss_mb_per_pod              (qemu + virtiofsd — the kata VMM cost)
#        conmon_rss_mb_per_pod           (the crun-side per-pod helper)
#
# Results land in results/<label>-<runtime>-<stamp>/overhead.jsonl using the
# same RESULT_JSON envelope as every other suite.
#
# CAVEATS: MemAvailable is a kernel estimate and moves with page cache and
# unrelated node activity — treat memavailable_delta as indicative, run this
# several times on a quiet node, and put more weight on the RSS deltas.
# The kata RuntimeClass 'overhead.podFixed' value is the *scheduler's* estimate
# of the same cost; this script measures the empirical one.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/measure-overhead.sh --runtime RUNTIME --node NODE [options]

Measure the per-pod node-side memory cost (VMM/guest-kernel floor under kata,
conmon under crun) by snapshotting node memory before/after N sleep pods.

Required:
  --runtime RT    crun | kata | kata-remote | kata-cc
  --node NODE     node to pin the pods to (and to snapshot via oc debug)

Options:
  --count N       number of sleep pods to create (default: 5)
  --settle S      seconds to wait after pods are Ready before the second
                  snapshot (default: 30)
  --label LABEL   run label for the results dir name, e.g. gcp (default: run)
  --namespace NS  namespace (default: runtime-bench)
  -h, --help      show this help

Notes:
  * Requires permission to run 'oc debug node/<node>' (host chroot).
  * Run on a QUIET node and repeat several times: MemAvailable is an estimate
    and is disturbed by page cache and unrelated pods. The qemu/virtiofsd RSS
    delta is the more stable signal for kata.
  * Compare the same measurement between --runtime crun and --runtime kata;
    the difference is the runtime's per-pod density floor.
EOF
}

COUNT="${COUNT:-5}"
SETTLE_S="${SETTLE_S:-30}"

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime)   RUNTIME="${2:?--runtime needs a value}"; shift 2 ;;
    --node)      NODE_NAME="${2:?--node needs a value}"; shift 2 ;;
    --count)     COUNT="${2:?--count needs a value}"; shift 2 ;;
    --settle)    SETTLE_S="${2:?--settle needs a value}"; shift 2 ;;
    --label)     RUN_LABEL="${2:?--label needs a value}"; shift 2 ;;
    --namespace) NAMESPACE="${2:?--namespace needs a value}"; shift 2 ;;
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
is_pos_int "${SETTLE_S}" || die "--settle must be a positive integer (got '${SETTLE_S}')"

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

RUN_DIR="$(new_run_dir "${RUN_LABEL}" "${RUNTIME}")"
log "run directory: ${RUN_DIR}"
record_metadata "${RUN_DIR}"

OVERHEAD_JSONL="${RUN_DIR}/overhead.jsonl"
: > "${OVERHEAD_JSONL}"

# --- Node snapshot via oc debug ----------------------------------------------------
# The debug pod's own output is noisy ("Starting pod/...", warnings), so the
# measurement lines are fenced between sentinel markers and extracted after.
# Retries cover transient debug-pod scheduling failures.
node_snapshot() {
  local outfile="$1" attempt raw
  local remote_cmd
  remote_cmd='echo RTB_SNAPSHOT_BEGIN;
awk '\''/^MemAvailable:/ {print "memavailable_kb=" $2}'\'' /proc/meminfo;
ps -eo rss=,comm= | awk '\''
  $2 ~ /qemu/      {qemu += $1}
  $2 ~ /virtiofsd/ {vf += $1}
  $2 ~ /conmon/    {cm += $1}
  END {printf "qemu_rss_kb=%d\nvirtiofsd_rss_kb=%d\nconmon_rss_kb=%d\n", qemu, vf, cm}
'\'';
echo RTB_SNAPSHOT_END'

  for attempt in 1 2 3; do
    raw="$(oc debug "node/${NODE_NAME}" -q -- chroot /host sh -c "${remote_cmd}" 2>/dev/null || true)"
    # Keep only the fenced lines; anything else the debug pod printed is noise.
    printf '%s\n' "$raw" \
      | awk '/^RTB_SNAPSHOT_BEGIN$/{f=1; next} /^RTB_SNAPSHOT_END$/{f=0} f' \
      > "$outfile"
    if grep -q '^memavailable_kb=' "$outfile"; then
      return 0
    fi
    warn "node snapshot attempt ${attempt}/3 failed (oc debug produced no usable output) — retrying in 5s"
    sleep 5
  done
  die "could not snapshot node ${NODE_NAME} via 'oc debug' — check permissions (host chroot) and node health"
}

# --- Pod lifecycle (cleanup runs even on failure) ------------------------------------
cleanup_pods() {
  local i pod
  log "cleaning up overhead pods"
  for ((i = 1; i <= COUNT; i++)); do
    pod="bench-overhead-${RUNTIME}-${i}"
    oc -n "${NAMESPACE}" delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
}
trap cleanup_pods EXIT

BEFORE_FILE="${RUN_DIR}/.snapshot-before"
AFTER_FILE="${RUN_DIR}/.snapshot-after"

log "snapshot BEFORE (node ${NODE_NAME}: MemAvailable + qemu/virtiofsd/conmon RSS)"
node_snapshot "${BEFORE_FILE}"
sed 's/^/  /' "${BEFORE_FILE}" >&2

log "creating ${COUNT} sleep pod(s) on ${NODE_NAME} (runtime=${RUNTIME}, 500m/512Mi each)"
for ((i = 1; i <= COUNT; i++)); do
  POD_NAME="bench-overhead-${RUNTIME}-${i}"
  export POD_NAME
  oc -n "${NAMESPACE}" delete pod "${POD_NAME}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  apply_manifest "${MANIFEST_DIR}/startup/startup-pod.yaml" >/dev/null
done

for ((i = 1; i <= COUNT; i++)); do
  pod="bench-overhead-${RUNTIME}-${i}"
  if ! oc -n "${NAMESPACE}" wait --for=condition=Ready "pod/${pod}" --timeout=300s >/dev/null; then
    warn "pod ${pod} did not become Ready within 300s — diagnostics follow"
    oc -n "${NAMESPACE}" describe pod "${pod}" >&2 || true
    die "overhead measurement aborted (pods are cleaned up on exit)"
  fi
done
log "all ${COUNT} pod(s) Ready — settling for ${SETTLE_S}s before the second snapshot"
sleep "${SETTLE_S}"

log "snapshot AFTER"
node_snapshot "${AFTER_FILE}"
sed 's/^/  /' "${AFTER_FILE}" >&2

# --- Compute deltas and emit the RESULT_JSON envelope --------------------------------
RUNTIME="${RUNTIME}" NODE_NAME="${NODE_NAME}" python3 - \
  "${BEFORE_FILE}" "${AFTER_FILE}" "${COUNT}" "${SETTLE_S}" \
  >> "${OVERHEAD_JSONL}" <<'PYEOF'
import datetime as dt
import json
import os
import sys


def load(path):
    vals = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if "=" in line:
                key, _, val = line.partition("=")
                vals[key] = float(val)
    return vals


before = load(sys.argv[1])
after = load(sys.argv[2])
count = int(sys.argv[3])
settle_s = int(sys.argv[4])

KB = 1024.0
MB = 1e6


def per_pod_mb(delta_kb):
    return round(delta_kb * KB / MB / count, 2)


memavail_delta_kb = before["memavailable_kb"] - after["memavailable_kb"]
vmm_delta_kb = (after.get("qemu_rss_kb", 0) + after.get("virtiofsd_rss_kb", 0)) - (
    before.get("qemu_rss_kb", 0) + before.get("virtiofsd_rss_kb", 0)
)
conmon_delta_kb = after.get("conmon_rss_kb", 0) - before.get("conmon_rss_kb", 0)

metrics = {
    "memavailable_delta_mb_per_pod": per_pod_mb(memavail_delta_kb),
    "vmm_rss_mb_per_pod": per_pod_mb(vmm_delta_kb),
    "conmon_rss_mb_per_pod": per_pod_mb(conmon_delta_kb),
}

print(json.dumps({
    "suite": "overhead",
    "test": "per-pod-memory",
    "runtime": os.environ.get("RUNTIME", ""),
    "node": os.environ.get("NODE_NAME", ""),
    "timestamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "iteration": 1,
    "parameters": {
        "pod_count": count,
        "settle_s": settle_s,
        "pod_size": "500m/512Mi",
        "before": before,
        "after": after,
        "note": "MemAvailable is a kernel estimate; RSS deltas are the more stable signal",
    },
    "metrics": metrics,
    "units": {k: "MB" for k in metrics},
}, separators=(",", ":")))

sys.stderr.write(
    "\nPer-pod node-side memory over %d pod(s):\n"
    "  memavailable_delta_mb_per_pod : %8.2f MB  (whole-node view, noisy)\n"
    "  vmm_rss_mb_per_pod            : %8.2f MB  (qemu + virtiofsd — kata VMM cost)\n"
    "  conmon_rss_mb_per_pod         : %8.2f MB  (crun-side per-pod helper)\n\n"
    % (
        count,
        metrics["memavailable_delta_mb_per_pod"],
        metrics["vmm_rss_mb_per_pod"],
        metrics["conmon_rss_mb_per_pod"],
    )
)
PYEOF

rm -f "${BEFORE_FILE}" "${AFTER_FILE}"

log "wrote $(wc -l < "${OVERHEAD_JSONL}" | tr -d '[:space:]') result line(s) -> ${OVERHEAD_JSONL}"

case "${RUNTIME}" in
  crun)
    log "crun run: vmm_rss_mb_per_pod should be ~0; the per-pod floor is conmon + pause"
    ;;
  *)
    log "kata-family run: vmm_rss_mb_per_pod is the per-pod VMM floor; compare it with the"
    log "RuntimeClass scheduler estimate: oc get runtimeclass ${RUNTIME} -o jsonpath='{.overhead.podFixed}'"
    ;;
esac

log "caveat: MemAvailable moves with page cache and unrelated node activity — repeat this"
log "measurement several times on a quiet node and compare crun vs kata deltas, not absolutes"
log "done — compare against another runtime with:"
log "  python3 ${REPO_ROOT}/scripts/parse-results.py results/<baseline-run-dir> ${RUN_DIR}"
