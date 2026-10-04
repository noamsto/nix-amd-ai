#!/usr/bin/env bash
# probes.sh <flm-binary> <outdir> <base|new>
#
# Red/green for #204 and #205, two malformed-model_list.json paths in
# ensure_model_loaded that broke the #181 contract (a server-side config fault
# must fail the load as HTTP 500 model_load_failed without evicting the served
# model):
#
#   #205  a bare tag (no ":size") whose size map is an empty object reads
#         end().key() (undefined behavior); a non-object size map throws
#         invalid_iterator and is answered 400.
#   #204  an entry with a missing or non-array `files` for a model not on disk:
#         get_missing_files() swallows the type_error and reports nothing
#         missing, so the load reaches LM_Config::_load_json's exit(1) and the
#         process dies.
#
# Each case copies the shipped model_list.json, mutates the gemma4-it map, and
# points flm serve at it with FLM_CONFIG_PATH. The server is started with
# llama3.2:1b so there is a serving model to protect: GET /api/ps is checked
# before the failing request and again after it.
#
#   empty-size-map   models["gemma4-it"] = {}          request "gemma4-it"
#   array-size-map   models["gemma4-it"] = [<e4b>]     request "gemma4-it"
#   missing-files    e2b entry without `files`         request "gemma4-it:e2b"
#   nonarray-files   e2b entry with a string `files`   request "gemma4-it:e2b"
#
# gemma4-it:e2b is not downloaded, which the #204 mechanism requires. Only one
# flm may drive the NPU: wait for the NPU and lemond to be free before every
# start, and never kill a process this script did not start.
set -u

FLM=${1:?usage: probes.sh <flm-binary> <outdir> <base|new>}
outdir=${2:?usage: probes.sh <flm-binary> <outdir> <base|new>}
mode=${3:?usage: probes.sh <flm-binary> <outdir> <base|new>}
mkdir -p "$outdir"

port=58601
base="http://127.0.0.1:$port"
libpath=${XRT_LIB_DIR:-}
health_url=http://127.0.0.1:13305/api/v1/health

shipped_list="$(dirname "$FLM")/../share/flm/model_list.json"
llama_config="$HOME/.config/flm/models/Llama-3.2-1B-NPU2/config.json"
if [[ ! -f "$llama_config" ]]; then
  echo "ABORT: $llama_config not found; pull llama3.2:1b first" >&2
  exit 1
fi
e2b_dir="$HOME/.config/flm/models/Gemma4-E2B-IT-NPU2"
if [[ -e "$e2b_dir" ]]; then
  echo "ABORT: $e2b_dir exists; the #204 cases need gemma4-it:e2b not downloaded" >&2
  exit 1
fi

pass_count=0
fail_count=0
results=()

server_pid=""
cleanup() { [[ -n "$server_pid" ]] && stop_server; return 0; }
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
      echo "NPU still busy after ${waited}s, giving up" >&2
      return 1
    fi
    echo "NPU busy (pgrep flm or all_models_loaded=$loaded); waiting 30s..." >&2
    sleep 30
    (( waited += 30 ))
  done
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
  pgrep -x flm >/dev/null && { echo "WARN: flm still running after stop" >&2; return 1; }
  return 0
}

# scratch_model <out> <python-expr-on-model-list>
# The expression runs with `d` bound to the parsed model list.
scratch_model() {
  local out=$1 expr=$2 src
  src=$(dirname "$FLM")/../share/flm/model_list.json
  python3 - "$src" "$out" "$expr" <<'PY'
import json, sys
src, out, expr = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(src))
exec(expr, {"d": d})
json.dump(d, open(out, "w"), indent=4)
PY
}

req() {
  local method=$1 path=$2 body=${3:-}
  local resp
  printf '$ %s %s %s\n' "$method" "$path" "$body"
  if [[ "$method" == GET ]]; then
    resp=$(curl -sS -m 30 -w '\nHTTP %{http_code}\n' "$base$path")
  else
    resp=$(curl -sS -m 30 -w '\nHTTP %{http_code}\n' -H 'Content-Type: application/json' \
      --data-binary "$body" "$base$path")
  fi
  last_code=$(tail -n1 <<<"$resp" | awk '{print $2}')
  last_body=$(sed '$d' <<<"$resp")
  printf '%s\nHTTP %s\n' "$last_body" "$last_code"
}

ps_lists_llama() {
  curl -sS -m 30 "$base/api/ps" | jq -e '.models | any(.name == "llama3.2:1b")' >/dev/null 2>&1
}

record() {
  local id=$1 status=$2 reason=${3:-}
  if [[ "$status" == PASS ]]; then
    echo "PASS $id"; results+=("PASS $id"); (( pass_count++ ))
  else
    echo "FAIL $id: $reason"; results+=("FAIL $id: $reason"); (( fail_count++ ))
  fi
}

start_server() { # <model-list> <label>
  local list=$1 label=$2
  local tries=0
  # wait_for_npu() can return in the gap before another worker's flm starts;
  # re-check and keep waiting rather than aborting on that race.
  while :; do
    wait_for_npu || { echo "ABORT: NPU never became free for $label" >&2; return 1; }
    pgrep -x flm >/dev/null || break
    (( tries++ ))
    if (( tries >= 5 )); then
      echo "ABORT: flm still running before $label" >&2
      return 1
    fi
    sleep 10
  done
  if [[ -n "$libpath" ]]; then
    FLM_CONFIG_PATH="$list" LD_LIBRARY_PATH="$libpath" "$FLM" serve llama3.2:1b --port "$port" \
      >"$outdir/server-$label.log" 2>&1 &
  else
    FLM_CONFIG_PATH="$list" "$FLM" serve llama3.2:1b --port "$port" \
      >"$outdir/server-$label.log" 2>&1 &
  fi
  server_pid=$!
  local waited=0
  while (( waited < 300 )); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "server for $label died before ready" >&2
      server_pid=""; return 1
    fi
    curl -s -o /dev/null "$base/api/version" && return 0
    sleep 1; (( waited++ ))
  done
  echo "server for $label not ready within 300s" >&2
  return 1
}

# load_failed_body <model> -- the #181 contract body for a known model that
# could not be loaded.
load_failed_body() {
  local model=$1
  jq -cn --arg m "$model" '{error:{message:("model \u0027" + $m + "\u0027 is known to this build but could not be loaded; the server log says why"),type:"server_error",param:"model",code:"model_load_failed"}}'
}

json_eq() {
  local a b
  a=$(jq -S . 2>/dev/null <<<"$1") || return 1
  b=$(jq -S . 2>/dev/null <<<"$2") || return 1
  [[ "$a" == "$b" ]]
}

# run_case <label> <expr> <requested-model> <base-outcome>
# base-outcome: "400" (HTTP 400 invalid_request_error) or "dead" (the server
# exited). new mode always expects 500 + the model_load_failed body.
run_case() {
  local label=$1 expr=$2 model=$3 base_outcome=$4
  echo "== case $label ($mode) =="
  local list="$outdir/model_list.$label.json"
  scratch_model "$list" "$expr"
  if start_server "$list" "$label"; then
    req GET /api/ps
    if ps_lists_llama; then record "$label/loaded" PASS; else record "$label/loaded" FAIL "llama3.2:1b not listed before the request: $last_body"; fi

    req POST /v1/chat/completions '{"model":"'"$model"'","messages":[{"role":"user","content":"Say hi"}],"stream":false,"max_tokens":8}'
    if [[ "$mode" == new ]]; then
      if [[ "$last_code" == 500 ]] && json_eq "$last_body" "$(load_failed_body "$model")"; then
        record "$label/status" PASS
      else
        record "$label/status" FAIL "expected HTTP 500 + model_load_failed, got HTTP $last_code: $last_body"
      fi
    elif [[ "$base_outcome" == "crash-or-400" ]]; then
      if ! kill -0 "$server_pid" 2>/dev/null || [[ "$last_code" == 400 ]]; then
        record "$label/status" PASS
      else
        record "$label/status" FAIL "expected the red build to crash or answer 400, got HTTP $last_code: $last_body"
      fi
    elif [[ "$base_outcome" == dead ]]; then
      if kill -0 "$server_pid" 2>/dev/null; then
        record "$label/status" FAIL "expected the server to exit on the malformed entry, it is alive; HTTP $last_code: $last_body"
      else
        record "$label/status" PASS
      fi
    else
      if [[ "$last_code" == "$base_outcome" ]]; then record "$label/status" PASS
      else record "$label/status" FAIL "expected HTTP $base_outcome on the red build, got HTTP $last_code: $last_body"; fi
    fi

    if kill -0 "$server_pid" 2>/dev/null; then
      req GET /api/ps
      if ps_lists_llama; then record "$label/not-evicted" PASS; else record "$label/not-evicted" FAIL "llama3.2:1b evicted by the failed request: $last_body"; fi
    else
      record "$label/not-evicted" FAIL "server is not running after the failed request"
    fi

    echo "-- [ERROR] ensure_model_loaded line --"
    grep -E '\[ERROR\].*(malformed model-list entry|Failed to load model|handle_openai_chat_completion)' "$outdir/server-$label.log" || echo "(none found)"
  else
    record "$label/startup" FAIL "server did not become ready"
  fi
  stop_server
}

run_case empty-size-map 'd["models"]["gemma4-it"] = {}' 'gemma4-it' crash-or-400
run_case array-size-map 'd["models"]["gemma4-it"] = [d["models"]["gemma4-it"]["e4b"]]' 'gemma4-it' 400
run_case missing-files 'd["models"]["gemma4-it"]["e2b"].pop("files")' 'gemma4-it:e2b' dead
run_case nonarray-files 'd["models"]["gemma4-it"]["e2b"]["files"] = "not-an-array"' 'gemma4-it:e2b' dead

echo "== summary ($mode) =="
for r in "${results[@]}"; do echo "$r"; done
echo "$pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
