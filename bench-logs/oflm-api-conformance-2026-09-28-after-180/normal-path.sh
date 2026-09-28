#!/usr/bin/env bash
# Confirms the #180 decode-fault fix leaves the normal, non-faulting
# non-stream /api/chat response byte-for-byte unchanged: runs the same
# deterministic request twice against llama3.2:1b and gemma4-it:e4b, saving
# each response (with timing fields stripped) to <prefix>.<model>.<n>.json.
# Usage: normal-path.sh <flm-binary> <outfile-prefix>
set -u

FLM=${1:?usage: normal-path.sh <flm-binary> <outfile-prefix>}
prefix=${2:?usage: normal-path.sh <flm-binary> <outfile-prefix>}
mkdir -p "$(dirname "$prefix")"

libpath=/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib
health_url=http://127.0.0.1:13305/api/v1/health

server_pid=""
rc=0

# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() {
  [[ -n "$server_pid" ]] && stop_server
  return 0
}
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

wait_for_npu() {
  local waited=0
  while :; do
    local loaded
    loaded=$(curl -s "$health_url" | jq -c '.all_models_loaded' 2>/dev/null)
    if ! pgrep -x flm >/dev/null && [[ "$loaded" == "[]" ]]; then
      return 0
    fi
    if (( waited >= 1800 )); then
      echo "NPU still busy after ${waited}s wait, giving up" >&2
      return 1
    fi
    echo "NPU busy (pgrep flm running or all_models_loaded=$loaded); waiting 30s..." >&2
    sleep 30
    (( waited += 30 ))
  done
}

start_server() { # model port logfile
  local model=$1 port=$2 logfile=$3
  wait_for_npu || { echo "ABORT: NPU never became free for $model" >&2; exit 1; }
  if pgrep -x flm >/dev/null; then
    echo "ABORT: flm already running before starting $model" >&2
    exit 1
  fi
  LD_LIBRARY_PATH="$libpath" "$FLM" serve "$model" --port "$port" >"$logfile" 2>&1 &
  server_pid=$!
  local waited=0
  while (( waited < 300 )); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "server for $model died before becoming ready (see $logfile)" >&2
      server_pid=""
      return 1
    fi
    curl -s -o /dev/null "http://127.0.0.1:$port/api/version" && return 0
    sleep 1
    (( waited++ ))
  done
  echo "server for $model did not become ready within 300s" >&2
  return 1
}

stop_server() {
  [[ -z "$server_pid" ]] && return 0
  kill -TERM "$server_pid" 2>/dev/null
  local waited=0
  while (( waited < 30 )) && kill -0 "$server_pid" 2>/dev/null; do
    sleep 1
    (( waited++ ))
  done
  kill -0 "$server_pid" 2>/dev/null && kill -KILL "$server_pid" 2>/dev/null
  wait "$server_pid" 2>/dev/null
  server_pid=""
  pgrep -x flm >/dev/null && echo "WARN: flm still running after stop" >&2
  return 0
}

run_twice() { # model port
  local model=$1 port=$2
  local body='{"model":"'"$model"'","messages":[{"role":"user","content":"Name three primary colors."}],"stream":false,"top_k":1,"options":{"num_predict":64}}'
  for n in 1 2; do
    local resp code out
    resp=$(curl -sS -m 300 -w '\nHTTP %{http_code}\n' -H 'Content-Type: application/json' \
      --data-binary "$body" "http://127.0.0.1:$port/api/chat")
    code=$(tail -n1 <<<"$resp" | awk '{print $2}')
    out=$(sed '$d' <<<"$resp")
    if [[ "$code" != 200 ]]; then
      echo "$model run $n: expected HTTP 200, got $code: $out" >&2
      rc=1
    fi
    jq -S 'del(.total_duration,.load_duration,.prompt_eval_duration,.eval_duration)' \
      <<<"$out" >"$prefix.$model.$n.json"
    echo "wrote $prefix.$model.$n.json (HTTP $code)"
  done
}

start_server llama3.2:1b 58601 "$prefix.server-llama.log" || exit 1
run_twice llama3.2:1b 58601
stop_server

start_server gemma4-it:e4b 58603 "$prefix.server-gemma4.log" || exit 1
run_twice gemma4-it:e4b 58603
stop_server
exit "$rc"
