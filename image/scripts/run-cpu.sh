#!/usr/bin/env bash
#
# run-cpu.sh — CPU benchmark suite.
#
# Sub-tests per iteration:
#   sysbench-cpu       — prime-number crunching (raw CPU throughput + latency)
#   stress-ng-matrix   — matrix ops (cache/FP heavy)
#   stress-ng-switch   — context switching (scheduler overhead)
#   stress-ng-syscall  — syscall overhead (vmexit-sensitive under kata)
#   stress-ng-fork     — process creation
#
# Env: RUNTIME, NODE_NAME, ITERATIONS, DURATION, THREADS (see common.sh for
# defaults). Invoke as /bench/run-cpu.sh with env vars only.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

SNG_YAML=/tmp/sng.yaml

# ---------------------------------------------------------------------------
# sysbench-cpu
# ---------------------------------------------------------------------------
run_sysbench_cpu() {
  local iter=$1
  log "[cpu][iter ${iter}] sysbench cpu: threads=${THREADS} time=${DURATION}s"

  local out
  if ! out=$(sysbench cpu run --threads="$THREADS" --time="$DURATION" 2>&1); then
    log "ERROR: sysbench cpu failed:"
    printf '%s\n' "$out" >&2
    exit 1
  fi
  printf '%s\n' "$out" >&2

  local eps lat_avg lat_p95
  eps=$(awk '/events per second:/ {print $NF; exit}' <<< "$out")
  lat_avg=$(awk '$1 == "avg:" {print $NF; exit}' <<< "$out")
  lat_p95=$(awk '/95th percentile:/ {print $NF; exit}' <<< "$out")
  require_number events_per_sec "$eps"
  require_number latency_avg_ms "$lat_avg"
  require_number latency_p95_ms "$lat_p95"

  local params metrics units
  params=$(jq -c -n \
    --argjson threads "$THREADS" \
    --argjson duration "$DURATION" \
    '{threads: $threads, duration_s: $duration}')
  metrics=$(jq -c -n \
    --argjson eps "$eps" \
    --argjson avg "$lat_avg" \
    --argjson p95 "$lat_p95" \
    '{events_per_sec: $eps, latency_avg_ms: $avg, latency_p95_ms: $p95}')
  units='{"events_per_sec":"events/s","latency_avg_ms":"ms","latency_p95_ms":"ms"}'
  emit_result cpu sysbench-cpu "$iter" "$params" "$metrics" "$units"
}

# ---------------------------------------------------------------------------
# stress-ng stressors → bogo_ops_per_sec_real
# ---------------------------------------------------------------------------
run_stress_ng_bogo() {
  local iter=$1 test_name=$2 stressor=$3
  log "[cpu][iter ${iter}] stress-ng --${stressor} ${THREADS} for ${DURATION}s"

  rm -f "$SNG_YAML"
  local rc=0
  # --temp-path /tmp: stress-ng writes scratch files to its temp path (default
  # is the cwd, which is not writable under the restricted-v2 arbitrary UID).
  stress-ng --"$stressor" "$THREADS" -t "${DURATION}s" --temp-path /tmp \
    --metrics -Y "$SNG_YAML" >&2 || rc=$?
  if ((rc != 0)); then
    # Some stressors report a non-zero exit for partial failures (e.g. the
    # syscall stressor hitting seccomp-blocked syscalls under the default
    # runtime/default profile). If the YAML metrics parse, the run is usable.
    log "WARNING: stress-ng --${stressor} exited ${rc}; attempting to parse metrics anyway"
  fi

  local bogo
  bogo=$(sng_bogo_ops_per_sec "$SNG_YAML")
  if ! is_number "$bogo"; then
    log "ERROR: could not parse bogo-ops-per-second-real-time from ${SNG_YAML} for --${stressor} (exit ${rc})"
    exit 1
  fi

  local params metrics units
  params=$(jq -c -n \
    --arg stressor "$stressor" \
    --argjson threads "$THREADS" \
    --argjson duration "$DURATION" \
    --argjson rc "$rc" \
    '{stressor: $stressor, threads: $threads, duration_s: $duration,
      stress_ng_exit: $rc}')
  metrics=$(jq -c -n --argjson bogo "$bogo" '{bogo_ops_per_sec_real: $bogo}')
  units='{"bogo_ops_per_sec_real":"bogo-ops/s"}'
  emit_result cpu "$test_name" "$iter" "$params" "$metrics" "$units"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  emit_env_info
  log "cpu suite: ${ITERATIONS} iteration(s), ${DURATION}s per sub-test, ${THREADS} thread(s)"

  local iter
  for ((iter = 1; iter <= ITERATIONS; iter++)); do
    run_sysbench_cpu "$iter"
    run_stress_ng_bogo "$iter" stress-ng-matrix matrix
    run_stress_ng_bogo "$iter" stress-ng-switch switch
    run_stress_ng_bogo "$iter" stress-ng-syscall syscall
    run_stress_ng_bogo "$iter" stress-ng-fork fork
  done

  log "cpu suite complete (${ITERATIONS} iteration(s))"
}

main "$@"
