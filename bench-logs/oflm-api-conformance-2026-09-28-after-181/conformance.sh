#!/usr/bin/env bash
# conformance.sh <flm> <outdir> <oflm-next>
set -u
FLM=$1; out=$2; T=$3/specs/server-api/tests
LIB=/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib
pid=""
rc=0

# stop -- bounded: TERM, wait up to 30s, then KILL, then reap.
stop() {
  [ -z "$pid" ] && return
  kill "$pid" 2>/dev/null
  local waited=0
  while [ "$waited" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  pid=""
}
# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() { stop; }
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

up() { # label port args...
  local label=$1 port=$2; shift 2
  pgrep -x flm >/dev/null && { echo "flm already running" >&2; exit 1; }
  LD_LIBRARY_PATH=$LIB "$FLM" serve "$@" --port "$port" >"$out/server-conformance-$label.log" 2>&1 & pid=$!
  for _ in $(seq 300); do
    kill -0 "$pid" 2>/dev/null || { echo "server $label died during startup" >&2; exit 1; }
    curl -s -o /dev/null "http://127.0.0.1:$port/api/version" && return
    sleep 1
  done
  echo "server $label not ready" >&2; exit 1
}
down() {
  stop
  pgrep -x flm >/dev/null && { echo "stray flm!" >&2; return 1; }
  return 0
}
R=$out/run_spec_tests.py
up chat 58601 llama3.2:1b
OFLM_TEST_BASE_URL=http://127.0.0.1:58601 OFLM_TEST_MODEL=llama3.2:1b python3 "$R" "$T/test_error_status.py" >"$out/test_error_status.log" 2>&1 || rc=1
OFLM_TEST_BASE_URL=http://127.0.0.1:58601 OFLM_TEST_MODEL=llama3.2:1b python3 "$R" "$T/test_finish_reason.py" >"$out/test_finish_reason.log" 2>&1 || rc=1
OFLM_TEST_BASE_URL=http://127.0.0.1:58601 OFLM_TEST_MODEL=llama3.2:1b python3 "$R" "$T/test_request_validation.py" >"$out/test_request_validation.log" 2>&1 || rc=1
down || rc=1
up gemma4 58603 gemma4-it:e4b
OFLM_TEST_BASE_URL=http://127.0.0.1:58603 OFLM_TEST_MODEL=gemma4-it:e4b python3 "$R" "$T/test_error_status.py" >"$out/test_error_status.gemma4.log" 2>&1 || rc=1
down || rc=1
up embed 58602 llama3.2:1b --embed 1
OFLM_TEST_BASE_URL=http://127.0.0.1:58602 OFLM_TEST_EMBED_MODEL=embed-gemma:300m python3 "$R" "$T/test_embed_task_prompt.py" >"$out/test_embed_task_prompt.log" 2>&1 || rc=1
OFLM_TEST_BASE_URL=http://127.0.0.1:58602 OFLM_TEST_MODEL=llama3.2:1b OFLM_TEST_EMBED_MODEL=embed-gemma:300m python3 "$R" "$T/test_request_validation.py" >"$out/test_request_validation.embed.log" 2>&1 || rc=1
down || rc=1
exit "$rc"
