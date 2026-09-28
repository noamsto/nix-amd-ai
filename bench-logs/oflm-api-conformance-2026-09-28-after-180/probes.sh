#!/usr/bin/env bash
# Probes flm serve's non-streaming /api/chat fault classification: a fault
# during decode must answer 500 {"error":{"message":"Internal error",
# "type":"server_error"}}, a fault before prefill completes (template or
# prefill itself) must stay a 400 {"error":{"message":"Invalid request",
# "type":"invalid_request_error","code":"invalid_value"}}.
# Usage: probes.sh <flm-binary> <outdir>
set -u

FLM=${1:?usage: probes.sh <flm-binary> <outdir>}
outdir=${2:?usage: probes.sh <flm-binary> <outdir>}
mkdir -p "$outdir"

port=58601
base="http://127.0.0.1:$port"
libpath=/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib
health_url=http://127.0.0.1:13305/api/v1/health

server_pid=""
pass_count=0
fail_count=0
results=()

GENERIC_500='{"error":{"message":"Internal error","type":"server_error"}}'
GENERIC_400='{"error":{"message":"Invalid request","type":"invalid_request_error","code":"invalid_value"}}'

cleanup() {
  [[ -n "$server_pid" ]] && stop_server
  return 0
}
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

# wait_for_npu -- blocks until no flm process is running and the NPU health
# endpoint reports no loaded models. Polls every 30s, gives up after 30min.
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

# req METHOD PATH BODY -- prints request, response body, and HTTP code;
# sets last_code/last_body for assertions.
req() {
  local method=$1 path=$2 body=${3:-}
  local resp
  printf '$ %s %s %s\n' "$method" "$path" "$body"
  if [[ "$method" == GET ]]; then
    resp=$(curl -sS -m 120 -w '\nHTTP %{http_code}\n' "$base$path")
  else
    resp=$(curl -sS -m 120 -w '\nHTTP %{http_code}\n' -H 'Content-Type: application/json' \
      --data-binary "$body" "$base$path")
  fi
  last_code=$(tail -n1 <<<"$resp" | awk '{print $2}')
  last_body=$(sed '$d' <<<"$resp")
  printf '%s\nHTTP %s\n' "$last_body" "$last_code"
}

# json_eq A B -- true if both strings are the same JSON value (order-insensitive).
json_eq() {
  local a b
  a=$(jq -S . 2>/dev/null <<<"$1") || return 1
  b=$(jq -S . 2>/dev/null <<<"$2") || return 1
  [[ "$a" == "$b" ]]
}

# start_mode MODE [ENV_NAME] -- waits for the NPU, then backgrounds
# `flm serve llama3.2:1b --port $port` with ENV_NAME=1 set (if given).
start_mode() {
  local mode=$1 envname=${2:-}
  wait_for_npu || { echo "ABORT: NPU never became free for mode $mode" >&2; exit 1; }
  if pgrep -x flm >/dev/null; then
    echo "ABORT: flm already running before mode $mode" >&2
    exit 1
  fi
  if [[ -n "$envname" ]]; then
    env "$envname=1" LD_LIBRARY_PATH="$libpath" "$FLM" serve llama3.2:1b --port "$port" \
      >"$outdir/server-$mode.log" 2>&1 &
  else
    LD_LIBRARY_PATH="$libpath" "$FLM" serve llama3.2:1b --port "$port" \
      >"$outdir/server-$mode.log" 2>&1 &
  fi
  server_pid=$!
  local waited=0
  while (( waited < 300 )); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "server for $mode died before becoming ready (see $outdir/server-$mode.log)" >&2
      server_pid=""
      return 1
    fi
    curl -s -o /dev/null "$base/api/version" && return 0
    sleep 1
    (( waited++ ))
  done
  echo "server for $mode did not become ready within 300s" >&2
  return 1
}

# stop_server -- bounded TERM, wait up to 30s, then KILL; confirms flm is gone.
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

record() {
  local id=$1 status=$2 reason=${3:-}
  if [[ "$status" == PASS ]]; then
    echo "PASS $id"
    results+=("PASS $id")
    (( pass_count++ ))
  elif [[ "$status" == SKIP ]]; then
    echo "SKIP $id: $reason"
    results+=("SKIP $id: $reason")
  else
    echo "FAIL $id: $reason"
    results+=("FAIL $id: $reason")
    (( fail_count++ ))
  fi
}

print_handle_chat_errors() {
  local mode=$1
  echo "-- [ERROR] handle_chat lines for mode $mode --"
  grep -E '\[ERROR\][[:space:]]+handle_chat:' "$outdir/server-$mode.log" || echo "(none found)"
}

# ---- mode decode-fault ----
echo "== mode decode-fault =="
if start_mode decode-fault FLM_INJECT_DECODE_FAULT; then
  req POST /api/chat '{"model":"llama3.2:1b","messages":[{"role":"user","content":"Say hi"}],"stream":false}'
  if [[ "$last_code" == 500 ]] && json_eq "$last_body" "$GENERIC_500" && ! grep -qi injected <<<"$last_body"; then
    record decode-fault/a PASS
  else
    record decode-fault/a FAIL "expected HTTP 500 + $GENERIC_500, got HTTP $last_code: $last_body"
  fi

  req POST /api/generate '{"model":"llama3.2:1b","prompt":"Say hi","stream":false}'
  if [[ "$last_code" == 500 ]] && json_eq "$last_body" "$GENERIC_500"; then
    record decode-fault/b-control PASS
  else
    record decode-fault/b-control FAIL "expected HTTP 500 + $GENERIC_500, got HTTP $last_code: $last_body"
  fi

  print_handle_chat_errors decode-fault
else
  record decode-fault/startup FAIL "server did not become ready"
fi
stop_server

# ---- mode prefill-fault ----
echo "== mode prefill-fault =="
if start_mode prefill-fault FLM_INJECT_PREFILL_FAULT; then
  req POST /api/chat '{"model":"llama3.2:1b","messages":[{"role":"user","content":"Say hi"}],"stream":false}'
  if [[ "$last_code" == 400 ]] && json_eq "$last_body" "$GENERIC_400"; then
    record prefill-fault/c PASS
  else
    record prefill-fault/c FAIL "expected HTTP 400 + $GENERIC_400, got HTTP $last_code: $last_body"
  fi

  print_handle_chat_errors prefill-fault
else
  record prefill-fault/startup FAIL "server did not become ready"
fi
stop_server

# ---- mode plain ----
echo "== mode plain =="
if start_mode plain; then
  req POST /api/chat '{"model":"llama3.2:1b","messages":[{"role":"user","content":"Say hi"}],"stream":false,"options":"x"}'
  if [[ "$last_code" == 400 ]] && json_eq "$last_body" "$GENERIC_400"; then
    record plain/d PASS
  else
    record plain/d FAIL "expected HTTP 400 + $GENERIC_400, got HTTP $last_code: $last_body"
  fi

  # Attempt a cheap chat-template rejection: llama3.2:1b's chat_template
  # raises when tools are supplied in the user-message slot but, after the
  # leading system message is popped off, no user message remains to carry
  # them (minja raise_exception("Cannot put tools in the first user message
  # when there's no first user message!")).
  req POST /api/chat '{"model":"llama3.2:1b","messages":[{"role":"system","content":"You are terse."}],"stream":false,"tools":[{"type":"function","function":{"name":"noop","description":"no-op","parameters":{"type":"object","properties":{}}}}]}'
  if [[ "$last_code" == 400 ]] && json_eq "$last_body" "$GENERIC_400"; then
    record plain/e PASS
  elif [[ "$last_code" == 200 ]]; then
    record plain/e SKIP "attempted trigger (system-only messages + tools) did not raise a template exception; /api/chat likely doesn't forward tools into the chat template the way /v1/chat/completions does; got HTTP 200"
  else
    record plain/e FAIL "attempted trigger got unexpected HTTP $last_code: $last_body (expected 200-skip or 400 generic)"
  fi

  req POST /api/chat '{"model":"llama3.2:1b","messages":[{"role":"user","content":"Say hi"}],"stream":false}'
  if [[ "$last_code" == 200 ]] && jq -e '(.message.content | type == "string") and (.message.content | length > 0)' >/dev/null 2>&1 <<<"$last_body"; then
    record plain/f PASS
  else
    record plain/f FAIL "expected HTTP 200 + non-empty message.content, got HTTP $last_code: $last_body"
  fi

  print_handle_chat_errors plain
else
  record plain/startup FAIL "server did not become ready"
fi
stop_server

echo "== summary =="
for r in "${results[@]}"; do
  echo "$r"
done
echo "$pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
