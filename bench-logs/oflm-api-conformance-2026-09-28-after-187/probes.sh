#!/usr/bin/env bash
# probes.sh <flm-binary> <outdir>
#
# Red/green for #187: streaming /api/chat ran insert() twice and never called
# generate(). The second insert() prefix-matched the whole prompt against the
# history the first one wrote, prefilled zero tokens, and sampled an empty
# logits buffer. The probe asserts the contract, so a build with the bug fails
# the stream-chat checks and a fixed build passes them all.
#
# Per model (llama3.2:1b on 58601, gemma4-it:e4b on 58603), in this order:
#   nonstream-chat   POST /api/chat, "stream": false
#   stream-openai    POST /v1/chat/completions, "stream": true
#   stream-chat      POST /api/chat, "stream": true  (the #187 path)
#   nonstream-after  POST /api/chat, "stream": false, same prompt again
#
# The two unchanged paths run first, so the red build still answers them before
# stream-chat takes it down. Every request pins top_k=1 (Sampler::sample takes
# the greedy path), so each case's content is written to
# <outdir>/<model>.<case>.content for a byte diff against another build, and
# nonstream-after must repeat nonstream-chat exactly: the streaming request has
# to leave no context behind.
set -u

FLM=${1:?usage: probes.sh <flm-binary> <outdir>}
outdir=${2:?usage: probes.sh <flm-binary> <outdir>}
mkdir -p "$outdir"

libpath=${XRT_LIB_DIR:?set XRT_LIB_DIR to the xrt-combined lib dir}
health_url=http://127.0.0.1:13305/api/v1/health
prompt="Count from 1 to 5, separated by commas."
num_predict=32

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

start_server() { # <model> <port> <label>
  local model=$1 port=$2 label=$3
  wait_for_npu || { echo "ABORT: NPU never became free for $label" >&2; exit 1; }
  pgrep -x flm >/dev/null && { echo "ABORT: flm already running before $label" >&2; exit 1; }
  LD_LIBRARY_PATH="$libpath" "$FLM" serve "$model" --port "$port" \
    >"$outdir/server-$label.log" 2>&1 &
  server_pid=$!
  local waited=0
  while (( waited < 300 )); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "server for $label died before ready" >&2
      server_pid=""; return 1
    fi
    curl -s -o /dev/null "http://127.0.0.1:$port/api/version" && return 0
    sleep 1; (( waited++ ))
  done
  echo "server for $label not ready within 300s" >&2
  return 1
}

record() {
  local id=$1 status=$2 reason=${3:-}
  if [[ "$status" == PASS ]]; then
    echo "PASS $id"; results+=("PASS $id"); (( pass_count++ ))
  else
    echo "FAIL $id: $reason"; results+=("FAIL $id: $reason"); (( fail_count++ ))
  fi
}

# stream_req <url> <body> <transcript> -- POST and read the reply line by line,
# stamping each line with its arrival time (seconds since the request was sent).
# Prints one summary line: "HTTP <code> lines=<n> first_line_s=<t> total_s=<t>",
# or "HTTP 000 error=<why>" when the connection fails.
stream_req() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, time, urllib.request, urllib.error
url, body, transcript = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(url, data=body.encode(), headers={"Content-Type": "application/json"})
t0 = time.monotonic()
lines, first, code = 0, None, 0
with open(transcript, "w") as out:
    try:
        resp = urllib.request.urlopen(req, timeout=180)
        code = resp.status
    except urllib.error.HTTPError as e:
        resp, code = e, e.code
    except Exception as e:
        print(f"HTTP 000 error={type(e).__name__}: {e}")
        sys.exit(0)
    try:
        for raw in resp:
            t = time.monotonic() - t0
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            if not line:
                continue
            first = t if first is None else first
            lines += 1
            out.write(f"{t:8.3f}\t{line}\n")
    except Exception as e:
        out.write(f"{time.monotonic() - t0:8.3f}\t<read error {type(e).__name__}: {e}>\n")
print(f"HTTP {code} lines={lines} first_line_s={first if first is None else round(first, 3)} total_s={round(time.monotonic() - t0, 3)}")
PY
}

# ndjson_body <transcript> -- the transcript's lines without their timestamps.
ndjson_body() { cut -f2- "$1"; }

server_alive() { kill -0 "$server_pid" 2>/dev/null; }

probe_model() { # <model> <port> <label>
  local model=$1 port=$2 label=$3 base="http://127.0.0.1:$2"
  local chat_body stream_body openai_body t summary code prefills_before prefills_after

  echo "== $label ($model) =="
  if ! start_server "$model" "$port" "$label"; then
    record "$label/startup" FAIL "server did not become ready"
    return
  fi

  chat_body=$(jq -cn --arg m "$model" --arg p "$prompt" --argjson n "$num_predict" \
    '{model:$m, messages:[{role:"user", content:$p}], stream:false, top_k:1, options:{num_predict:$n}}')
  stream_body=$(jq -c '.stream = true' <<<"$chat_body")
  openai_body=$(jq -cn --arg m "$model" --arg p "$prompt" --argjson n "$num_predict" \
    '{model:$m, messages:[{role:"user", content:$p}], stream:true, top_k:1, max_tokens:$n}')

  # ---- nonstream-chat
  t="$outdir/$label.nonstream-chat.ndjson"
  printf '$ POST /api/chat %s\n' "$chat_body"
  summary=$(stream_req "$base/api/chat" "$chat_body" "$t"); echo "$summary"; ndjson_body "$t"
  code=$(awk '{print $2}' <<<"$summary")
  if [[ "$code" == 200 ]] && ndjson_body "$t" | jq -e '.done == true and .eval_count > 0 and (.message.content | length > 0)' >/dev/null 2>&1; then
    record "$label/nonstream-chat" PASS
  else
    record "$label/nonstream-chat" FAIL "expected 200 with done:true, eval_count>0 and content; got $summary"
  fi
  ndjson_body "$t" | jq -j '.message.content // empty' >"$outdir/$label.nonstream-chat.content" 2>/dev/null

  # ---- stream-openai
  t="$outdir/$label.stream-openai.sse"
  printf '$ POST /v1/chat/completions %s\n' "$openai_body"
  summary=$(stream_req "$base/v1/chat/completions" "$openai_body" "$t"); echo "$summary"
  code=$(awk '{print $2}' <<<"$summary")
  local sse_json sse_last
  sse_json=$(ndjson_body "$t" | sed -n 's/^data: //p' | grep -v '^\[DONE\]$')
  sse_last=$(ndjson_body "$t" | tail -n1)
  printf '%s\n' "$sse_json" | jq -j '.choices[0].delta.content // empty' >"$outdir/$label.stream-openai.content" 2>/dev/null
  echo "content: $(cat "$outdir/$label.stream-openai.content")"
  if [[ "$code" == 200 && "$sse_last" == "data: [DONE]" ]] && [[ -s "$outdir/$label.stream-openai.content" ]] \
    && printf '%s\n' "$sse_json" | jq -se 'map(.choices[0].finish_reason // empty) | length == 1' >/dev/null 2>&1; then
    record "$label/stream-openai" PASS
  else
    record "$label/stream-openai" FAIL "expected 200, delta content, one finish_reason and data: [DONE]; got $summary, last line: $sse_last"
  fi

  # ---- stream-chat (#187)
  t="$outdir/$label.stream-chat.ndjson"
  prefills_before=$(grep -c 'Prefill chunk' "$outdir/server-$label.log")
  printf '$ POST /api/chat %s\n' "$stream_body"
  summary=$(stream_req "$base/api/chat" "$stream_body" "$t"); echo "$summary"; cat "$t"
  code=$(awk '{print $2}' <<<"$summary")
  sleep 1
  prefills_after=$(grep -c 'Prefill chunk' "$outdir/server-$label.log")
  echo "prefill log lines during stream-chat: $((prefills_after - prefills_before))"
  ndjson_body "$t" | jq -j '.message.content // empty' >"$outdir/$label.stream-chat.content" 2>/dev/null
  echo "content: $(cat "$outdir/$label.stream-chat.content")"

  if server_alive; then record "$label/stream-chat/server-alive" PASS
  else record "$label/stream-chat/server-alive" FAIL "flm serve exited during the request (see server-$label.log)"; fi

  if [[ "$code" == 200 ]] && ndjson_body "$t" | jq -se '
      length >= 2
      and (.[:-1] | all(.done == false) and any(.message.content | length > 0))
      and (.[-1] | .done == true and .eval_count > 0 and .prompt_eval_count > 0 and (.done_reason | type == "string"))' >/dev/null 2>&1; then
    record "$label/stream-chat/tokens" PASS
  else
    record "$label/stream-chat/tokens" FAIL "expected 200, content chunks with done:false, then one done:true chunk with eval_count>0; got $summary"
  fi

  if cmp -s "$outdir/$label.stream-chat.content" "$outdir/$label.nonstream-chat.content"; then
    record "$label/stream-chat/matches-nonstream" PASS
  else
    record "$label/stream-chat/matches-nonstream" FAIL "streamed content differs from the non-streaming reply"
  fi

  # ---- nonstream-after
  if server_alive; then
    t="$outdir/$label.nonstream-after.ndjson"
    printf '$ POST /api/chat %s\n' "$chat_body"
    summary=$(stream_req "$base/api/chat" "$chat_body" "$t"); echo "$summary"
    ndjson_body "$t" | jq -j '.message.content // empty' >"$outdir/$label.nonstream-after.content" 2>/dev/null
    if cmp -s "$outdir/$label.nonstream-after.content" "$outdir/$label.nonstream-chat.content"; then
      record "$label/nonstream-after" PASS
    else
      record "$label/nonstream-after" FAIL "the same non-streaming request answered differently after stream-chat; got $summary"
    fi
  else
    record "$label/nonstream-after" FAIL "server is gone"
  fi

  stop_server
}

probe_model llama3.2:1b 58601 llama
probe_model gemma4-it:e4b 58603 gemma4

echo "== summary =="
for r in "${results[@]}"; do echo "$r"; done
echo "$pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
