#!/usr/bin/env bash
#
# run-memory.sh — memory benchmark suite.
#
# Sub-tests per iteration:
#   sysbench-mem-write-seq — sequential 4K writes (bandwidth)
#   sysbench-mem-read-seq  — sequential 4K reads (bandwidth)
#   sysbench-mem-write-rnd — random 4K writes (bandwidth)
#   stress-ng-stream       — STREAM-like sustained memory bandwidth
#   stress-ng-fault        — page-fault rate; pure guest-kernel work under
#                            kata, so it should be near-native. A large
#                            deviation is diagnostic (e.g. EPT/NPT or memory
#                            backend issues), not generic runtime overhead.
#
# Env: RUNTIME, NODE_NAME, ITERATIONS, DURATION, THREADS (see common.sh for
# defaults). Invoke as /bench/run-memory.sh with env vars only.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

SNG_YAML=/tmp/sng.yaml

# ---------------------------------------------------------------------------
# sysbench memory
# ---------------------------------------------------------------------------
run_sysbench_memory() {
  local iter=$1 test_name=$2 oper=$3 access_mode=$4
  log "[memory][iter ${iter}] ${test_name}: sysbench memory oper=${oper} access=${access_mode} threads=${THREADS} time=${DURATION}s"

  local out
  if ! out=$(sysbench memory run \
    --threads="$THREADS" \
    --time="$DURATION" \
    --memory-block-size=4K \
    --memory-total-size=512G \
    --memory-oper="$oper" \
    --memory-access-mode="$access_mode" 2>&1); then
    log "ERROR: sysbench memory (${test_name}) failed:"
    printf '%s\n' "$out" >&2
    exit 1
  fi
  printf '%s\n' "$out" >&2

  # Line looks like: "48234.68 MiB transferred (1607.51 MiB/sec)"
  local mibs
  mibs=$(awk '/MiB transferred/ {gsub(/[()]/, "", $4); print $4; exit}' <<< "$out")
  require_number throughput_mib_s "$mibs"

  local params metrics units
  params=$(jq -c -n \
    --arg oper "$oper" \
    --arg access "$access_mode" \
    --argjson threads "$THREADS" \
    --argjson duration "$DURATION" \
    '{oper: $oper, access_mode: $access, block_size: "4K",
      total_size: "512G", threads: $threads, duration_s: $duration}')
  metrics=$(jq -c -n --argjson t "$mibs" '{throughput_mib_s: $t}')
  units='{"throughput_mib_s":"MiB/s"}'
  emit_result memory "$test_name" "$iter" "$params" "$metrics" "$units"
}

# ---------------------------------------------------------------------------
# stress-ng --stream (memory bandwidth) with bogo-ops fallback
# ---------------------------------------------------------------------------
run_stress_ng_stream() {
  local iter=$1
  log "[memory][iter ${iter}] stress-ng --stream ${THREADS} for ${DURATION}s"

  rm -f "$SNG_YAML"
  local rc=0
  stress-ng --stream "$THREADS" -t "${DURATION}s" --metrics -Y "$SNG_YAML" >&2 || rc=$?
  if ((rc != 0)); then
    log "WARNING: stress-ng --stream exited ${rc}; attempting to parse metrics anyway"
  fi

  local rate metric_source metrics units
  rate=$(sng_memory_rate_mb_s "$SNG_YAML")
  if is_number "$rate"; then
    metric_source="stream-memory-rate"
    metrics=$(jq -c -n --argjson r "$rate" '{memory_rate_mb_s: $r}')
    units='{"memory_rate_mb_s":"MB/s"}'
  else
    log "NOTE: stream memory-rate not found in stress-ng YAML; falling back to bogo-ops rate"
    local bogo
    bogo=$(sng_bogo_ops_per_sec "$SNG_YAML")
    if ! is_number "$bogo"; then
      log "ERROR: could not parse memory rate nor bogo-ops rate from ${SNG_YAML} for --stream (exit ${rc})"
      exit 1
    fi
    metric_source="bogo-ops-per-second-real-time"
    metrics=$(jq -c -n --argjson b "$bogo" '{bogo_ops_per_sec_real: $b}')
    units='{"bogo_ops_per_sec_real":"bogo-ops/s"}'
  fi

  local params
  params=$(jq -c -n \
    --arg source "$metric_source" \
    --argjson threads "$THREADS" \
    --argjson duration "$DURATION" \
    --argjson rc "$rc" \
    '{stressor: "stream", metric_source: $source, threads: $threads,
      duration_s: $duration, stress_ng_exit: $rc}')
  emit_result memory stress-ng-stream "$iter" "$params" "$metrics" "$units"
}

# ---------------------------------------------------------------------------
# stress-ng --fault (page faults) → bogo_ops_per_sec_real
# ---------------------------------------------------------------------------
run_stress_ng_fault() {
  local iter=$1
  log "[memory][iter ${iter}] stress-ng --fault ${THREADS} for ${DURATION}s"

  rm -f "$SNG_YAML"
  local rc=0
  stress-ng --fault "$THREADS" -t "${DURATION}s" --metrics -Y "$SNG_YAML" >&2 || rc=$?
  if ((rc != 0)); then
    log "WARNING: stress-ng --fault exited ${rc}; attempting to parse metrics anyway"
  fi

  local bogo
  bogo=$(sng_bogo_ops_per_sec "$SNG_YAML")
  if ! is_number "$bogo"; then
    log "ERROR: could not parse bogo-ops-per-second-real-time from ${SNG_YAML} for --fault (exit ${rc})"
    exit 1
  fi

  local params metrics units
  params=$(jq -c -n \
    --argjson threads "$THREADS" \
    --argjson duration "$DURATION" \
    --argjson rc "$rc" \
    '{stressor: "fault", threads: $threads, duration_s: $duration,
      stress_ng_exit: $rc}')
  metrics=$(jq -c -n --argjson b "$bogo" '{bogo_ops_per_sec_real: $b}')
  units='{"bogo_ops_per_sec_real":"bogo-ops/s"}'
  emit_result memory stress-ng-fault "$iter" "$params" "$metrics" "$units"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  emit_env_info
  log "memory suite: ${ITERATIONS} iteration(s), ${DURATION}s per sub-test, ${THREADS} thread(s)"

  local iter
  for ((iter = 1; iter <= ITERATIONS; iter++)); do
    run_sysbench_memory "$iter" sysbench-mem-write-seq write seq
    run_sysbench_memory "$iter" sysbench-mem-read-seq read seq
    run_sysbench_memory "$iter" sysbench-mem-write-rnd write rnd
    run_stress_ng_stream "$iter"
    run_stress_ng_fault "$iter"
  done

  log "memory suite complete (${ITERATIONS} iteration(s))"
}

main "$@"
