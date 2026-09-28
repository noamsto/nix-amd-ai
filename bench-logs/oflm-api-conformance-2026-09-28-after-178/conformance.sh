#!/usr/bin/env bash
# conf.sh <flm> <outdir> <oflm-next>
set -u
FLM=$1; out=$2; T=$3/specs/server-api/tests
LIB=/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib
pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; wait 2>/dev/null' EXIT INT TERM
up() { # port args...
  local port=$1; shift
  pgrep -x flm >/dev/null && { echo "flm already running" >&2; exit 1; }
  LD_LIBRARY_PATH=$LIB "$FLM" serve "$@" --port "$port" >"$out/server-$port.log" 2>&1 & pid=$!
  for _ in $(seq 300); do curl -s -o /dev/null "http://127.0.0.1:$port/api/version" && return; sleep 1; done
  echo "server $port not ready" >&2; exit 1
}
down() { kill "$pid"; wait "$pid" 2>/dev/null; pid=""; pgrep -a flm && echo "stray flm!" >&2; }
R=$out/run_spec_tests.py
up 58601 llama3.2:1b
OFLM_TEST_BASE_URL=http://127.0.0.1:58601 OFLM_TEST_MODEL=llama3.2:1b python3 "$R" "$T/test_error_status.py" >"$out/test_error_status.log" 2>&1
OFLM_TEST_BASE_URL=http://127.0.0.1:58601 OFLM_TEST_MODEL=llama3.2:1b python3 "$R" "$T/test_finish_reason.py" >"$out/test_finish_reason.log" 2>&1
OFLM_TEST_BASE_URL=http://127.0.0.1:58601 OFLM_TEST_MODEL=llama3.2:1b python3 "$R" "$T/test_request_validation.py" >"$out/test_request_validation.log" 2>&1
down
up 58603 gemma4-it:e4b
OFLM_TEST_BASE_URL=http://127.0.0.1:58603 OFLM_TEST_MODEL=gemma4-it:e4b python3 "$R" "$T/test_error_status.py" >"$out/test_error_status.gemma4.log" 2>&1
down
up 58602 llama3.2:1b --embed 1
OFLM_TEST_BASE_URL=http://127.0.0.1:58602 OFLM_TEST_EMBED_MODEL=embed-gemma:300m python3 "$R" "$T/test_embed_task_prompt.py" >"$out/test_embed_task_prompt.log" 2>&1
OFLM_TEST_BASE_URL=http://127.0.0.1:58602 OFLM_TEST_MODEL=llama3.2:1b OFLM_TEST_EMBED_MODEL=embed-gemma:300m python3 "$R" "$T/test_request_validation.py" >"$out/test_request_validation.embed.log" 2>&1
down
