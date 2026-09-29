#!/usr/bin/env bash
# npu-lock.sh <flm> <outdir> <label>
#
# Evidence for the ps-serving-snapshot.patch claim (#184) that POST
# /v1/completions and POST /api/embeddings used to run without the NPU
# lock: fires both against a server that is busy decoding a long /api/chat
# reply, then checks the server's own "NPU busy, request queued" log for
# lines naming each path. A base build that races here may also crash, so
# this tolerates that -- it always exits 0 unless a stray flm process is
# left behind; the caller reads the PASS/FAIL lines to tell red from green.
#
# The request body for /api/embeddings uses "input" (a string or array),
# not "prompt": RestHandler::handle_embeddings (rest_handler.cpp) requires
# "model" and "input" and refuses a request missing either.
set -u

FLM=${1:?usage: npu-lock.sh <flm> <outdir> <label>}
outdir=${2:?usage: npu-lock.sh <flm> <outdir> <label>}
label=${3:?usage: npu-lock.sh <flm> <outdir> <label>}
mkdir -p "$outdir"

LIB=${XRT_LIB_DIR:?set XRT_LIB_DIR to the xrt-combined lib dir}
PORT=58605
server_log="$outdir/server-npu-lock-$label.log"
chat_code_file="$outdir/npu-lock-$label.chat-code.txt"
completions_code_file="$outdir/npu-lock-$label.completions-code.txt"
embeddings_code_file="$outdir/npu-lock-$label.embeddings-code.txt"
result_file="$outdir/npu-lock-$label.txt"
# Reset now, not just inside the up()-success branch below: a failed up() (or
# an ABORT in wait_for_no_flm, below) must not leave a previous run's code or
# PASS/FAIL lines behind for the caller to misread.
: >"$chat_code_file"
: >"$completions_code_file"
: >"$embeddings_code_file"
: >"$result_file"

pid=""
rc=0

# stop -- bounded: TERM, wait up to 30s, then KILL, then reap.
stop() {
  [ -n "$pid" ] || return 0
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
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_no_flm() {
  local waited=0
  while pgrep -x flm >/dev/null; do
    if [ "$waited" -ge 600 ]; then
      echo "ABORT: flm already running, still busy after ${waited}s" >&2
      exit 1
    fi
    echo "flm already running; retrying in 30s (${waited}s so far)" >&2
    sleep 30
    waited=$((waited + 30))
  done
}

up() {
  LD_LIBRARY_PATH=$LIB "$FLM" serve llama3.2:1b --embed 1 --port "$PORT" \
    >"$server_log" 2>&1 &
  pid=$!
  local waited=0
  while [ "$waited" -lt 600 ]; do
    kill -0 "$pid" 2>/dev/null || { echo "server died during startup" >&2; return 1; }
    curl -s -o /dev/null "http://127.0.0.1:$PORT/api/version" && return 0
    sleep 1
    waited=$((waited + 1))
  done
  echo "server not ready within 600s" >&2
  return 1
}

queued_for() { # <needle> -- a "request queued" server log line names <needle>
  grep -F 'request queued' "$server_log" 2>/dev/null | grep -qF "$1"
}

wait_for_no_flm

log() { echo "$1" | tee -a "$result_file"; }

if ! up; then
  log "FAIL server-up: never became ready"
else
  chat_body='{"model":"llama3.2:1b","messages":[{"role":"user","content":"Count from 1 to 400, separated by commas."}],"stream":false,"options":{"num_predict":512,"top_k":1}}'
  completions_body='{"model":"llama3.2:1b","prompt":"Say hi.","max_tokens":4}'
  embeddings_body='{"model":"embed-gemma:300m","input":"hello"}'

  (curl -s -o /dev/null --max-time 600 -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/chat" \
    -H 'Content-Type: application/json' -d "$chat_body" >"$chat_code_file") &
  chat_pid=$!

  sleep 0.3

  (curl -s -o /dev/null --max-time 600 -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/v1/completions" \
    -H 'Content-Type: application/json' -d "$completions_body" >"$completions_code_file") &
  completions_pid=$!
  (curl -s -o /dev/null --max-time 600 -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/embeddings" \
    -H 'Content-Type: application/json' -d "$embeddings_body" >"$embeddings_code_file") &
  embeddings_pid=$!

  wait "$chat_pid" 2>/dev/null
  wait "$completions_pid" 2>/dev/null
  wait "$embeddings_pid" 2>/dev/null

  chat_code=$(cat "$chat_code_file" 2>/dev/null)
  completions_code=$(cat "$completions_code_file" 2>/dev/null)
  embeddings_code=$(cat "$embeddings_code_file" 2>/dev/null)

  server_alive=false
  kill -0 "$pid" 2>/dev/null && server_alive=true

  log "INFO chat_code=$chat_code completions_code=$completions_code embeddings_code=$embeddings_code server_alive=$server_alive"

  if queued_for 'POST /v1/completions'; then
    log "PASS queued-v1-completions"
  else
    log "FAIL queued-v1-completions"
  fi

  if queued_for 'POST /api/embeddings'; then
    log "PASS queued-api-embeddings"
  else
    log "FAIL queued-api-embeddings"
  fi

  if [ "$chat_code" = 200 ] && [ "$completions_code" = 200 ] && [ "$embeddings_code" = 200 ]; then
    log "PASS all-200"
  else
    log "FAIL all-200"
  fi

  if $server_alive; then
    log "PASS server-alive"
  else
    log "FAIL server-alive"
  fi

  stop
fi

if pgrep -x flm >/dev/null; then
  echo "stray flm!" >&2
  rc=1
fi

exit "$rc"
