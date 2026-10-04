#!/usr/bin/env bash
# probes.sh <flm-binary> <outdir> <base|new>
#
# Red/green for #220: LM_Config::_load_json() called exit(1) on a missing
# config.json, so a malformed model_list.json entry whose `files` omits
# config.json killed the process on paths other than the flm serve request
# path that #204/#205 already guard:
#
#   pull     `flm pull gemma4-it:e2b` runs is_model_downloaded() ->
#            check_model_compatibility() -> from_pretrained(), which reached
#            _load_json()'s exit(1).
#   asr      `flm serve -a 1` loads whisper-v3:turbo at startup and did the
#            same in ensure_asr_model_loaded().
#   embed    `flm serve -e 1` loads embed-gemma:300m at startup and did the
#            same in ensure_embed_model_loaded().
#
# base (red): the process exits with "Failed to open file" / the server dies
#             before it is ready.
# new  (green): pull prints a clean CLI error and exits 1; serve logs the fault,
#             drops the optional model and keeps serving the chat model.
#
# The model directory is pointed at a scratch FLM_MODEL_PATH so the malformed
# `files` entry really has no config.json on disk (gemma4-it:e2b, whisper-v3 and
# embed-gemma are absent; llama3.2:1b is symlinked in so serve has a chat model).
#
# The flm serve request path itself is covered by
# bench-logs/flm-malformed-model-list-204-205/probes.sh; run it in `new` mode
# against the same binary to confirm #219's 500 model_load_failed contract is
# untouched.
#
# Only one flm may drive the NPU: wait for the NPU and lemond to be free before
# every server start, and never kill a process this script did not start.
set -u

FLM=${1:?usage: probes.sh <flm-binary> <outdir> <base|new>}
outdir=${2:?usage: probes.sh <flm-binary> <outdir> <base|new>}
mode=${3:?usage: probes.sh <flm-binary> <outdir> <base|new>}
mkdir -p "$outdir"
FLM=$(readlink -f "$FLM")
# The unwrapped build needs the XRT tree that carries libxrt_driver_xdna.so;
# pass it as XRT_LIB_DIR (the wrapped flm sets an equivalent LD_LIBRARY_PATH).
libpath=${XRT_LIB_DIR:-}
if [[ -n "$libpath" ]]; then
  export LD_LIBRARY_PATH="$libpath${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

port=58602
base="http://127.0.0.1:$port"
health_url=http://127.0.0.1:13305/api/v1/health
shipped_list="$(dirname "$FLM")/../share/flm/model_list.json"
llama_src="$HOME/.config/flm/models/Llama-3.2-1B-NPU2"
if [[ ! -f "$shipped_list" ]]; then
  echo "ABORT: $shipped_list not found" >&2
  exit 1
fi
if [[ ! -d "$llama_src" ]]; then
  echo "ABORT: $llama_src not found; pull llama3.2:1b first" >&2
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

record() {
  local id=$1 status=$2 reason=${3:-}
  if [[ "$status" == PASS ]]; then
    echo "PASS $id"; results+=("PASS $id"); (( pass_count++ ))
  else
    echo "FAIL $id: $reason"; results+=("FAIL $id: $reason"); (( fail_count++ ))
  fi
}

# scratch_models <name> <python-expr-on-model-list>
# Creates <outdir>/models.<name>/{models,model_list.json}. The expr runs with
# `d` bound to the parsed shipped model list; llama3.2:1b is symlinked in.
scratch_models() {
  local name=$1 expr=$2
  local root="$outdir/models.$name"
  rm -rf "$root"
  mkdir -p "$root/models"
  ln -s "$llama_src" "$root/models/Llama-3.2-1B-NPU2"
  python3 - "$shipped_list" "$root/model_list.json" "$expr" <<'PY'
import json, sys
src, out, expr = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(src))
exec(expr, {"d": d})
json.dump(d, open(out, "w"), indent=4)
PY
  echo "$root"
}

run_pull_case() {
  echo "== case pull ($mode) =="
  local root
  root=$(scratch_models pull 'd["models"]["gemma4-it"]["e2b"]["files"] = [f for f in d["models"]["gemma4-it"]["e2b"]["files"] if f != "config.json"]')
  local out rc
  out=$(FLM_CONFIG_PATH="$root/model_list.json" FLM_MODEL_PATH="$root" \
        timeout 300 "$FLM" pull gemma4-it:e2b 2>&1)
  rc=$?
  printf '%s\n' "$out" > "$outdir/pull.log"
  printf '%s\n' "$out" | tail -25

  if [[ "$mode" == base ]]; then
    if [[ $rc -ne 0 ]] && grep -q 'Failed to open file' <<<"$out" && ! grep -q 'Failed to pull model' <<<"$out"; then
      record pull/exit-raw PASS
    else
      record pull/exit-raw FAIL "expected raw exit(1) ('Failed to open file', no 'Failed to pull model'), rc=$rc"
    fi
  else
    if [[ $rc -ne 0 ]] && grep -q 'Exception during download' <<<"$out" && grep -q 'Failed to pull model' <<<"$out"; then
      record pull/handled PASS
    else
      record pull/handled FAIL "expected handled error ('Exception during download' + 'Failed to pull model', nonzero), rc=$rc"
    fi
  fi
}

# start_server <model-list> <label> <extra flm args...>
start_server() {
  local list=$1 label=$2; shift 2
  local tries=0
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
  FLM_CONFIG_PATH="$list" FLM_MODEL_PATH="$(dirname "$list")" "$FLM" serve llama3.2:1b --port "$port" "$@" \
    >"$outdir/server-$label.log" 2>&1 &
  server_pid=$!
  local waited=0
  while (( waited < 300 )); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      return 1
    fi
    curl -s -o /dev/null "$base/api/version" && return 0
    sleep 1; (( waited++ ))
  done
  echo "server for $label not ready within 300s" >&2
  return 1
}

# run_serve_case <name> <expr> <flag> <skip-phrase>
run_serve_case() {
  local name=$1 expr=$2 flag=$3 skip=$4
  echo "== case $name ($mode) =="
  local root
  root=$(scratch_models "$name" "$expr")
  if start_server "$root/model_list.json" "$name" "$flag" 1; then
    if [[ "$mode" == new ]]; then
      local ps chat_code
      ps=$(curl -sS -m 30 "$base/api/ps")
      chat_code=$(curl -sS -m 60 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
        --data-binary '{"model":"llama3.2:1b","messages":[{"role":"user","content":"Say hi"}],"stream":false,"max_tokens":4}' \
        "$base/v1/chat/completions")
      if grep -q "$skip" "$outdir/server-$name.log" && jq -e '.models | any(.name == "llama3.2:1b")' <<<"$ps" >/dev/null 2>&1 && [[ "$chat_code" == 200 ]]; then
        record "$name/keeps-serving" PASS
      else
        record "$name/keeps-serving" FAIL "skip line / llama in /api/ps / chat 200 not all seen (chat=$chat_code)"
      fi
    else
      record "$name/red-alive" FAIL "expected the red build to die at startup, it is serving"
    fi
  else
    if [[ "$mode" == base ]]; then
      if grep -q 'Failed to open file' "$outdir/server-$name.log"; then
        record "$name/red-exit" PASS
      else
        record "$name/red-exit" FAIL "server died but without 'Failed to open file'"
      fi
    else
      record "$name/keeps-serving" FAIL "green build did not become ready: $(tail -3 "$outdir/server-$name.log" | tr '\n' ' ')"
    fi
  fi
  stop_server
}

run_pull_case
run_serve_case serve-asr \
  'd["models"]["whisper-v3"]["turbo"]["files"] = [f for f in d["models"]["whisper-v3"]["turbo"]["files"] if f != "config.json"]' \
  -a 'serving without ASR'
run_serve_case serve-embed \
  'd["models"]["embed-gemma"]["300m"]["files"] = [f for f in d["models"]["embed-gemma"]["300m"]["files"] if f != "config.json"]' \
  -e 'serving without embeddings'

echo "== summary ($mode) =="
for r in "${results[@]}"; do echo "$r"; done
echo "$pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
