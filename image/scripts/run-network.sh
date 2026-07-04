#!/usr/bin/env bash
#
# run-network.sh — network benchmark suite (iperf3 + qperf).
#
# MODE=server — starts a qperf listener (tcp/19765) in the background, then
#               execs iperf3 -s (tcp+udp/5201) in the foreground. Both bind
#               all addresses. Used by the iperf3-server Deployment.
# MODE=client — requires SERVER_HOST (the server POD IP; no Service in the
#               measured path). Waits for both ports, then per iteration:
#   iperf3-tcp-p1      — single-stream TCP throughput (client → server)
#   iperf3-tcp-p4      — 4 parallel TCP streams
#   iperf3-tcp-reverse — single-stream TCP, server → client (-R)
#   iperf3-udp-1g      — UDP at 1 Gbit/s target: throughput, jitter, loss
#   qperf-tcp-lat      — TCP round-trip latency
#   qperf-tcp-bw       — TCP bandwidth (qperf's independent measurement)
#
# Env: RUNTIME, NODE_NAME, ITERATIONS, DURATION (see common.sh), MODE, and
# SERVER_HOST for clients.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

IPERF_PORT=5201
QPERF_PORT=19765
IPERF_JSON=/tmp/iperf3.json

# ---------------------------------------------------------------------------
# Unit conversion helpers (qperf prints value + unit)
# ---------------------------------------------------------------------------

# lat_to_us VALUE UNIT — convert a qperf latency to microseconds.
lat_to_us() {
  python3 - "$1" "$2" <<'PY'
import sys

val = float(sys.argv[1])
unit = sys.argv[2].lower().rstrip(",")
scale = {"ns": 1e-3, "us": 1.0, "ms": 1e3, "s": 1e6, "sec": 1e6}
if unit not in scale:
    sys.exit("unknown latency unit: %s" % unit)
print(val * scale[unit])
PY
}

# bw_to_gbps VALUE UNIT — convert a qperf bandwidth (SI bytes/sec) to Gbit/s.
bw_to_gbps() {
  python3 - "$1" "$2" <<'PY'
import sys

val = float(sys.argv[1])
unit = sys.argv[2].lower().rstrip(",")
bytes_per_sec = {
    "bytes/sec": 1.0,
    "b/sec": 1.0,
    "kb/sec": 1e3,
    "mb/sec": 1e6,
    "gb/sec": 1e9,
    "tb/sec": 1e12,
}
if unit not in bytes_per_sec:
    sys.exit("unknown bandwidth unit: %s" % unit)
print(val * bytes_per_sec[unit] * 8 / 1e9)
PY
}

# ---------------------------------------------------------------------------
# Server mode
# ---------------------------------------------------------------------------
server_main() {
  log "MODE=server: qperf listener on tcp/${QPERF_PORT}, iperf3 server on tcp+udp/${IPERF_PORT} (all addresses)"

  qperf >&2 &
  local qperf_pid=$!
  sleep 1
  if ! kill -0 "$qperf_pid" 2> /dev/null; then
    log "ERROR: qperf listener failed to start"
    exit 1
  fi
  log "qperf listener running (pid ${qperf_pid}, port ${QPERF_PORT})"

  log "starting iperf3 server in foreground (port ${IPERF_PORT})"
  exec iperf3 -s >&2
}

# ---------------------------------------------------------------------------
# Client mode — iperf3
# ---------------------------------------------------------------------------

# iperf3_exec TEST_NAME EXTRA_ARGS... — run iperf3 -c with JSON output into
# $IPERF_JSON; retry up to 3 times (a lingering previous session can make the
# server report "busy" briefly between back-to-back tests).
iperf3_exec() {
  local test_name=$1
  shift
  local attempt
  for attempt in 1 2 3; do
    rm -f "$IPERF_JSON"
    if iperf3 -c "$SERVER_HOST" -p "$IPERF_PORT" -t "$DURATION" -J "$@" > "$IPERF_JSON"; then
      return 0
    fi
    log "WARNING: iperf3 ${test_name} attempt ${attempt}/3 failed: $(jq -r '.error // "unknown error"' "$IPERF_JSON" 2> /dev/null || echo 'no JSON output')"
    sleep 3
  done
  log "ERROR: iperf3 ${test_name} failed after 3 attempts"
  exit 1
}

# run_iperf3_tcp ITER TEST_NAME PARALLEL REVERSE_FLAG EXTRA_ARGS...
run_iperf3_tcp() {
  local iter=$1 test_name=$2 parallel=$3 reverse=$4
  shift 4
  log "[network][iter ${iter}] ${test_name}: iperf3 tcp parallel=${parallel} reverse=${reverse} duration=${DURATION}s"
  iperf3_exec "$test_name" "$@"

  local metrics
  if ! metrics=$(jq -c '{
      throughput_gbps: (.end.sum_received.bits_per_second / 1e9),
      retransmits: (.end.sum_sent.retransmits // 0)
    }' "$IPERF_JSON"); then
    log "ERROR: failed to extract metrics from iperf3 JSON for ${test_name}"
    exit 1
  fi
  require_metrics_numeric "$test_name" "$metrics"

  local params
  params=$(jq -c -n \
    --argjson p "$parallel" \
    --argjson r "$reverse" \
    --argjson d "$DURATION" \
    '{protocol: "tcp", parallel: $p, reverse: ($r == 1), duration_s: $d}')
  emit_result network "$test_name" "$iter" "$params" "$metrics" \
    '{"throughput_gbps":"Gbit/s","retransmits":"count"}'
}

# run_iperf3_udp ITER — UDP at a 1 Gbit/s target bitrate.
run_iperf3_udp() {
  local iter=$1
  local test_name=iperf3-udp-1g
  log "[network][iter ${iter}] ${test_name}: iperf3 udp -b 1G duration=${DURATION}s"
  iperf3_exec "$test_name" -u -b 1G

  local metrics
  if ! metrics=$(jq -c '{
      throughput_gbps: (.end.sum.bits_per_second / 1e9),
      jitter_ms: .end.sum.jitter_ms,
      loss_pct: .end.sum.lost_percent
    }' "$IPERF_JSON"); then
    log "ERROR: failed to extract metrics from iperf3 JSON for ${test_name}"
    exit 1
  fi
  require_metrics_numeric "$test_name" "$metrics"

  local params
  params=$(jq -c -n --argjson d "$DURATION" \
    '{protocol: "udp", target_bitrate: "1G", duration_s: $d}')
  emit_result network "$test_name" "$iter" "$params" "$metrics" \
    '{"throughput_gbps":"Gbit/s","jitter_ms":"ms","loss_pct":"%"}'
}

# ---------------------------------------------------------------------------
# Client mode — qperf
# ---------------------------------------------------------------------------
run_qperf_lat() {
  local iter=$1
  local test_name=qperf-tcp-lat
  log "[network][iter ${iter}] ${test_name}: qperf ${SERVER_HOST} tcp_lat (${DURATION}s)"

  local out
  if ! out=$(qperf -t "$DURATION" "$SERVER_HOST" tcp_lat 2>&1); then
    log "ERROR: qperf tcp_lat failed:"
    printf '%s\n' "$out" >&2
    exit 1
  fi
  printf '%s\n' "$out" >&2

  # Output looks like: "    latency  =  28.9 us" (unit may be ns/us/ms/sec)
  local val unit lat_us
  val=$(awk '/latency[[:space:]]*=/ {print $(NF-1); exit}' <<< "$out")
  unit=$(awk '/latency[[:space:]]*=/ {print $NF; exit}' <<< "$out")
  require_number "qperf tcp_lat latency" "$val"
  lat_us=$(lat_to_us "$val" "$unit")
  require_number latency_us "$lat_us"

  local params metrics units
  params=$(jq -c -n --argjson d "$DURATION" '{protocol: "tcp", duration_s: $d}')
  metrics=$(jq -c -n --argjson l "$lat_us" '{latency_us: $l}')
  units='{"latency_us":"us"}'
  emit_result network "$test_name" "$iter" "$params" "$metrics" "$units"
}

run_qperf_bw() {
  local iter=$1
  local test_name=qperf-tcp-bw
  log "[network][iter ${iter}] ${test_name}: qperf ${SERVER_HOST} tcp_bw (${DURATION}s)"

  local out
  if ! out=$(qperf -t "$DURATION" "$SERVER_HOST" tcp_bw 2>&1); then
    log "ERROR: qperf tcp_bw failed:"
    printf '%s\n' "$out" >&2
    exit 1
  fi
  printf '%s\n' "$out" >&2

  # Output looks like: "    bw  =  1.18 GB/sec" (unit may be KB/MB/GB/sec)
  local val unit gbps
  val=$(awk '/(^|[[:space:]])bw[[:space:]]*=/ {print $(NF-1); exit}' <<< "$out")
  unit=$(awk '/(^|[[:space:]])bw[[:space:]]*=/ {print $NF; exit}' <<< "$out")
  require_number "qperf tcp_bw bandwidth" "$val"
  gbps=$(bw_to_gbps "$val" "$unit")
  require_number throughput_gbps "$gbps"

  local params metrics units
  params=$(jq -c -n --argjson d "$DURATION" '{protocol: "tcp", duration_s: $d}')
  metrics=$(jq -c -n --argjson g "$gbps" '{throughput_gbps: $g}')
  units='{"throughput_gbps":"Gbit/s"}'
  emit_result network "$test_name" "$iter" "$params" "$metrics" "$units"
}

# ---------------------------------------------------------------------------
# Client mode main
# ---------------------------------------------------------------------------
client_main() {
  require_env SERVER_HOST
  log "MODE=client: server ${SERVER_HOST}, ${ITERATIONS} iteration(s), ${DURATION}s per sub-test"

  wait_for_tcp "$SERVER_HOST" "$IPERF_PORT"
  wait_for_tcp "$SERVER_HOST" "$QPERF_PORT"

  local iter
  for ((iter = 1; iter <= ITERATIONS; iter++)); do
    run_iperf3_tcp "$iter" iperf3-tcp-p1 1 0
    sleep 2
    run_iperf3_tcp "$iter" iperf3-tcp-p4 4 0 -P 4
    sleep 2
    run_iperf3_tcp "$iter" iperf3-tcp-reverse 1 1 -R
    sleep 2
    run_iperf3_udp "$iter"
    sleep 2
    run_qperf_lat "$iter"
    run_qperf_bw "$iter"
  done

  log "network suite complete (${ITERATIONS} iteration(s))"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  emit_env_info
  case "${MODE:-}" in
    server) server_main ;;
    client) client_main ;;
    *)
      log "ERROR: MODE must be 'server' or 'client' (got '${MODE:-unset}')"
      exit 1
      ;;
  esac
}

main "$@"
