#!/usr/bin/env bash
# =============================================================================
# run-suite.sh — orchestrate the benchmark suites for one node/runtime combo.
#
# Renders the envsubst-templated manifests, runs the requested suites as Jobs
# pinned to a node, collects RESULT_JSON lines from the pod logs into a
# timestamped directory under results/, and cleans up.
#
# Typical comparison workflow (same node, two runtimes):
#   scripts/run-suite.sh --runtime crun --node worker-0 --label gcp
#   scripts/run-suite.sh --runtime kata --node worker-0 --label gcp
#   python3 scripts/parse-results.py results/gcp-crun-<ts> results/gcp-kata-<ts>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/run-suite.sh --runtime RUNTIME --node NODE [options]

Run benchmark suites against one node/runtime combination and collect the
RESULT_JSON output into a timestamped directory under results/.

Required:
  --runtime RT         crun | kata | kata-remote | kata-cc
                       'crun' = no runtimeClassName (cluster default runtime)
  --node NODE          node to pin benchmark pods to (kubernetes.io/hostname)

Suite selection:
  --benchmarks CSV     comma-separated subset of: cpu,memory,disk,network,app
                       (default: cpu,memory,disk,network,app)
  --pvc                also run the PVC-backed (Filesystem) disk job
  --block              also run the raw-block PVC disk job
  --storage-class SC   StorageClass for --pvc/--block PVCs
                       (default: cluster default StorageClass)
  --podvm-instance-type TYPE
                       kata-remote only: pin the peer-pods pod-VM cloud instance
                       type (e.g. t3.large) instead of letting the Cloud API
                       Adaptor auto-select. Use when the adaptor's instance-type
                       list can pick an architecture that mismatches the pod-VM
                       image. Ignored for crun/kata.

Network/app topology:
  --server-node NODE   node for the iperf3/nginx server pods (default: same
                       as --node -> same-node test; pass a different node
                       for the cross-node path)
  --server-runtime RT  runtime for the server pods (default: crun)

Run parameters:
  --label LABEL        run label used in the results dir name, e.g. gcp, aws
                       (default: run)
  --namespace NS       namespace (default: runtime-bench)
  --iterations N       iterations per sub-test, passed to pods (default: 3)
  --duration S         seconds per sub-test, passed to pods (default: 30)
  --keep               keep jobs/servers/PVCs after collection (default:
                       delete everything the suite created)
  -h, --help           show this help

Environment: every flag has an env equivalent (RUNTIME, NODE_NAME, BENCHMARKS,
RUN_PVC=1, RUN_BLOCK=1, STORAGE_CLASS, SERVER_NODE_NAME, SERVER_RUNTIME,
RUN_LABEL, NAMESPACE, ITERATIONS, DURATION, KEEP=1). Flags override env; see
scripts/env.example.sh for persistent configuration.

Examples:
  # Baseline (crun) then candidate (kata) on the same node:
  scripts/run-suite.sh --runtime crun --node worker-0 --label gcp
  scripts/run-suite.sh --runtime kata --node worker-0 --label gcp

  # Cross-node network path with PVC-backed disk tests:
  scripts/run-suite.sh --runtime kata --node worker-0 --server-node worker-1 \
    --pvc --storage-class ssd-csi --label gcp
EOF
}

# --- Flag parsing (env provides defaults; flags win) ---------------------------
BENCHMARKS="${BENCHMARKS:-cpu,memory,disk,network,app}"
RUN_PVC="${RUN_PVC:-0}"
RUN_BLOCK="${RUN_BLOCK:-0}"
KEEP="${KEEP:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime)        RUNTIME="${2:?--runtime needs a value}"; shift 2 ;;
    --node)           NODE_NAME="${2:?--node needs a value}"; shift 2 ;;
    --benchmarks)     BENCHMARKS="${2:?--benchmarks needs a value}"; shift 2 ;;
    --pvc)            RUN_PVC=1; shift ;;
    --block)          RUN_BLOCK=1; shift ;;
    --storage-class)  STORAGE_CLASS="${2:?--storage-class needs a value}"; shift 2 ;;
    --podvm-instance-type) POD_VM_INSTANCE_TYPE="${2:?--podvm-instance-type needs a value}"; shift 2 ;;
    --server-node)    SERVER_NODE_NAME="${2:?--server-node needs a value}"; shift 2 ;;
    --server-runtime) SERVER_RUNTIME="${2:?--server-runtime needs a value}"; shift 2 ;;
    --label)          RUN_LABEL="${2:?--label needs a value}"; shift 2 ;;
    --namespace)      NAMESPACE="${2:?--namespace needs a value}"; shift 2 ;;
    --iterations)     ITERATIONS="${2:?--iterations needs a value}"; shift 2 ;;
    --duration)       DURATION="${2:?--duration needs a value}"; shift 2 ;;
    --keep)           KEEP=1; shift ;;
    -h | --help)      usage; exit 0 ;;
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
is_pos_int "${ITERATIONS}" || die "--iterations must be a positive integer (got '${ITERATIONS}')"
is_pos_int "${DURATION}"   || die "--duration must be a positive integer (got '${DURATION}')"

if ! oc whoami >/dev/null 2>&1; then
  die "not logged in to a cluster ('oc whoami' failed) — run 'oc login' first"
fi
log "cluster: $(oc whoami --show-server 2>/dev/null || echo '?') as $(oc whoami)"

check_node_exists "${NODE_NAME}" "--node"
SERVER_NODE_NAME="${SERVER_NODE_NAME:-${NODE_NAME}}"
if [ "${SERVER_NODE_NAME}" != "${NODE_NAME}" ]; then
  check_node_exists "${SERVER_NODE_NAME}" "--server-node"
fi

derive_runtime_spec
verify_runtime_class "${RUNTIME}"
case ",${BENCHMARKS}," in
  *,network,* | *,app,*)
    verify_runtime_class "${SERVER_RUNTIME}"
    ;;
esac

# --- Namespace + run directory ---------------------------------------------------
apply_manifest "${MANIFEST_DIR}/namespace.yaml"

RUN_DIR="$(new_run_dir "${RUN_LABEL}" "${RUNTIME}")"
log "run directory: ${RUN_DIR}"
record_metadata "${RUN_DIR}"

# Generous per-job timeout: every sub-test runs ITERATIONS x DURATION, plus
# scheduling/boot/setup headroom (kata pods boot a VM first).
JOB_TIMEOUT=$((ITERATIONS * DURATION * 8 + 300))
FAILED_SUITES=""

# --- Suite helpers ---------------------------------------------------------------

# run_batch_suite JOB_NAME MANIFEST OUT_SUITE — the delete/apply/wait/collect/
# cleanup cycle shared by cpu, memory, and all disk variants. Multi-doc
# manifests (PVC + Job) are handled as a unit, so stale PVCs are recreated
# fresh and removed on cleanup unless --keep.
run_batch_suite() {
  local job="$1" manifest="$2" out_suite="$3"
  log "=== suite: ${out_suite} — job/${job} on ${NODE_NAME} (runtime=${RUNTIME}) ==="
  delete_manifest "$manifest"   # remove stale objects from earlier runs
  apply_manifest "$manifest"
  if wait_job "$job" "${JOB_TIMEOUT}"; then
    collect_job "$job" "$out_suite" "${RUN_DIR}"
  else
    FAILED_SUITES="${FAILED_SUITES} ${out_suite}"
    warn "suite '${out_suite}' failed — continuing with the remaining suites"
  fi
  if [ "${KEEP}" -eq 0 ]; then
    delete_manifest "$manifest"
  else
    log "--keep: leaving objects from ${manifest} in place"
  fi
}

suite_disk() {
  run_batch_suite "bench-disk-emptydir-${RUNTIME}" \
    "${MANIFEST_DIR}/jobs/disk-emptydir-job.yaml" disk-emptydir
  if [ "${RUN_PVC}" -eq 1 ]; then
    run_batch_suite "bench-disk-pvc-${RUNTIME}" \
      "${MANIFEST_DIR}/jobs/disk-pvc-job.yaml" disk-pvc
  fi
  if [ "${RUN_BLOCK}" -eq 1 ]; then
    run_batch_suite "bench-disk-block-${RUNTIME}" \
      "${MANIFEST_DIR}/jobs/disk-block-job.yaml" disk-block
  fi
}

# run_client_server_suite SUITE SERVER_MANIFEST SERVER_DEPLOY CLIENT_MANIFEST
#                         CLIENT_JOB SELECTOR
# Shared network/app flow: server up -> pod IP -> client job -> collect ->
# cleanup. Clients target the server POD IP directly (no Service) to keep
# kube-proxy/OVN service DNAT out of the measured path.
run_client_server_suite() {
  local suite="$1" server_manifest="$2" server_deploy="$3"
  local client_manifest="$4" client_job="$5" selector="$6"
  log "=== suite: ${suite} — server on ${SERVER_NODE_NAME} (runtime=${SERVER_RUNTIME}), client on ${NODE_NAME} (runtime=${RUNTIME}) ==="

  delete_manifest "$client_manifest"   # stale client job from earlier runs
  delete_manifest "$server_manifest"   # stale server from earlier runs
  apply_manifest "$server_manifest"

  if ! wait_deploy "$server_deploy" 300; then
    FAILED_SUITES="${FAILED_SUITES} ${suite}"
    warn "suite '${suite}' failed: server never became ready"
    if [ "${KEEP}" -eq 0 ]; then delete_manifest "$server_manifest"; fi
    return 0
  fi

  SERVER_HOST="$(get_pod_ip "$selector" || true)"
  if [ -z "${SERVER_HOST}" ]; then
    FAILED_SUITES="${FAILED_SUITES} ${suite}"
    warn "suite '${suite}' failed: could not resolve a Running server pod IP (selector: ${selector})"
    if [ "${KEEP}" -eq 0 ]; then delete_manifest "$server_manifest"; fi
    return 0
  fi
  export SERVER_HOST
  log "server pod IP: ${SERVER_HOST}"

  apply_manifest "$client_manifest"
  if wait_job "$client_job" "${JOB_TIMEOUT}"; then
    collect_job "$client_job" "$suite" "${RUN_DIR}"
  else
    FAILED_SUITES="${FAILED_SUITES} ${suite}"
    warn "suite '${suite}' failed — continuing with the remaining suites"
  fi

  if [ "${KEEP}" -eq 0 ]; then
    delete_manifest "$client_manifest"
    delete_manifest "$server_manifest"
  else
    log "--keep: leaving ${suite} client and server in place"
  fi
}

suite_network() {
  run_client_server_suite network \
    "${MANIFEST_DIR}/servers/iperf3-server.yaml" \
    "iperf3-server-${SERVER_RUNTIME}" \
    "${MANIFEST_DIR}/jobs/network-client-job.yaml" \
    "bench-network-client-${RUNTIME}" \
    "app=runtime-bench,bench=network,runtime=${SERVER_RUNTIME}"
}

suite_app() {
  run_client_server_suite app \
    "${MANIFEST_DIR}/servers/nginx-server.yaml" \
    "nginx-server-${SERVER_RUNTIME}" \
    "${MANIFEST_DIR}/jobs/app-client-job.yaml" \
    "bench-app-client-${RUNTIME}" \
    "app=runtime-bench,bench=app,runtime=${SERVER_RUNTIME}"
}

# --- Run the requested suites ------------------------------------------------------
IFS=',' read -r -a SUITE_LIST <<< "${BENCHMARKS}"
for suite in "${SUITE_LIST[@]}"; do
  case "$suite" in
    cpu)
      run_batch_suite "bench-cpu-${RUNTIME}" "${MANIFEST_DIR}/jobs/cpu-job.yaml" cpu
      ;;
    memory)
      run_batch_suite "bench-memory-${RUNTIME}" "${MANIFEST_DIR}/jobs/memory-job.yaml" memory
      ;;
    disk)
      suite_disk
      ;;
    network)
      suite_network
      ;;
    app)
      suite_app
      ;;
    '')
      ;;
    *)
      warn "unknown benchmark suite '${suite}' — skipping (valid: cpu,memory,disk,network,app)"
      ;;
  esac
done

# --- Summary ---------------------------------------------------------------------
log "run finished — results in ${RUN_DIR}:"
ls -l "${RUN_DIR}" >&2 || true

cat >&2 <<EOF

Next steps:
  # summarize this run
  python3 "${REPO_ROOT}/scripts/parse-results.py" "${RUN_DIR}"

  # compare against a baseline run (baseline dir first):
  python3 "${REPO_ROOT}/scripts/parse-results.py" results/<baseline-run-dir> "${RUN_DIR}" --csv comparison.csv
EOF

if [ -n "${FAILED_SUITES}" ]; then
  die "some suites failed:${FAILED_SUITES}"
fi
log "all requested suites completed successfully"
