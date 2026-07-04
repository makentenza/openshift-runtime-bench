#!/usr/bin/env bash
# shellcheck shell=bash
#
# common.sh — shared helpers for the openshift-runtime-bench in-pod scripts.
#
# Sourced by every /bench/run-*.sh. Callers are expected to run with:
#   set -euo pipefail
#
# RESULT PROTOCOL
# ---------------
# Benchmark scripts write human-readable progress to STDERR and machine
# results to STDOUT as single lines of the form:
#
#   RESULT_JSON {compact single-line JSON}
#
# Envelope keys (exact):
#   {"suite": "cpu|memory|disk|network|app|startup|overhead|env",
#    "test": "<sub-test-name>", "runtime": "<RUNTIME>", "node": "<NODE_NAME>",
#    "timestamp": "<UTC ISO8601>", "iteration": <int>,
#    "parameters": {..}, "metrics": {"<name>": <number>, ..},
#    "units": {"<metric-name>": "<unit>", ..}}
#
# The workstation runner collects these with:
#   oc logs job/<name> | grep '^RESULT_JSON ' | sed 's/^RESULT_JSON //'
#
# STDOUT MUST stay clean: everything that is not a RESULT_JSON line belongs
# on STDERR.

# Consistent number formatting / parsing regardless of image locale.
export LC_ALL=C

# ---------------------------------------------------------------------------
# Defaults (overridden by the Job/Deployment templates via container env)
# ---------------------------------------------------------------------------
: "${RUNTIME:=unknown}"
: "${NODE_NAME:=$(hostname)}"
: "${ITERATIONS:=3}"
: "${DURATION:=30}"
: "${THREADS:=2}"

# ---------------------------------------------------------------------------
# Logging and validation
# ---------------------------------------------------------------------------

# log MESSAGE... — timestamped human-readable line on stderr.
log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

# is_number VALUE — true if VALUE is a plain or scientific-notation number.
is_number() {
  [[ ${1:-} =~ ^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]]
}

# require_number NAME VALUE — exit with a clear message unless VALUE is numeric.
require_number() {
  local name=$1 value=${2:-}
  if ! is_number "$value"; then
    log "ERROR: expected a numeric value for ${name}, got: '${value}'"
    exit 1
  fi
}

# require_env VAR... — exit unless every named environment variable is set
# and non-empty.
require_env() {
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      log "ERROR: required environment variable ${var} is not set"
      exit 1
    fi
  done
}

# require_metrics_numeric NAME METRICS_JSON — exit unless METRICS_JSON is a
# JSON object whose values are all numbers (guards against nulls sneaking in
# from jq extractions over tool output).
require_metrics_numeric() {
  local name=$1 json=${2:-}
  if ! printf '%s' "$json" \
      | jq -e 'type == "object" and all(.[]; type == "number")' \
      > /dev/null 2>&1; then
    log "ERROR: metrics for ${name} are not a JSON object of numbers: ${json}"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Result emission
# ---------------------------------------------------------------------------

# emit_result SUITE TEST ITERATION PARAMS_JSON METRICS_JSON UNITS_JSON
# Builds the result envelope (runtime from $RUNTIME, node from $NODE_NAME,
# timestamp in UTC ISO8601) and prints the RESULT_JSON line on stdout.
emit_result() {
  local suite=$1 test=$2 iteration=$3 params_json=$4 metrics_json=$5 units_json=$6
  local ts envelope
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  envelope=$(jq -c -n \
    --arg suite "$suite" \
    --arg test "$test" \
    --arg runtime "$RUNTIME" \
    --arg node "$NODE_NAME" \
    --arg timestamp "$ts" \
    --argjson iteration "$iteration" \
    --argjson parameters "$params_json" \
    --argjson metrics "$metrics_json" \
    --argjson units "$units_json" \
    '{suite: $suite, test: $test, runtime: $runtime, node: $node,
      timestamp: $timestamp, iteration: $iteration,
      parameters: $parameters, metrics: $metrics, units: $units}')
  printf 'RESULT_JSON %s\n' "$envelope"
}

# emit_env_info — one result with suite=env, test=environment capturing the
# environment AS SEEN FROM INSIDE THE POD. Inside a kata pod this shows the
# GUEST kernel, the guest vCPU count and hypervisor_flag=1 — key evidence
# that the runtime boundary differs from crun (which shows the host kernel).
emit_env_info() {
  local kernel cpus mem_kb hyp
  kernel=$(uname -r)
  cpus=$(nproc)
  mem_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
  if grep -qw hypervisor /proc/cpuinfo; then
    hyp=1
  else
    hyp=0
  fi
  require_number nproc "$cpus"
  require_number mem_total_kb "$mem_kb"

  local params metrics units
  params=$(jq -c -n --arg kernel "$kernel" '{kernel: $kernel}')
  metrics=$(jq -c -n \
    --argjson cpus "$cpus" \
    --argjson mem "$mem_kb" \
    --argjson hyp "$hyp" \
    '{nproc: $cpus, mem_total_kb: $mem, hypervisor_flag: $hyp}')
  units='{"nproc":"cpus","mem_total_kb":"kB","hypervisor_flag":"flag"}'
  emit_result env environment 0 "$params" "$metrics" "$units"
}

# ---------------------------------------------------------------------------
# Network helpers (in-image only; uses coreutils `timeout`)
# ---------------------------------------------------------------------------

# wait_for_tcp HOST PORT [TIMEOUT_SECONDS] — poll until a TCP connect to
# HOST:PORT succeeds, or exit non-zero after TIMEOUT_SECONDS (default 180).
wait_for_tcp() {
  local host=$1 port=$2 timeout_s=${3:-180}
  local waited=0
  log "waiting for tcp/${port} on ${host} (timeout ${timeout_s}s)"
  while ! timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}; exec 3>&- 3<&-" \
      2> /dev/null; do
    sleep 2
    waited=$((waited + 5))
    if ((waited >= timeout_s)); then
      log "ERROR: timed out after ${timeout_s}s waiting for tcp/${port} on ${host}"
      exit 1
    fi
  done
  log "tcp/${port} on ${host} is reachable"
}

# ---------------------------------------------------------------------------
# stress-ng YAML parsing (shared by run-cpu.sh and run-memory.sh)
# ---------------------------------------------------------------------------

# sng_bogo_ops_per_sec YAML_FILE — print the bogo-ops-per-second-real-time
# value from a stress-ng metrics YAML (-Y file --metrics), or nothing if the
# key is absent. Plain-text parse: no PyYAML dependency in the image.
sng_bogo_ops_per_sec() {
  python3 - "$1" <<'PY'
import re
import sys

NUMBER = r"(-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)"
val = None
try:
    fh = open(sys.argv[1], encoding="utf-8", errors="replace")
except OSError:
    print("")
    sys.exit(0)
with fh:
    for line in fh:
        m = re.match(r"\s*bogo-ops-per-second-real-time:\s*" + NUMBER + r"\s*$", line)
        if m:
            val = m.group(1)
print(val if val is not None else "")
PY
}

# sng_memory_rate_mb_s YAML_FILE — print the stream stressor's memory rate
# (MB/s) from a stress-ng metrics YAML, or nothing if absent. Handles both
# inline keys (e.g. "memory-rate-mb-per-sec: N") and description/value pairs
# ("description: memory rate (MB per sec)" followed by "value: N"), since the
# exact YAML shape varies across stress-ng versions.
sng_memory_rate_mb_s() {
  python3 - "$1" <<'PY'
import re
import sys

NUMBER = r"(-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)"
try:
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError:
    print("")
    sys.exit(0)

lines = text.splitlines()
val = None
for i, line in enumerate(lines):
    if ":" not in line:
        continue
    key, _, rest = line.partition(":")
    key_norm = re.sub(r"[^a-z]+", " ", key.strip().strip('"').lower())
    # Inline form: key mentions memory + rate, numeric value on same line.
    if "memory" in key_norm and "rate" in key_norm:
        m = re.search(NUMBER + r"\s*$", line)
        if m:
            val = m.group(1)
            break
    # description/value form.
    if "description" in key_norm and "memory rate" in rest.strip().strip('"').lower():
        for nxt in lines[i + 1 : i + 4]:
            m = re.match(r"\s*value:\s*" + NUMBER, nxt)
            if m:
                val = m.group(1)
                break
        if val is not None:
            break
print(val if val is not None else "")
PY
}

# ---------------------------------------------------------------------------
# Sanity checks on the tunables the templates inject
# ---------------------------------------------------------------------------
require_number ITERATIONS "$ITERATIONS"
require_number DURATION "$DURATION"
require_number THREADS "$THREADS"
