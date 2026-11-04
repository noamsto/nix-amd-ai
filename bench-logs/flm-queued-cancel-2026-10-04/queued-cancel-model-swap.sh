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
#   model-swap:     streaming /api/generate. PASS iff cancel answered
#                   cancelled:true, B ends done_reason=cancel with 0 content
#                   lines, and /api/ps still lists MODEL.
#                   FAIL (red): /api/ps lists OTHER_MODEL -- B swapped to it
#                   before the cancel was observed.
#   chat-nonstream: non-streaming /api/chat, same pattern. PASS iff the answer
#                   body is {} and /api/ps still lists MODEL.
#                   FAIL (red): /api/ps lists OTHER_MODEL.
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
results="$outdir/$label.results"
log="$outdir/server-$label.log"
cancels="$outdir/$label.cancels.jsonl"
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

# start_stream <model> <request_id|""> <out.ndjson>: streaming POST /api/generate
start_stream() {
  local model=$1 rid=$2 out=$3 body
  body=$(jq -cn --arg m "$model" --arg rid "$rid" '
    {model: $m, stream: true, max_tokens: 768,
     prompt: "Write a long, detailed essay about the history of the printing press."}
    + (if $rid == "" then {} else {request_id: $rid} end)')
  : >"$out"
  curl -sN -X POST "$base/api/generate" -H 'Content-Type: application/json' \
    -d "$body" >"$out" 2>/dev/null &
  stream_pid=$!
}

# start_chat_nonstream <model> <request_id> <out.json>: non-streaming /api/chat
start_chat_nonstream() {
  local model=$1 rid=$2 out=$3 body
  body=$(jq -cn --arg m "$model" --arg rid "$rid" '
    {model: $m, stream: false, request_id: $rid,
     messages: [{role: "user",
                 content: "Write a long, detailed essay about the history of the printing press."}],
     options: {num_predict: 768}}')
  : >"$out"
  curl -s -X POST "$base/api/chat" -H 'Content-Type: application/json' \
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
  local target=$(( $2 + 1 )) waited=0
  while (( waited < $3 )); do
    [[ "$(queued_count "$1")" -ge "$target" ]] && return 0
    sleep 1; (( waited++ ))
  done
  return 1
}

cancel() { curl -s -m 10 -X POST "$base/api/cancel" -H 'Content-Type: application/json' \
  -d "{\"request_id\":\"$1\"}" | tee -a "$cancels"; }
done_reason() { jq -r 'select(.done == true) | .done_reason // "none"' "$1" 2>/dev/null | tail -n1; }
content_lines() { jq -c 'select(.response != null and .response != "")' "$1" 2>/dev/null | wc -l; }

ps_dump() { curl -s -m 10 "$base/api/ps"; }
ps_tags() { jq -r '[.models[]? | (.model // .name)] | join(",")' "$1" 2>/dev/null; }
ps_has() { jq -e --arg t "$1" 'any(.models[]?; ((.model // .name) == $t))' "$2" >/dev/null 2>&1; }

case_model_swap() {
  local a="$outdir/$label.ms.a.ndjson" b="$outdir/$label.ms.b.ndjson"
  local bid="ms-$RANDOM$RANDOM" resp cancelled reason blines psfile pstags qc0
  psfile="$outdir/$label.ms.ps.json"
  start_stream "$MODEL" "" "$a"; local apid=$stream_pid
  if ! wait_first_content "$a"; then record model-swap FAIL "A no content within 60s"; return; fi
  qc0=$(queued_count "POST /api/generate")
  start_stream "$OTHER_MODEL" "$bid" "$b"; local bpid=$stream_pid
  if ! wait_queued_after "POST /api/generate" "$qc0" 60; then
    record model-swap FAIL "B never appeared in the NPU queue"; return
  fi
  # NB: jq's // treats false as a fallback, so read .cancelled directly.
  resp=$(cancel "$bid"); cancelled=$(jq -r '.cancelled' <<<"$resp" 2>/dev/null)
  # B can only dequeue once A releases the NPU, so wait A out first.
  wait_stream_end "$apid" 300 || echo "A stream did not finish within 300s" >&2
  wait_stream_end "$bpid" 600 || echo "B stream did not finish within 600s" >&2
  reason=$(done_reason "$b"); reason=${reason:-none}
  blines=$(content_lines "$b")
  ps_dump >"$psfile"
  pstags=$(ps_tags "$psfile")
  if [[ "$cancelled" == true && "$reason" == cancel && "$blines" -eq 0 ]] \
     && ps_has "$MODEL" "$psfile" && ! ps_has "$OTHER_MODEL" "$psfile"; then
    record model-swap PASS "cancelled=$cancelled B_done_reason=$reason B_content_lines=$blines ps=[$pstags]"
  else
    record model-swap FAIL "cancelled=$cancelled B_done_reason=$reason B_content_lines=$blines ps=[$pstags] (want cancelled/true, cancel, 0, ps=[$MODEL])"
  fi
}

case_chat_nonstream() {
  local a="$outdir/$label.cn.a.ndjson" b="$outdir/$label.cn.b.json"
  local bid="cn-$RANDOM$RANDOM" resp cancelled answer psfile pstags qc0
  psfile="$outdir/$label.cn.ps.json"
  start_stream "$MODEL" "" "$a"; local apid=$stream_pid
  if ! wait_first_content "$a"; then record chat-nonstream FAIL "A no content within 60s"; return; fi
  qc0=$(queued_count "POST /api/chat")
  start_chat_nonstream "$OTHER_MODEL" "$bid" "$b"; local bpid=$stream_pid
  if ! wait_queued_after "POST /api/chat" "$qc0" 60; then
    record chat-nonstream FAIL "B never appeared in the NPU queue"; return
  fi
  resp=$(cancel "$bid"); cancelled=$(jq -r '.cancelled' <<<"$resp" 2>/dev/null)
  wait_stream_end "$apid" 300 || echo "A stream did not finish within 300s" >&2
  wait_stream_end "$bpid" 600 || echo "B did not finish within 600s" >&2
  answer=$(tr -d '[:space:]' <"$b" 2>/dev/null)
  ps_dump >"$psfile"
  pstags=$(ps_tags "$psfile")
  if [[ "$cancelled" == true && "$answer" == "{}" ]] \
     && ps_has "$MODEL" "$psfile" && ! ps_has "$OTHER_MODEL" "$psfile"; then
    record chat-nonstream PASS "cancelled=$cancelled answer=$answer ps=[$pstags]"
  else
    record chat-nonstream FAIL "cancelled=$cancelled answer=$answer ps=[$pstags] (want cancelled/true, {}, ps=[$MODEL])"
  fi
}

if ! start_server; then
  record startup FAIL "$start_err"
  exit 1
fi

ps_dump >"$outdir/$label.ps.start.json"
echo "start ps: $(ps_tags "$outdir/$label.ps.start.json")" >&2
echo "queued so far: $(queued_count 'POST /api/generate')" >&2
case_model_swap
case_chat_nonstream

echo "--- summary ($results)"
cat "$results"
! grep -q $'\tFAIL\t' "$results"
