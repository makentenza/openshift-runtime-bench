#!/usr/bin/env bash
#
# run-app.sh — application-level benchmark suite (nginx + ApacheBench).
#
# MODE=server — writes static content (/tmp/www: index.html ~small, 1m.bin
#               1 MiB) and a self-contained nginx config under /tmp (works
#               under restricted-v2 with an arbitrary UID: pid, logs and all
#               temp paths in /tmp), then execs nginx in the foreground on
#               tcp/8080. Used by the nginx-server Deployment.
# MODE=client — requires SERVER_HOST (the server POD IP; no Service in the
#               measured path). Waits for tcp/8080, then per iteration:
#   ab-http-small — ab -n 20000 -c 50 on /index.html (request-rate bound)
#   ab-http-1m    — ab -n 2000  -c 20 on /1m.bin     (throughput bound)
#
# Env: RUNTIME, NODE_NAME, ITERATIONS (see common.sh), MODE, and SERVER_HOST
# for clients. DURATION is not used by ab (fixed request counts instead).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

HTTP_PORT=8080
AB_OUT=/tmp/ab.out

# ---------------------------------------------------------------------------
# Server mode
# ---------------------------------------------------------------------------
server_main() {
  local www=/tmp/www
  mkdir -p "$www"

  # index.html: 'ok' plus a few hundred bytes of payload.
  {
    echo "ok"
    head -c 384 /dev/urandom | base64
  } > "${www}/index.html"

  # 1m.bin: 1 MiB of incompressible data.
  dd if=/dev/urandom of="${www}/1m.bin" bs=1M count=1 status=none

  log "content ready: index.html ($(stat -c %s "${www}/index.html") bytes), 1m.bin ($(stat -c %s "${www}/1m.bin") bytes)"

  # Self-contained nginx config: everything writable lives under /tmp so the
  # server runs as an arbitrary UID under restricted-v2.
  cat > /tmp/nginx.conf <<'NGINX_EOF'
worker_processes 2;
error_log /tmp/nginx-error.log warn;
pid /tmp/nginx.pid;

events {
  worker_connections 4096;
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  access_log off;
  sendfile on;
  tcp_nopush on;
  keepalive_timeout 65;

  client_body_temp_path /tmp/client_body_temp;
  proxy_temp_path /tmp/proxy_temp;
  fastcgi_temp_path /tmp/fastcgi_temp;
  uwsgi_temp_path /tmp/uwsgi_temp;
  scgi_temp_path /tmp/scgi_temp;

  server {
    listen 8080;
    server_name _;
    root /tmp/www;
  }
}
NGINX_EOF

  log "starting nginx on 0.0.0.0:${HTTP_PORT} (config /tmp/nginx.conf)"
  # -e moves the pre-config-parse error log to a writable path as well.
  exec nginx -e /tmp/nginx-error.log -c /tmp/nginx.conf -g 'daemon off;'
}

# ---------------------------------------------------------------------------
# Client mode
# ---------------------------------------------------------------------------

# run_ab ITER TEST_NAME PATH REQUESTS CONCURRENCY
run_ab() {
  local iter=$1 test_name=$2 path=$3 requests=$4 concurrency=$5
  local url="http://${SERVER_HOST}:${HTTP_PORT}${path}"
  log "[app][iter ${iter}] ${test_name}: ab -n ${requests} -c ${concurrency} ${url}"

  if ! ab -n "$requests" -c "$concurrency" "$url" > "$AB_OUT"; then
    log "ERROR: ab failed for ${test_name}:"
    sed -n '1,60p' "$AB_OUT" >&2
    exit 1
  fi
  cat "$AB_OUT" >&2

  local rps p50 p99 kb_s failed
  rps=$(awk '/^Requests per second:/ {print $4; exit}' "$AB_OUT")
  p50=$(awk '$1 == "50%" {print $2; exit}' "$AB_OUT")
  p99=$(awk '$1 == "99%" {print $2; exit}' "$AB_OUT")
  kb_s=$(awk '/^Transfer rate:/ {print $3; exit}' "$AB_OUT")
  failed=$(awk '/^Failed requests:/ {print $NF; exit}' "$AB_OUT")
  require_number requests_per_sec "$rps"
  require_number latency_p50_ms "$p50"
  require_number latency_p99_ms "$p99"
  require_number transfer_rate_kb_s "$kb_s"

  if is_number "$failed" && ((failed > 0)); then
    log "WARNING: ${test_name} reported ${failed} failed request(s) out of ${requests}"
  fi

  # ab reports Kbytes/sec (1024 bytes); convert to MB/s (10^6 bytes).
  local mb_s
  mb_s=$(python3 -c "print(float('${kb_s}') * 1024 / 1000000)")
  require_number transfer_rate_mb_s "$mb_s"

  local params metrics units
  params=$(jq -c -n \
    --arg path "$path" \
    --argjson requests "$requests" \
    --argjson concurrency "$concurrency" \
    '{path: $path, requests: $requests, concurrency: $concurrency,
      keepalive: false}')
  metrics=$(jq -c -n \
    --argjson rps "$rps" \
    --argjson p50 "$p50" \
    --argjson p99 "$p99" \
    --argjson mbs "$mb_s" \
    '{requests_per_sec: $rps, latency_p50_ms: $p50, latency_p99_ms: $p99,
      transfer_rate_mb_s: $mbs}')
  units='{"requests_per_sec":"req/s","latency_p50_ms":"ms","latency_p99_ms":"ms","transfer_rate_mb_s":"MB/s"}'
  emit_result app "$test_name" "$iter" "$params" "$metrics" "$units"
}

client_main() {
  require_env SERVER_HOST
  log "MODE=client: server ${SERVER_HOST}:${HTTP_PORT}, ${ITERATIONS} iteration(s)"

  wait_for_tcp "$SERVER_HOST" "$HTTP_PORT"

  # Short warm-up so connection setup and server caches do not skew the
  # first recorded iteration. Not recorded.
  log "warm-up: ab -n 200 -c 10 /index.html (not recorded)"
  if ! ab -n 200 -c 10 "http://${SERVER_HOST}:${HTTP_PORT}/index.html" > /dev/null; then
    log "WARNING: warm-up run failed (continuing)"
  fi

  local iter
  for ((iter = 1; iter <= ITERATIONS; iter++)); do
    run_ab "$iter" ab-http-small /index.html 20000 50
    run_ab "$iter" ab-http-1m /1m.bin 2000 20
  done

  log "app suite complete (${ITERATIONS} iteration(s))"
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
