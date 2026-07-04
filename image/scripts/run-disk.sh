#!/usr/bin/env bash
#
# run-disk.sh — disk I/O benchmark suite (fio).
#
# Target modes (TARGET_MODE):
#   fs    (default) — benchmark a file on a mounted filesystem:
#                     FIO_TARGET=${TARGET_DIR}/fio.dat (TARGET_DIR default
#                     /bench-data, size 1G). Used by the emptyDir and
#                     PVC-filesystem jobs.
#   block           — benchmark a raw block device (BLOCK_DEV, default
#                     /dev/bench-block) attached via volumeDevices.
#                     DESTRUCTIVE to that device/PVC (and only that PVC).
#
# O_DIRECT handling (fs mode): under kata, filesystem volumes are typically
# passed to the guest via virtiofs, which commonly rejects O_DIRECT depending
# on its cache mode. We probe O_DIRECT support with a tiny fio run first; if
# unsupported we fall back to buffered I/O (direct=0 + end_fsync=1) and record
# parameters.io_mode=buffered vs direct so results are never silently compared
# across I/O modes. fio-fsync-4k is ALWAYS buffered (etcd-style fdatasync
# workload) regardless of the probe.
#
# Sub-tests per iteration (fio: json output, ramp_time=5, time_based,
# runtime=$DURATION, ioengine=libaio):
#   fio-randread-4k / fio-randwrite-4k   bs=4k iodepth=16 numjobs=2
#   fio-seqread-1m  / fio-seqwrite-1m    bs=1m iodepth=8  numjobs=1
#   fio-randrw-70-30-4k                  rwmixread=70, 4k profile
#   fio-fsync-4k                         write bs=4k iodepth=1 numjobs=1 fdatasync=1
#
# Env: RUNTIME, NODE_NAME, ITERATIONS, DURATION (see common.sh), plus
# TARGET_MODE / TARGET_DIR / BLOCK_DEV as above.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET_MODE=${TARGET_MODE:-fs}
TARGET_DIR=${TARGET_DIR:-/bench-data}
BLOCK_DEV=${BLOCK_DEV:-/dev/bench-block}
FIO_SIZE=${FIO_SIZE:-1G}
FIO_JSON=/tmp/fio.json
RAMP_TIME=5

FIO_TARGET=""
IO_MODE=""   # direct | buffered — resolved during setup
IO_ARGS=()   # fio flags implementing IO_MODE

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
setup_fs() {
  FIO_TARGET="${TARGET_DIR}/fio.dat"

  if [[ ! -d "$TARGET_DIR" ]]; then
    log "ERROR: target directory ${TARGET_DIR} does not exist — is the emptyDir/PVC volume mounted at ${TARGET_DIR}?"
    exit 1
  fi
  if ! touch "${TARGET_DIR}/.write-probe" 2> /dev/null; then
    log "ERROR: target directory ${TARGET_DIR} is not writable by uid $(id -u) — check fsGroup / volume permissions"
    exit 1
  fi
  rm -f "${TARGET_DIR}/.write-probe"

  # Probe O_DIRECT support with a tiny direct write.
  local probe_file="${TARGET_DIR}/.direct-probe.dat"
  log "probing O_DIRECT support on ${TARGET_DIR}"
  if fio --name=direct-probe --filename="$probe_file" --rw=write --bs=4k \
    --size=4m --direct=1 --ioengine=libaio --iodepth=1 > /dev/null 2>&1; then
    IO_MODE=direct
    IO_ARGS=(--direct=1)
    log "O_DIRECT probe: supported — running with direct=1 (io_mode=direct)"
  else
    IO_MODE=buffered
    IO_ARGS=(--direct=0 --end_fsync=1)
    log "O_DIRECT probe: NOT supported on ${TARGET_DIR} (common on virtiofs) — falling back to direct=0 with end_fsync=1 (io_mode=buffered)"
    log "NOTE: buffered read results can be inflated by the page cache; only compare results with the same parameters.io_mode"
  fi
  rm -f "$probe_file"
}

setup_block() {
  FIO_TARGET="$BLOCK_DEV"

  if [[ ! -e "$BLOCK_DEV" ]]; then
    log "ERROR: block device ${BLOCK_DEV} not found — expected via volumeDevices devicePath ${BLOCK_DEV}"
    exit 1
  fi
  log "WARNING: TARGET_MODE=block writes raw data directly to ${BLOCK_DEV} — destructive to that PVC (and only that PVC)"

  IO_MODE=direct
  IO_ARGS=(--direct=1)

  # Prefill the benchmark region so reads hit allocated blocks; freshly
  # provisioned (thin) volumes otherwise return zeroes at unrealistic speed.
  log "prefilling first ${FIO_SIZE} of ${BLOCK_DEV} before measurement (not recorded)"
  if ! fio --name=prefill --filename="$BLOCK_DEV" --rw=write --bs=1M \
    --size="$FIO_SIZE" --direct=1 --ioengine=libaio --iodepth=8 >&2; then
    log "ERROR: prefill of ${BLOCK_DEV} failed"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# fio execution and parameter helpers
# ---------------------------------------------------------------------------

# do_fio EXTRA_FIO_ARGS... — run fio with the suite-wide settings, JSON
# output into $FIO_JSON, human output to stderr.
do_fio() {
  rm -f "$FIO_JSON"
  if ! fio "$@" \
    --ioengine=libaio \
    --filename="$FIO_TARGET" \
    --size="$FIO_SIZE" \
    --time_based \
    --ramp_time="$RAMP_TIME" \
    --runtime="$DURATION" \
    --group_reporting \
    --output-format=json \
    --output="$FIO_JSON" >&2; then
    log "ERROR: fio run failed: $*"
    exit 1
  fi
}

# fio_params RW BS IODEPTH NUMJOBS IO_MODE [EXTRA_JSON]
fio_params() {
  local rw=$1 bs=$2 iodepth=$3 numjobs=$4 io_mode=$5 extra=${6:-'{}'}
  jq -c -n \
    --arg target_mode "$TARGET_MODE" \
    --arg io_mode "$io_mode" \
    --arg rw "$rw" \
    --arg bs "$bs" \
    --arg size "$FIO_SIZE" \
    --argjson iodepth "$iodepth" \
    --argjson numjobs "$numjobs" \
    --argjson runtime "$DURATION" \
    --argjson ramp "$RAMP_TIME" \
    --argjson extra "$extra" \
    '{target_mode: $target_mode, io_mode: $io_mode, rw: $rw, bs: $bs,
      iodepth: $iodepth, numjobs: $numjobs, size: $size,
      runtime_s: $runtime, ramp_time_s: $ramp} + $extra'
}

# ---------------------------------------------------------------------------
# Sub-tests
# ---------------------------------------------------------------------------

# run_rand_4k ITER TEST_NAME RW SIDE — random 4k, bs=4k iodepth=16 numjobs=2.
run_rand_4k() {
  local iter=$1 test_name=$2 rw=$3 side=$4
  log "[disk][iter ${iter}] ${test_name}: rw=${rw} bs=4k iodepth=16 numjobs=2 io_mode=${IO_MODE}"
  do_fio "${IO_ARGS[@]}" --name="$test_name" --rw="$rw" --bs=4k --iodepth=16 --numjobs=2

  local metrics
  if ! metrics=$(jq -c --arg s "$side" '{
      iops: .jobs[0][$s].iops,
      bw_mb_s: (.jobs[0][$s].bw_bytes / 1000000),
      lat_p50_ms: (.jobs[0][$s].clat_ns.percentile["50.000000"] / 1000000),
      lat_p99_ms: (.jobs[0][$s].clat_ns.percentile["99.000000"] / 1000000)
    }' "$FIO_JSON"); then
    log "ERROR: failed to extract metrics from fio JSON for ${test_name}"
    exit 1
  fi
  require_metrics_numeric "$test_name" "$metrics"

  local params
  params=$(fio_params "$rw" 4k 16 2 "$IO_MODE")
  emit_result disk "$test_name" "$iter" "$params" "$metrics" \
    '{"iops":"iops","bw_mb_s":"MB/s","lat_p50_ms":"ms","lat_p99_ms":"ms"}'
}

# run_seq_1m ITER TEST_NAME RW SIDE — sequential 1m, bs=1m iodepth=8 numjobs=1.
run_seq_1m() {
  local iter=$1 test_name=$2 rw=$3 side=$4
  log "[disk][iter ${iter}] ${test_name}: rw=${rw} bs=1m iodepth=8 numjobs=1 io_mode=${IO_MODE}"
  do_fio "${IO_ARGS[@]}" --name="$test_name" --rw="$rw" --bs=1m --iodepth=8 --numjobs=1

  local metrics
  if ! metrics=$(jq -c --arg s "$side" '{
      bw_mb_s: (.jobs[0][$s].bw_bytes / 1000000),
      iops: .jobs[0][$s].iops
    }' "$FIO_JSON"); then
    log "ERROR: failed to extract metrics from fio JSON for ${test_name}"
    exit 1
  fi
  require_metrics_numeric "$test_name" "$metrics"

  local params
  params=$(fio_params "$rw" 1m 8 1 "$IO_MODE")
  emit_result disk "$test_name" "$iter" "$params" "$metrics" \
    '{"bw_mb_s":"MB/s","iops":"iops"}'
}

# run_randrw ITER — mixed 70/30 random read/write, 4k profile.
run_randrw() {
  local iter=$1
  local test_name=fio-randrw-70-30-4k
  log "[disk][iter ${iter}] ${test_name}: rw=randrw rwmixread=70 bs=4k iodepth=16 numjobs=2 io_mode=${IO_MODE}"
  do_fio "${IO_ARGS[@]}" --name="$test_name" --rw=randrw --rwmixread=70 \
    --bs=4k --iodepth=16 --numjobs=2

  local metrics
  if ! metrics=$(jq -c '{
      read_iops: .jobs[0].read.iops,
      write_iops: .jobs[0].write.iops,
      read_lat_p99_ms: (.jobs[0].read.clat_ns.percentile["99.000000"] / 1000000),
      write_lat_p99_ms: (.jobs[0].write.clat_ns.percentile["99.000000"] / 1000000)
    }' "$FIO_JSON"); then
    log "ERROR: failed to extract metrics from fio JSON for ${test_name}"
    exit 1
  fi
  require_metrics_numeric "$test_name" "$metrics"

  local params
  params=$(fio_params randrw 4k 16 2 "$IO_MODE" '{"rwmixread": 70}')
  emit_result disk "$test_name" "$iter" "$params" "$metrics" \
    '{"read_iops":"iops","write_iops":"iops","read_lat_p99_ms":"ms","write_lat_p99_ms":"ms"}'
}

# run_fsync ITER — etcd-style fdatasync-per-write. ALWAYS buffered; the
# O_DIRECT probe result is deliberately ignored here.
run_fsync() {
  local iter=$1
  local test_name=fio-fsync-4k
  log "[disk][iter ${iter}] ${test_name}: rw=write bs=4k iodepth=1 numjobs=1 fdatasync=1 (always buffered)"
  do_fio --direct=0 --name="$test_name" --rw=write --bs=4k --iodepth=1 \
    --numjobs=1 --fdatasync=1

  local metrics
  if ! metrics=$(jq -c '{
      fsync_lat_p50_ms: (.jobs[0].sync.lat_ns.percentile["50.000000"] / 1000000),
      fsync_lat_p99_ms: (.jobs[0].sync.lat_ns.percentile["99.000000"] / 1000000),
      iops: .jobs[0].write.iops
    }' "$FIO_JSON"); then
    log "ERROR: failed to extract metrics from fio JSON for ${test_name}"
    exit 1
  fi
  require_metrics_numeric "$test_name" "$metrics"

  local params
  params=$(fio_params write 4k 1 1 buffered '{"fdatasync": 1}')
  emit_result disk "$test_name" "$iter" "$params" "$metrics" \
    '{"fsync_lat_p50_ms":"ms","fsync_lat_p99_ms":"ms","iops":"iops"}'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  emit_env_info

  case "$TARGET_MODE" in
    fs) setup_fs ;;
    block) setup_block ;;
    *)
      log "ERROR: TARGET_MODE must be 'fs' or 'block' (got '${TARGET_MODE}')"
      exit 1
      ;;
  esac

  log "disk suite: target=${FIO_TARGET} mode=${TARGET_MODE} io_mode=${IO_MODE} size=${FIO_SIZE}, ${ITERATIONS} iteration(s), ${DURATION}s per sub-test"

  local iter
  for ((iter = 1; iter <= ITERATIONS; iter++)); do
    run_rand_4k "$iter" fio-randread-4k randread read
    run_rand_4k "$iter" fio-randwrite-4k randwrite write
    run_seq_1m "$iter" fio-seqread-1m read read
    run_seq_1m "$iter" fio-seqwrite-1m write write
    run_randrw "$iter"
    run_fsync "$iter"
  done

  if [[ "$TARGET_MODE" == fs ]]; then
    rm -f "$FIO_TARGET"
  fi
  log "disk suite complete (${ITERATIONS} iteration(s))"
}

main "$@"
