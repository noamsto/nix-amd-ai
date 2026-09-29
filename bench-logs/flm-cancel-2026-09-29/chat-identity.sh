#!/usr/bin/env bash
# chat-identity.sh <flm-binary> <outdir> <label>
#
# Non-streaming /api/chat identity/conformance snapshot: two requests per
# model (a single-turn prompt, and a multi-turn conversation where the model
# should recall a name given earlier -- gemma4e-flash is single-turn only, so
# it gets a second single-turn prompt instead). Bodies use top_k 1 for
# reproducibility. Saved with timing fields stripped so runs can be diffed.
#
# ${MODELS:-...} to limit models; ports start at 58611 and increment per
# model in list order.
set -u

FLM=${1:?usage: chat-identity.sh <flm-binary> <outdir> <label>}
outdir=${2:?usage: chat-identity.sh <flm-binary> <outdir> <label>}
label=${3:?usage: chat-identity.sh <flm-binary> <outdir> <label>}
mkdir -p "$outdir" || exit 1
outdir=$(cd "$outdir" && pwd) || exit 1

libpath=${XRT_LIB:?set XRT_LIB to the xrt-combined lib dir}
[[ -d "$libpath" ]] || { echo "libpath not found: $libpath" >&2; exit 1; }
health_url=http://127.0.0.1:13305/api/v1/health

identity_dir="$outdir/identity/$label"
mkdir -p "$identity_dir" || exit 1

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

stamp() {
  python3 -u -c '
import sys, time
for line in sys.stdin:
    sys.stdout.write(f"{time.time():.3f}\t{line}")
    sys.stdout.flush()
'
}

start_server() { # <model> <port> <run_label>
  local model=$1 port=$2 run_label=$3
  wait_for_npu || { echo "ABORT: NPU never became free for $run_label" >&2; exit 1; }
  pgrep -x flm >/dev/null && { echo "ABORT: flm already running before $run_label" >&2; exit 1; }
  LD_LIBRARY_PATH="$libpath" stdbuf -oL -eL "$FLM" serve "$model" --port "$port" \
    > >(stamp >"$outdir/server-identity-$run_label.log") 2>&1 &
  server_pid=$!
  local waited=0
  while (( waited < 300 )); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "server for $run_label died before ready" >&2
      server_pid=""; return 1
    fi
    curl -s -o /dev/null "http://127.0.0.1:$port/api/version" && return 0
    sleep 1; (( waited++ ))
  done
  echo "server for $run_label not ready within 300s" >&2
  return 1
}

# chat_request <port> <model> <messages-json> <out-prefix> -- POST a
# non-streaming /api/chat request; saves the raw body and the body with
# timing fields stripped, plus the HTTP status.
chat_request() {
  local port=$1 model=$2 messages_json=$3 out_prefix=$4 status
  status=$(curl -s -o "$out_prefix.raw" -w '%{http_code}' --max-time 600 \
    "http://127.0.0.1:$port/api/chat" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg model "$model" --argjson messages "$messages_json" \
      '{model: $model, messages: $messages, top_k: 1, stream: false, options: {num_predict: 256}}')")
  jq -S 'del(.total_duration, .load_duration, .prompt_eval_duration, .eval_duration)' \
    "$out_prefix.raw" >"$out_prefix.json"
  echo "status=$status -> $out_prefix.json"
}

port=58611
models=${MODELS:-llama3.2:1b gemma4-it:e4b gemma4e-flash:e4b qwen3.6-moe:35b-a3b}
for model in $models; do
  safe_model=${model//:/_}
  run_label="$label.$safe_model"
  if ! start_server "$model" "$port" "$run_label"; then
    (( port++ ))
    continue
  fi

  req1='[{"role": "user", "content": "Explain in a few paragraphs how a bicycle gear system works."}]'
  chat_request "$port" "$model" "$req1" "$identity_dir/$safe_model.1"

  if [[ "$model" == gemma4e-flash:e4b ]]; then
    req2='[{"role": "user", "content": "List five uses of copper and why."}]'
  else
    req2='[{"role": "user", "content": "My name is Ada."},
           {"role": "assistant", "content": "Nice to meet you, Ada."},
           {"role": "user", "content": "What is my name, and what is a good name for a cat?"}]'
  fi
  chat_request "$port" "$model" "$req2" "$identity_dir/$safe_model.2"

  stop_server
  (( port++ ))
done
