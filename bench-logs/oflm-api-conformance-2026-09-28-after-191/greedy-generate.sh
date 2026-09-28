#!/usr/bin/env bash
# greedy-generate.sh <flm-binary> <outdir>
#
# /api/generate never applies a request's sampling options, so on the fresh
# server disconnect.sh starts per endpoint it samples with the default
# (random) sampler and its `full` replies cannot be byte-compared across
# builds. This primes the sampler with a one-token greedy /api/chat (top_k 1),
# which /api/generate then inherits, and records a streaming and a
# non-streaming /api/generate reply per model, as <outdir>/<model>.<case>.content.
set -u

FLM=${1:?usage: greedy-generate.sh <flm-binary> <outdir>}
outdir=${2:?usage: greedy-generate.sh <flm-binary> <outdir>}
mkdir -p "$outdir" || exit 1
libpath=/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib
prompt="Write a detailed essay of at least 2000 words on the history of the printing press."
pid=""

stop() {
  [[ -z "$pid" ]] && return
  kill -TERM "$pid" 2>/dev/null
  local waited=0
  while (( waited < 30 )) && kill -0 "$pid" 2>/dev/null; do sleep 1; (( waited++ )); done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  pid=""
}
trap stop EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

run_model() { # <model> <port> <label>
  local model=$1 port=$2 label=$3 ready=0 base="http://127.0.0.1:$2" body reply
  pgrep -x flm >/dev/null && { echo "flm already running" >&2; exit 1; }
  LD_LIBRARY_PATH=$libpath "$FLM" serve "$model" --port "$port" >"$outdir/server-$label.log" 2>&1 &
  pid=$!
  for _ in $(seq 300); do
    kill -0 "$pid" 2>/dev/null || { echo "server died" >&2; exit 1; }
    curl -s -o /dev/null "$base/api/version" && { ready=1; break; }
    sleep 1
  done
  (( ready )) || { echo "server not ready within 300s" >&2; exit 1; }

  body=$(jq -cn --arg m "$model" '{model: $m, messages: [{role: "user", content: "Say hi."}], stream: false, top_k: 1, options: {num_predict: 1}}')
  curl -sf "$base/api/chat" -H 'Content-Type: application/json' -d "$body" >/dev/null \
    || { echo "primer failed" >&2; exit 1; }

  body=$(jq -cn --arg m "$model" --arg p "$prompt" '{model: $m, prompt: $p, stream: true, max_tokens: 512}')
  reply=$(curl -sfN "$base/api/generate" -H 'Content-Type: application/json' -d "$body") \
    || { echo "streaming generate failed" >&2; exit 1; }
  jq -je '.response // empty' <<<"$reply" >"$outdir/$label.generate.content"
  jq -c 'select(.done) | {done_reason, eval_count}' <<<"$reply"

  body=$(jq -c '.stream = false' <<<"$body")
  reply=$(curl -sf "$base/api/generate" -H 'Content-Type: application/json' -d "$body") \
    || { echo "non-streaming generate failed" >&2; exit 1; }
  jq -je '.response' <<<"$reply" >"$outdir/$label.generate-ns.content"
  jq -c '{done_reason, eval_count}' <<<"$reply"
  stop
  pgrep -x flm >/dev/null && { echo "stray flm" >&2; exit 1; }
  return 0
}

run_model llama3.2:1b 58601 llama
run_model gemma4-it:e4b 58603 gemma4
