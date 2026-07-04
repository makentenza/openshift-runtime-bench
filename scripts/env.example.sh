#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# openshift-runtime-bench — local environment configuration (EXAMPLE)
# =============================================================================
#
# Setup:
#
#   cp scripts/env.example.sh scripts/env.sh   # scripts/env.sh is gitignored
#   "$EDITOR" scripts/env.sh                   # uncomment and edit the values
#
# scripts/lib.sh automatically sources scripts/env.sh if it exists, so every
# workstation script (run-suite.sh, measure-startup.sh, measure-overhead.sh)
# picks these values up. You can also `source scripts/env.sh` in your shell.
#
# Precedence, lowest to highest:
#
#   1. Built-in defaults (scripts/lib.sh)
#   2. Values exported here (scripts/env.sh)
#   3. Variables already exported in your shell (the ${VAR:-...} guards below
#      make an existing export win over this file)
#   4. Command-line flags on run-suite.sh / measure-*.sh — flags ALWAYS win
#
# Keep the ${VAR:-default} form when you edit values so one-off shell exports
# still override the file.
# =============================================================================

# --- Namespace ---------------------------------------------------------------
# Namespace that holds every benchmark resource (jobs, servers, PVCs, builds).
# Must match the ImageStream namespace embedded in BENCH_IMAGE if you build
# in-cluster. Flag equivalent: --namespace
#
# export NAMESPACE="${NAMESPACE:-runtime-bench}"

# --- Benchmark image ---------------------------------------------------------
# Fully-qualified pull spec of the benchmark container image. The default
# points at the in-cluster registry ImageStream created by
# manifests/build/build.yaml. Point this at quay.io/... if you build and push
# externally instead.
#
# export BENCH_IMAGE="${BENCH_IMAGE:-image-registry.openshift-image-registry.svc:5000/runtime-bench/runtime-bench:latest}"

# --- Pod sizing (Guaranteed QoS) ----------------------------------------------
# CPU and memory used for BOTH requests and limits on benchmark and server
# pods (Guaranteed QoS keeps the scheduler and cgroup behavior deterministic).
# BENCH_CPU is also passed to the pods as THREADS, so it sets benchmark
# parallelism. Keep these identical across the runs you intend to compare.
#
# export BENCH_CPU="${BENCH_CPU:-2}"
# export BENCH_MEMORY="${BENCH_MEMORY:-4Gi}"

# --- Persistent storage (disk suite, --pvc / --block) -------------------------
# Size requested for the Filesystem and Block PVCs.
#
# export PVC_SIZE="${PVC_SIZE:-10Gi}"

# Optional: StorageClass for those PVCs. Leave unset to use the cluster
# default StorageClass. Flag equivalent: --storage-class
#
# export STORAGE_CLASS="${STORAGE_CLASS:-}"

# --- Run parameters ------------------------------------------------------------
# ITERATIONS: how many times each sub-test repeats inside the pod (more
# iterations -> tighter mean/stdev, longer runs). Flag equivalent: --iterations
#
# export ITERATIONS="${ITERATIONS:-3}"

# DURATION: seconds each sub-test runs per iteration (sysbench/fio/iperf3
# time-boxed runs). Flag equivalent: --duration
#
# export DURATION="${DURATION:-30}"

# =============================================================================
# Anything settable here can also be set per-invocation with run-suite.sh
# flags (--namespace, --iterations, --duration, --storage-class, ...), and
# flags override this file. Run scripts/run-suite.sh --help for the full list.
# =============================================================================
