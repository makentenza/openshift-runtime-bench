#!/usr/bin/env bash
# =============================================================================
# lib.sh — shared library for openshift-runtime-bench workstation scripts.
#
# Sourced by run-suite.sh, measure-startup.sh, and measure-overhead.sh.
# Portable across macOS (bash 3.2, BSD userland) and Linux: no GNU-only flags
# (no `date -d`, no `readlink -f`, no `sed -i`); python3 handles date and
# statistics math.
# =============================================================================

# Guard against double-sourcing.
if [ -n "${_RTB_LIB_SOURCED:-}" ]; then
  return 0
fi
_RTB_LIB_SOURCED=1

# Strict mode for every script that sources this library.
set -euo pipefail

# --- Locations ---------------------------------------------------------------
# Repo root = parent of the directory containing this file, resolved without
# readlink -f (unavailable on macOS).
RTB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${RTB_LIB_DIR}/.." && pwd)"
MANIFEST_DIR="${REPO_ROOT}/manifests"
export REPO_ROOT MANIFEST_DIR

# --- Logging (all to stderr; stdout is reserved for data) ---------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _RTB_CYN=$'\033[0;36m'
  _RTB_YEL=$'\033[0;33m'
  _RTB_RED=$'\033[0;31m'
  _RTB_RST=$'\033[0m'
else
  _RTB_CYN=""
  _RTB_YEL=""
  _RTB_RED=""
  _RTB_RST=""
fi

log()  { printf '%s[bench]%s %s\n'        "${_RTB_CYN}" "${_RTB_RST}" "$*" >&2; }
warn() { printf '%s[bench] WARN:%s %s\n'  "${_RTB_YEL}" "${_RTB_RST}" "$*" >&2; }
die()  { printf '%s[bench] ERROR:%s %s\n' "${_RTB_RED}" "${_RTB_RST}" "$*" >&2; exit 1; }

# is_pos_int VALUE — true when VALUE is a non-empty string of digits.
is_pos_int() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# --- Prerequisites -------------------------------------------------------------
# require_cmds CMD... — verify each command exists; print actionable install
# hints for anything missing, then fail.
require_cmds() {
  local missing=0 cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing=1
      case "$cmd" in
        oc)
          warn "'oc' not found. Install the OpenShift CLI:"
          warn "  macOS : brew install openshift-cli"
          warn "  Linux : https://mirror.openshift.com/pub/openshift-v4/clients/ocp/ (extract oc into your PATH)"
          ;;
        envsubst)
          warn "'envsubst' not found (it ships with gettext). Install:"
          warn "  macOS        : brew install gettext"
          warn "  Fedora/RHEL  : sudo dnf install gettext"
          warn "  Debian/Ubuntu: sudo apt install gettext-base"
          ;;
        python3)
          warn "'python3' not found. Install:"
          warn "  macOS        : brew install python  (or xcode-select --install)"
          warn "  Fedora/RHEL  : sudo dnf install python3"
          warn "  Debian/Ubuntu: sudo apt install python3"
          ;;
        jq)
          warn "'jq' not found. Install:"
          warn "  macOS: brew install jq | Fedora/RHEL: sudo dnf install jq | Debian/Ubuntu: sudo apt install jq"
          ;;
        *)
          warn "'$cmd' not found — install it and re-run."
          ;;
      esac
    fi
  done
  if [ "$missing" -ne 0 ]; then
    die "missing prerequisite command(s) — see install hints above"
  fi
}

# --- Local overrides + defaults ------------------------------------------------
# scripts/env.sh (gitignored; see scripts/env.example.sh) is sourced first so
# its exports win over the built-in defaults below.
if [ -f "${RTB_LIB_DIR}/env.sh" ]; then
  # shellcheck source=/dev/null
  . "${RTB_LIB_DIR}/env.sh"
fi

NAMESPACE="${NAMESPACE:-runtime-bench}"
BENCH_IMAGE="${BENCH_IMAGE:-image-registry.openshift-image-registry.svc:5000/runtime-bench/runtime-bench:latest}"
BENCH_CPU="${BENCH_CPU:-2}"
BENCH_MEMORY="${BENCH_MEMORY:-4Gi}"
PVC_SIZE="${PVC_SIZE:-10Gi}"
ITERATIONS="${ITERATIONS:-3}"
DURATION="${DURATION:-30}"
STORAGE_CLASS="${STORAGE_CLASS:-}"

RUNTIME="${RUNTIME:-}"
SERVER_RUNTIME="${SERVER_RUNTIME:-crun}"
NODE_NAME="${NODE_NAME:-}"
SERVER_NODE_NAME="${SERVER_NODE_NAME:-}"
SERVER_HOST="${SERVER_HOST:-}"
POD_NAME="${POD_NAME:-}"
RUNTIME_CLASS_SPEC="${RUNTIME_CLASS_SPEC:-}"
SERVER_RUNTIME_CLASS_SPEC="${SERVER_RUNTIME_CLASS_SPEC:-}"
STORAGE_CLASS_SPEC="${STORAGE_CLASS_SPEC:-}"
RUN_LABEL="${RUN_LABEL:-run}"

# --- Template rendering ----------------------------------------------------------
# Explicit allowlist: envsubst substitutes ONLY these variables, so stray
# dollar signs anywhere in the manifests are never mangled.
# shellcheck disable=SC2016
RENDER_VARS='${NAMESPACE} ${BENCH_IMAGE} ${RUNTIME} ${RUNTIME_CLASS_SPEC} ${NODE_NAME} ${SERVER_RUNTIME} ${SERVER_RUNTIME_CLASS_SPEC} ${SERVER_NODE_NAME} ${SERVER_HOST} ${BENCH_CPU} ${BENCH_MEMORY} ${STORAGE_CLASS_SPEC} ${PVC_SIZE} ${ITERATIONS} ${DURATION} ${POD_NAME}'

# derive_runtime_spec — turn RUNTIME / SERVER_RUNTIME / STORAGE_CLASS into the
# *_SPEC template fragments and export everything envsubst needs.
#   RUNTIME=crun         -> RUNTIME_CLASS_SPEC=""  (cluster default runtime,
#                           no runtimeClassName line rendered)
#   RUNTIME=<anything>   -> RUNTIME_CLASS_SPEC="runtimeClassName: <RUNTIME>"
# Unknown runtime values get a warning (not an error) so new RuntimeClasses can
# be exercised without editing this library.
derive_runtime_spec() {
  case "${RUNTIME}" in
    '')
      die "RUNTIME is not set — pass --runtime crun|kata|kata-remote|kata-cc"
      ;;
    crun)
      RUNTIME_CLASS_SPEC=""
      ;;
    kata | kata-remote | kata-cc)
      RUNTIME_CLASS_SPEC="runtimeClassName: ${RUNTIME}"
      ;;
    *)
      warn "RUNTIME='${RUNTIME}' is not one of crun|kata|kata-remote|kata-cc — using it as a RuntimeClass name anyway"
      RUNTIME_CLASS_SPEC="runtimeClassName: ${RUNTIME}"
      ;;
  esac

  case "${SERVER_RUNTIME}" in
    '' | crun)
      SERVER_RUNTIME="${SERVER_RUNTIME:-crun}"
      SERVER_RUNTIME_CLASS_SPEC=""
      ;;
    kata | kata-remote | kata-cc)
      SERVER_RUNTIME_CLASS_SPEC="runtimeClassName: ${SERVER_RUNTIME}"
      ;;
    *)
      warn "SERVER_RUNTIME='${SERVER_RUNTIME}' is not one of crun|kata|kata-remote|kata-cc — using it as a RuntimeClass name anyway"
      SERVER_RUNTIME_CLASS_SPEC="runtimeClassName: ${SERVER_RUNTIME}"
      ;;
  esac

  if [ -n "${STORAGE_CLASS}" ]; then
    STORAGE_CLASS_SPEC="storageClassName: ${STORAGE_CLASS}"
  else
    STORAGE_CLASS_SPEC=""
  fi

  export NAMESPACE BENCH_IMAGE RUNTIME RUNTIME_CLASS_SPEC NODE_NAME \
    SERVER_RUNTIME SERVER_RUNTIME_CLASS_SPEC SERVER_NODE_NAME SERVER_HOST \
    BENCH_CPU BENCH_MEMORY STORAGE_CLASS_SPEC PVC_SIZE ITERATIONS DURATION \
    POD_NAME
}

# render FILE — envsubst the manifest to stdout using the allowlist.
render() {
  local file="$1"
  if [ ! -f "$file" ]; then
    die "manifest not found: ${file}"
  fi
  # Re-export in case a caller mutated a variable (e.g. POD_NAME, SERVER_HOST)
  # after derive_runtime_spec ran.
  export NAMESPACE BENCH_IMAGE RUNTIME RUNTIME_CLASS_SPEC NODE_NAME \
    SERVER_RUNTIME SERVER_RUNTIME_CLASS_SPEC SERVER_NODE_NAME SERVER_HOST \
    BENCH_CPU BENCH_MEMORY STORAGE_CLASS_SPEC PVC_SIZE ITERATIONS DURATION \
    POD_NAME
  envsubst "${RENDER_VARS}" < "$file"
}

# apply_manifest FILE — render and apply.
apply_manifest() {
  local file="$1"
  log "apply: ${file}"
  render "$file" | oc apply -f -
}

# delete_manifest FILE — render and delete every object in it; never fatal.
delete_manifest() {
  local file="$1"
  log "delete: ${file}"
  render "$file" | oc delete --ignore-not-found -f - \
    || warn "delete of objects from ${file} reported errors (continuing)"
}

# --- Cluster helpers -------------------------------------------------------------

# verify_runtime_class RUNTIME — ensure the RuntimeClass exists on the cluster
# (skipped for crun, which uses the cluster default runtime, no RuntimeClass).
verify_runtime_class() {
  local rt="$1"
  if [ "$rt" = "crun" ]; then
    return 0
  fi
  if ! oc get runtimeclass "$rt" >/dev/null 2>&1; then
    warn "RuntimeClass '${rt}' not found on this cluster. Available RuntimeClasses:"
    oc get runtimeclass >&2 2>/dev/null || warn "  (none listed, or no permission to list them)"
    die "RuntimeClass '${rt}' does not exist — install the OpenShift sandboxed containers operator and apply a KataConfig (or the equivalent that provides '${rt}') first"
  fi
}

# check_node_exists NODE DESCRIPTION — ensure the node exists; on failure list
# the available nodes so the caller can pick one.
check_node_exists() {
  local node="$1" what="${2:-node}"
  if ! oc get node "$node" >/dev/null 2>&1; then
    warn "${what} '${node}' not found. Available nodes:"
    oc get nodes -o wide >&2 || true
    die "${what} '${node}' does not exist on this cluster"
  fi
}

# wait_job NAME TIMEOUT_S — poll the Job's conditions every 5s until Complete,
# Failed, or timeout. On Failed/timeout: dump describe + logs, return 1.
wait_job() {
  local name="$1" timeout="$2"
  local waited=0 conditions=""
  log "waiting for job/${name} (timeout ${timeout}s)"
  while :; do
    conditions="$(oc -n "${NAMESPACE}" get job "$name" \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' \
      2>/dev/null || true)"
    case "$conditions" in
      *Complete=True*)
        log "job/${name} completed after ~${waited}s"
        return 0
        ;;
    esac
    case "$conditions" in
      *Failed=True*)
        warn "job/${name} FAILED — diagnostics follow"
        _rtb_dump_job_diag "$name"
        return 1
        ;;
    esac
    if [ "$waited" -ge "$timeout" ]; then
      warn "job/${name} did not finish within ${timeout}s — diagnostics follow"
      _rtb_dump_job_diag "$name"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

_rtb_dump_job_diag() {
  local name="$1"
  {
    echo "----- oc describe job/${name} -----"
    oc -n "${NAMESPACE}" describe job "$name" || true
    echo "----- last logs of job/${name} -----"
    oc -n "${NAMESPACE}" logs "job/${name}" --all-containers --tail=100 || true
    echo "------------------------------------"
  } >&2
}

# collect_job NAME SUITE OUTDIR — extract RESULT_JSON lines from the job's logs
# into OUTDIR/SUITE.jsonl. An empty result is a warning, never a script kill.
collect_job() {
  local name="$1" suite="$2" outdir="$3"
  local out="${outdir}/${suite}.jsonl"
  oc -n "${NAMESPACE}" logs "job/${name}" --all-containers 2>/dev/null \
    | { grep '^RESULT_JSON ' || true; } \
    | sed 's/^RESULT_JSON //' > "$out" \
    || true
  if [ -s "$out" ]; then
    local n
    n="$(wc -l < "$out" | tr -d '[:space:]')"
    log "collected ${n} result line(s) -> ${out}"
  else
    warn "no RESULT_JSON lines found in logs of job/${name} (${out} is empty)"
  fi
}

# wait_deploy NAME TIMEOUT_S — wait for a Deployment rollout; dump diagnostics
# and return 1 on failure.
wait_deploy() {
  local name="$1" timeout="$2"
  log "waiting for deployment/${name} rollout (timeout ${timeout}s)"
  if ! oc -n "${NAMESPACE}" rollout status "deployment/${name}" --timeout="${timeout}s"; then
    warn "deployment/${name} did not become ready — diagnostics follow"
    {
      oc -n "${NAMESPACE}" describe deployment "$name" || true
      oc -n "${NAMESPACE}" get pods -l app=runtime-bench -o wide || true
    } >&2
    return 1
  fi
}

# get_pod_ip LABEL_SELECTOR — print the podIP of the first Running pod matching
# the selector. Retries for up to 60s; returns 1 if none is found.
get_pod_ip() {
  local selector="$1" tries=0 out="" first=""
  while [ "$tries" -lt 12 ]; do
    out="$(oc -n "${NAMESPACE}" get pods -l "$selector" \
      -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.status.podIP}{"\n"}{end}' \
      2>/dev/null || true)"
    first="${out%%$'\n'*}"
    if [ -n "$first" ]; then
      printf '%s\n' "$first"
      return 0
    fi
    sleep 5
    tries=$((tries + 1))
  done
  return 1
}

# record_metadata OUTDIR — snapshot node + run identity into OUTDIR/metadata.json.
# Reads NODE_NAME, RUNTIME, RUN_LABEL from the environment set by the caller.
record_metadata() {
  local outdir="$1"
  [ -n "${NODE_NAME:-}" ] || die "record_metadata: NODE_NAME is not set"
  log "recording node metadata for ${NODE_NAME} -> ${outdir}/metadata.json"
  oc get node "${NODE_NAME}" -o json \
    | RUNTIME="${RUNTIME}" RUN_LABEL="${RUN_LABEL}" python3 -c '
import datetime, json, os, sys

node = json.load(sys.stdin)
labels = node.get("metadata", {}).get("labels", {})
info = node.get("status", {}).get("nodeInfo", {})
cap = node.get("status", {}).get("capacity", {})
meta = {
    "node": node.get("metadata", {}).get("name", ""),
    "instance_type": labels.get("node.kubernetes.io/instance-type", "unknown"),
    "region": labels.get("topology.kubernetes.io/region", "unknown"),
    "zone": labels.get("topology.kubernetes.io/zone", "unknown"),
    "kernelVersion": info.get("kernelVersion", ""),
    "osImage": info.get("osImage", ""),
    "containerRuntimeVersion": info.get("containerRuntimeVersion", ""),
    "kubeletVersion": info.get("kubeletVersion", ""),
    "cpu_capacity": cap.get("cpu", ""),
    "memory_capacity": cap.get("memory", ""),
    "runtime": os.environ.get("RUNTIME", ""),
    "label": os.environ.get("RUN_LABEL", ""),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(sys.argv[1], "w") as fh:
    json.dump(meta, fh, indent=2)
    fh.write("\n")
' "${outdir}/metadata.json"
}

# new_run_dir LABEL RUNTIME — create and echo results/<LABEL>-<RUNTIME>-<stamp>
# under the repo root. `date -u +...` is portable across BSD and GNU.
new_run_dir() {
  local label="$1" runtime="$2" stamp dir
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  dir="${REPO_ROOT}/results/${label}-${runtime}-${stamp}"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}
