#!/usr/bin/env bash
# queued-cancel-model-swap.sh <flm-binary> <outdir> <label>
#
# #243: a request cancelled while it waits in the NPU queue must not load the
# model it names. #222 (cancel-queued-request.patch) already makes
# POST /api/cancel reach a request queued behind another, but the four handlers
# still call ensure_model_loaded() before their cancellation branch, so a queued
# request that names a different, already-downloaded chat model swaps to it
# before it answers cancelled. This probe reproduces that swap.
#
# The server starts with MODEL (llama3.2:1b). In each case A is a long streaming
# /api/generate that holds the NPU; B is queued behind it and names OTHER_MODEL
# (gemma4e-flash:e4b) with a caller request_id, then /api/cancel is posted while
# the server log shows B queued. /api/ps is read after B answers.
#
# Cases:
#   model-swap: streaming POST /api/generate. PASS iff cancel answered
#                   cancelled:true, B ends done_reason=cancel with 0 content
#                   lines, and /api/ps still lists MODEL.
#                   FAIL (red): /api/ps lists OTHER_MODEL -- B swapped to it
#                   before the cancel was observed.
#   chat-nonstream: non-streaming POST /api/chat. PASS iff the answer body is
#                   {} and /api/ps still lists MODEL. FAIL (red): ps OTHER_MODEL.
#   chat-completions-nonstream: non-streaming POST /v1/chat/completions. PASS iff
#                   the answer body is JSON null (the endpoint's cancelled shape;
#                   there is no cancelled:true in it) and ps still lists MODEL.
#                   FAIL (red): ps OTHER_MODEL.
#   chat-completions-stream: streaming POST /v1/chat/completions. PASS iff the
#                   SSE stream ends with data: [DONE], carries no assistant text
#                   delta, and ps still lists MODEL. FAIL (red): ps OTHER_MODEL.
#   completions-nonstream: non-streaming POST /v1/completions. PASS iff the
#                   answer body is {} and ps still lists MODEL. FAIL (red): ps
#                   OTHER_MODEL.
#   completions-stream: streaming POST /v1/completions. PASS iff the SSE stream
#                   ends with data: [DONE], carries no text, and ps still lists
#                   MODEL. FAIL (red): ps OTHER_MODEL.
#
# Every artifact this probe writes carries a ".ms" segment ($label.ms.results,
# server-$label.ms.log, $label.ms.cancels.jsonl, ...), so queued-cancel.sh can
# share one out dir without either probe erasing the other's run.
#
# Env: XRT_LIB (optional; the nix-build flm resolves xrt via RPATH),
#      PORT=58731, MODEL=llama3.2:1b, OTHER_MODEL=gemma4e-flash:e4b.
# Exits 0 iff no case FAILs.
set -u

FLM=${1:?usage: queued-cancel-model-swap.sh <flm-binary> <outdir> <label>}
outdir=${2:?usage: queued-cancel-model-swap.sh <flm-binary> <outdir> <label>}
label=${3:?usage: queued-cancel-model-swap.sh <flm-binary> <outdir> <label>}
mkdir -p "$outdir" || exit 1
outdir=$(cd "$outdir" && pwd) || exit 1

PORT=${PORT:-58731}
MODEL=${MODEL:-llama3.2:1b}
OTHER_MODEL=${OTHER_MODEL:-gemma4e-flash:e4b}
base=http://127.0.0.1:$PORT
results="$outdir/$label.ms.results"
log="$outdir/server-$label.ms.log"
cancels="$outdir/$label.ms.cancels.jsonl"
: >"$results"
: >"$cancels"

server_pid=""
stream_pid=""
start_err=""

cleanup() {
  local p
  for p in $(jobs -pr); do
    [[ "$p" == "$server_pid" ]] || kill "$p" 2>/dev/null
  done
  [[ -n "$server_pid" ]] && stop_server
  return 0
}
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

stop_server() {
  kill -TERM "$server_pid" 2>/dev/null
  local waited=0
  while (( waited < 15 )) && kill -0 "$server_pid" 2>/dev/null; do
    sleep 1
    (( waited++ ))
  done
  kill -0 "$server_pid" 2>/dev/null && kill -KILL "$server_pid" 2>/dev/null
  wait "$server_pid" 2>/dev/null
  server_pid=""
}

flm_running() { # a live (non-zombie) flm process exists
  local pid state
  for pid in $(pgrep -x flm); do
    state=$(ps -o stat= -p "$pid" 2>/dev/null)
    [[ -n "$state" && "$state" != Z* ]] && return 0
  done
  return 1
}

record() { # <name> <PASS|FAIL> <detail>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$results"
  echo "$2 $1: $3"
}

start_server() {
  local busy=0
  while flm_running; do
    if (( busy >= 1800 )); then
      start_err="NPU still busy after ${busy}s"; echo "$start_err" >&2
      return 1
    fi
    echo "another flm process is running; waiting 5s..." >&2
    sleep 5
    busy=$((busy + 5))
  done
  # shellcheck disable=SC2086
  if [[ -n "${XRT_LIB:-}" ]]; then
    LD_LIBRARY_PATH="$XRT_LIB" stdbuf -oL -eL "$FLM" serve "$MODEL" --port "$PORT" \
      >"$log" 2>&1 &
  else
    stdbuf -oL -eL "$FLM" serve "$MODEL" --port "$PORT" >"$log" 2>&1 &
  fi
  server_pid=$!
  local waited=0
  while (( waited < 300 )); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      start_err="server died before ready"; echo "$start_err" >&2
      server_pid=""; return 1
    fi
    curl -s -o /dev/null "$base/api/version" && return 0
    sleep 1; (( waited++ ))
  done
  start_err="server not ready within 300s"; echo "$start_err" >&2
  return 1
}

# start_request <path> <stream true|false> <model> <request_id|""> <max_tokens> <out>
# Streaming replies land raw in <out> (NDJSON for /api/generate, SSE for the
# /v1 endpoints); non-streaming replies land as the response body.
start_request() {
  local path=$1 stream=$2 model=$3 rid=$4 max_tokens=$5 out=$6 body
  local prompt="Write a long, detailed essay about the history of the printing press."
  case "$path" in
    /api/generate)
      body=$(jq -cn --arg m "$model" --arg rid "$rid" --arg p "$prompt" \
        --argjson s "$stream" --argjson n "$max_tokens" '
        {model: $m, stream: $s, max_tokens: $n, prompt: $p}
        + (if $rid == "" then {} else {request_id: $rid} end)')
      ;;
    /api/chat)
      body=$(jq -cn --arg m "$model" --arg rid "$rid" --arg p "$prompt" \
        --argjson s "$stream" --argjson n "$max_tokens" '
        {model: $m, stream: $s,
         messages: [{role: "user", content: $p}],
         options: {num_predict: $n}}
        + (if $rid == "" then {} else {request_id: $rid} end)')
      ;;
    /v1/chat/completions)
      body=$(jq -cn --arg m "$model" --arg rid "$rid" --arg p "$prompt" \
        --argjson s "$stream" --argjson n "$max_tokens" '
        {model: $m, stream: $s, max_tokens: $n,
         messages: [{role: "user", content: $p}]}
        + (if $rid == "" then {} else {request_id: $rid} end)')
      ;;
    /v1/completions)
      body=$(jq -cn --arg m "$model" --arg rid "$rid" --arg p "$prompt" \
        --argjson s "$stream" --argjson n "$max_tokens" '
        {model: $m, stream: $s, max_tokens: $n, prompt: $p}
        + (if $rid == "" then {} else {request_id: $rid} end)')
      ;;
    *)
      echo "unknown request path: $path" >&2
      return 1
      ;;
  esac
  : >"$out"
  curl -sN -X POST "$base$path" -H 'Content-Type: application/json' \
    -d "$body" >"$out" 2>/dev/null &
  stream_pid=$!
}

wait_first_content() { # <ndjson>
  local waited=0
  while (( waited < 60 )); do
    [[ -n $(jq -c 'select(.response != null and .response != "")' "$1" 2>/dev/null | head -n1) ]] && return 0
    sleep 1; (( waited++ ))
  done
  return 1
}

wait_stream_end() { # <pid> <timeout_s>
  local waited=0
  while (( waited < $2 )) && kill -0 "$1" 2>/dev/null; do
    sleep 1; (( waited++ ))
  done
  kill -0 "$1" 2>/dev/null && { kill "$1" 2>/dev/null; return 1; }
  wait "$1" 2>/dev/null
  return 0
}

queued_count() { grep -c "request queued.*$1" "$log" 2>/dev/null || true; }

wait_queued_after() { # <endpoint> <prior_count> <timeout_s>: a NEW queued line
  local target=$(( $2 + 1 )) waited=0 count
  while (( waited < $3 )); do
    count=$(queued_count "$1")
    [[ "${count:-0}" -ge "$target" ]] && return 0
    sleep 1; (( waited++ ))
  done
  return 1
}

cancel() { curl -s -m 10 -X POST "$base/api/cancel" -H 'Content-Type: application/json' \
  -d "{\"request_id\":\"$1\"}" | tee -a "$cancels"; }
done_reason() { jq -r 'select(.done == true) | .done_reason // "none"' "$1" 2>/dev/null | tail -n1; }
content_lines() { jq -c 'select(.response != null and .response != "")' "$1" 2>/dev/null | wc -l; }

sse_payloads() { sed -n 's/^data: //p' "$1" 2>/dev/null | tr -d '\r' | grep -v '^\[DONE\]$' | grep -v '^[[:space:]]*$'; }
sse_last_data() { sed -n 's/\r$//; /^data: /p' "$1" 2>/dev/null | tail -n1; }
sse_text_count() { # <chat|completions> <sse file>
  local kind=$1 file=$2
  if [[ "$kind" == chat ]]; then
    sse_payloads "$file" | jq -rs '[.[] | (.choices // [])[]? | (.delta // {}) | (.content // empty) | select(type == "string" and length > 0)] | length' 2>/dev/null
  else
    sse_payloads "$file" | jq -rs '[.[] | (.choices // [])[]? | (.text // empty) | select(type == "string" and length > 0)] | length' 2>/dev/null
  fi
}

ps_dump() { curl -s -m 10 "$base/api/ps"; }
ps_tags() { jq -r '[.models[]? | (.model // .name)] | join(",")' "$1" 2>/dev/null; }
ps_has() { jq -e --arg t "$1" 'any(.models[]?; ((.model // .name) == $t))' "$2" >/dev/null 2>&1; }
ps_clean() { ps_has "$MODEL" "$1" && ! ps_has "$OTHER_MODEL" "$1"; }

assert_model_swap() { # <b.ndjson> <cancelled> <ps file> <ps tags>
  local b=$1 cancelled=$2 psfile=$3 pstags=$4 reason blines
  reason=$(done_reason "$b"); reason=${reason:-none}
  blines=$(content_lines "$b")
  if [[ "$cancelled" == true && "$reason" == cancel && "$blines" -eq 0 ]] \
     && ps_clean "$psfile"; then
    record model-swap PASS "cancelled=$cancelled B_done_reason=$reason B_content_lines=$blines ps=[$pstags]"
  else
    record model-swap FAIL "cancelled=$cancelled B_done_reason=$reason B_content_lines=$blines ps=[$pstags] (want cancelled/true, cancel, 0, ps=[$MODEL])"
  fi
}

assert_chat_nonstream() { # <b.json> <cancelled> <ps file> <ps tags>
  local b=$1 cancelled=$2 psfile=$3 pstags=$4 answer
  answer=$(tr -d '[:space:]' <"$b" 2>/dev/null)
  if [[ "$cancelled" == true && "$answer" == "{}" ]] && ps_clean "$psfile"; then
    record chat-nonstream PASS "cancelled=$cancelled answer=$answer ps=[$pstags]"
  else
    record chat-nonstream FAIL "cancelled=$cancelled answer=$answer ps=[$pstags] (want cancelled/true, {}, ps=[$MODEL])"
  fi
}

assert_chat_completions_nonstream() { # <b.json> <cancelled> <ps file> <ps tags>
  local b=$1 cancelled=$2 psfile=$3 pstags=$4 answer
  answer=$(tr -d '[:space:]' <"$b" 2>/dev/null)
  if [[ "$cancelled" == true && "$answer" == "null" ]] && ps_clean "$psfile"; then
    record chat-completions-nonstream PASS "cancelled=$cancelled answer=$answer ps=[$pstags]"
  else
    record chat-completions-nonstream FAIL "cancelled=$cancelled answer=$answer ps=[$pstags] (want cancelled/true, null, ps=[$MODEL])"
  fi
}

assert_chat_completions_stream() { # <b.sse> <cancelled> <ps file> <ps tags>
  local b=$1 cancelled=$2 psfile=$3 pstags=$4 last texts
  last=$(sse_last_data "$b"); last=${last:-none}
  texts=$(sse_text_count chat "$b")
  if [[ "$cancelled" == true && "$last" == "data: [DONE]" && "${texts:-none}" == "0" ]] \
     && ps_clean "$psfile"; then
    record chat-completions-stream PASS "cancelled=$cancelled last=$last text_deltas=$texts ps=[$pstags]"
  else
    record chat-completions-stream FAIL "cancelled=$cancelled last=$last text_deltas=${texts:-none} ps=[$pstags] (want cancelled/true, data: [DONE], 0, ps=[$MODEL])"
  fi
}

assert_completions_nonstream() { # <b.json> <cancelled> <ps file> <ps tags>
  local b=$1 cancelled=$2 psfile=$3 pstags=$4 answer
  answer=$(tr -d '[:space:]' <"$b" 2>/dev/null)
  if [[ "$cancelled" == true && "$answer" == "{}" ]] && ps_clean "$psfile"; then
    record completions-nonstream PASS "cancelled=$cancelled answer=$answer ps=[$pstags]"
  else
    record completions-nonstream FAIL "cancelled=$cancelled answer=$answer ps=[$pstags] (want cancelled/true, {}, ps=[$MODEL])"
  fi
}

assert_completions_stream() { # <b.sse> <cancelled> <ps file> <ps tags>
  local b=$1 cancelled=$2 psfile=$3 pstags=$4 last texts
  last=$(sse_last_data "$b"); last=${last:-none}
  texts=$(sse_text_count completions "$b")
  if [[ "$cancelled" == true && "$last" == "data: [DONE]" && "${texts:-none}" == "0" ]] \
     && ps_clean "$psfile"; then
    record completions-stream PASS "cancelled=$cancelled last=$last text_parts=$texts ps=[$pstags]"
  else
    record completions-stream FAIL "cancelled=$cancelled last=$last text_parts=${texts:-none} ps=[$pstags] (want cancelled/true, data: [DONE], 0, ps=[$MODEL])"
  fi
}

run_case() { # <case> <tag> <path> <stream true|false> <max_tokens> <assert_fn>
  local case=$1 tag=$2 path=$3 stream=$4 max_tokens=$5 assert_fn=$6
  local a="$outdir/$label.ms.$tag.a.ndjson" b="$outdir/$label.ms.$tag.b.out"
  local psfile="$outdir/$label.ms.$tag.ps.json"
  local bid="$tag-$RANDOM$RANDOM" resp cancelled qc0 apid bpid
  start_request /api/generate true "$MODEL" "" 768 "$a"; apid=$stream_pid
  if ! wait_first_content "$a"; then record "$case" FAIL "A no content within 60s"; return; fi
  qc0=$(queued_count "$path")
  start_request "$path" "$stream" "$OTHER_MODEL" "$bid" "$max_tokens" "$b"; bpid=$stream_pid
  if ! wait_queued_after "$path" "$qc0" 60; then
    record "$case" FAIL "B never appeared in the NPU queue"; return
  fi
  # NB: jq's // treats false as a fallback, so read .cancelled directly.
  resp=$(cancel "$bid"); cancelled=$(jq -r '.cancelled' <<<"$resp" 2>/dev/null)
  # B can only dequeue once A releases the NPU, so wait A out first.
  if ! wait_stream_end "$apid" 300; then
    record "$case" FAIL "A stream did not finish within 300s"; return
  fi
  if ! wait_stream_end "$bpid" 600; then
    record "$case" FAIL "B did not finish within 600s"; return
  fi
  ps_dump >"$psfile"
  "$assert_fn" "$b" "$cancelled" "$psfile" "$(ps_tags "$psfile")"
}

if ! start_server; then
  record startup FAIL "$start_err"
  exit 1
fi

ps_dump >"$outdir/$label.ms.ps.start.json"
echo "start ps: $(ps_tags "$outdir/$label.ms.ps.start.json")" >&2
echo "queued so far: $(queued_count 'POST /api/generate')" >&2
run_case model-swap ms-generate /api/generate true 32 assert_model_swap
run_case chat-nonstream ms-chat /api/chat false 32 assert_chat_nonstream
run_case chat-completions-nonstream ms-chat-completions /v1/chat/completions false 32 assert_chat_completions_nonstream
run_case chat-completions-stream ms-chat-completions-stream /v1/chat/completions true 32 assert_chat_completions_stream
run_case completions-nonstream ms-completions /v1/completions false 32 assert_completions_nonstream
run_case completions-stream ms-completions-stream /v1/completions true 32 assert_completions_stream

echo "--- summary ($results)"
cat "$results"
! grep -q $'\tFAIL\t' "$results"
