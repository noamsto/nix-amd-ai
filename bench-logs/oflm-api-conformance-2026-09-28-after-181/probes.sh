#!/usr/bin/env bash
# probes.sh <flm-binary> <outdir> <base|new>
#
# Red/green for #181: a malformed details.family in model_list.json is a
# server-side config fault and must fail the model load as
# 500 model_load_failed, not surface as a 400 Invalid request. Two malformations
# are exercised, each against a scratch model_list.json (FLM_CONFIG_PATH):
#
#   missing-family  the gemma4-it:e4b entry has no details.family. The read is
#                   before anything is unloaded, so the loaded model survives.
#   unknown-family  the entry's details.family is a string the build does not
#                   know ("bogus-family"). This one is read again inside
#                   get_auto_model() after the old engine is released, so the
#                   load failure does evict the serving model on both builds.
#
# Expected: base build (the #180 tip) answers missing-family 400 invalid_request
# and unknown-family 500 server_error; new build answers both 500
# model_load_failed. `base`/`new` selects the oracle.
set -u

FLM=${1:?usage: probes.sh <flm-binary> <outdir> <base|new>}
outdir=${2:?usage: probes.sh <flm-binary> <outdir> <base|new>}
mode=${3:?usage: probes.sh <flm-binary> <outdir> <base|new>}
mkdir -p "$outdir"

port=58601
base="http://127.0.0.1:$port"
libpath=${XRT_LIB_DIR:?set XRT_LIB_DIR to the xrt-combined lib dir}
health_url=http://127.0.0.1:13305/api/v1/health

pass_count=0
fail_count=0
results=()

BAD400='{"error":{"message":"Invalid request","type":"invalid_request_error","code":"invalid_value"}}'
BAD500='{"error":{"message":"Internal error","type":"server_error"}}'
LOAD500='{"error":{"message":"model '"'"'gemma4-it:e4b'"'"' is known to this build but could not be loaded; the server log says why","type":"server_error","param":"model","code":"model_load_failed"}}'

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

# scratch_model <out> <python-expr-on-entry> -- copy the shipped model_list.json
# and mutate the gemma4-it:e4b entry.
scratch_model() {
  local out=$1 expr=$2 src
  src=$(dirname "$FLM")/../share/flm/model_list.json
  python3 - "$src" "$out" "$expr" <<'PY'
import json, sys
src, out, expr = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(src))
entry = d["models"]["gemma4-it"]["e4b"]
exec(expr, {"entry": entry})
json.dump(d, open(out, "w"), indent=4)
PY
}

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

json_eq() {
  local a b
  a=$(jq -S . 2>/dev/null <<<"$1") || return 1
  b=$(jq -S . 2>/dev/null <<<"$2") || return 1
  [[ "$a" == "$b" ]]
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
  wait_for_npu || { echo "ABORT: NPU never became free for $label" >&2; exit 1; }
  pgrep -x flm >/dev/null && { echo "ABORT: flm already running before $label" >&2; exit 1; }
  FLM_CONFIG_PATH="$list" LD_LIBRARY_PATH="$libpath" "$FLM" serve llama3.2:1b --port "$port" \
    >"$outdir/server-$label.log" 2>&1 &
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

# ------------------------------------------------ missing-family
echo "== case missing-family ($mode) =="
list_missing="$outdir/model_list.missing-family.json"
scratch_model "$list_missing" 'entry["details"].pop("family")'
if start_server "$list_missing" missing-family; then
  req GET /api/ps
  if ps_lists_llama; then record missing-family/loaded PASS; else record missing-family/loaded FAIL "llama3.2:1b not listed before the request: $last_body"; fi

  req POST /v1/chat/completions '{"model":"gemma4-it:e4b","messages":[{"role":"user","content":"Say hi"}],"stream":false,"max_tokens":8}'
  if [[ "$mode" == new ]]; then
    if [[ "$last_code" == 500 ]] && json_eq "$last_body" "$LOAD500"; then record missing-family/status PASS
    else record missing-family/status FAIL "expected HTTP 500 + $LOAD500, got HTTP $last_code: $last_body"; fi
  else
    if [[ "$last_code" == 400 ]] && json_eq "$last_body" "$BAD400"; then record missing-family/status PASS
    else record missing-family/status FAIL "expected HTTP 400 + $BAD400, got HTTP $last_code: $last_body"; fi
  fi

  req GET /api/ps
  if ps_lists_llama; then record missing-family/not-evicted PASS; else record missing-family/not-evicted FAIL "llama3.2:1b evicted by the failed request: $last_body"; fi

  echo "-- [ERROR] ensure_model_loaded line --"
  grep -E '\[ERROR\].*(malformed model-list entry|Failed to load model)' "$outdir/server-missing-family.log" || echo "(none found)"
else
  record missing-family/startup FAIL "server did not become ready"
fi
stop_server

# ------------------------------------------------ unknown-family
echo "== case unknown-family ($mode) =="
list_unknown="$outdir/model_list.unknown-family.json"
scratch_model "$list_unknown" 'entry["details"]["family"] = "bogus-family"'
if start_server "$list_unknown" unknown-family; then
  req GET /api/ps
  if ps_lists_llama; then record unknown-family/loaded PASS; else record unknown-family/loaded FAIL "llama3.2:1b not listed before the request: $last_body"; fi

  req POST /v1/chat/completions '{"model":"gemma4-it:e4b","messages":[{"role":"user","content":"Say hi"}],"stream":false,"max_tokens":8}'
  if [[ "$mode" == new ]]; then
    if [[ "$last_code" == 500 ]] && json_eq "$last_body" "$LOAD500"; then record unknown-family/status PASS
    else record unknown-family/status FAIL "expected HTTP 500 + $LOAD500, got HTTP $last_code: $last_body"; fi
  else
    if [[ "$last_code" == 500 ]] && json_eq "$last_body" "$BAD500"; then record unknown-family/status PASS
    else record unknown-family/status FAIL "expected HTTP 500 + $BAD500, got HTTP $last_code: $last_body"; fi
  fi

  echo "-- [ERROR] ensure_model_loaded line --"
  grep -E '\[ERROR\].*(malformed model-list entry|Failed to load model)' "$outdir/server-unknown-family.log" || echo "(none found)"
else
  record unknown-family/startup FAIL "server did not become ready"
fi
stop_server

echo "== summary ($mode) =="
for r in "${results[@]}"; do echo "$r"; done
echo "$pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
