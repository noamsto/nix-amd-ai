#!/usr/bin/env bash
# queued-cancel.sh <flm-binary> <outdir> <label>
#
# #222: a request queued behind another on the NPU must be cancellable by
# POST /api/cancel with its request_id, and must not decode once cancelled.
#
# Cases (llama3.2:1b, streaming /api/generate):
#   queued-cancel:     A runs; B queues with a caller id; cancel B while queued.
#                      Red:  cancel answers cancelled:false and B runs fully.
#                      Green: cancel answers cancelled:true, B ends with
#                             done_reason=cancel and 0 content lines, A completes.
#   queued-disconnect: A runs; B queues; B's client disconnects while queued.
#                      B must still be cancelled (#201 kept working).
#   queued-normal:     A runs; B queues; A finishes; B completes normally.
#   registry:          first cancel for B is a hit; a second is cancelled:false
#                      (B's slot is gone, not lingering).
#
# Env: XRT_LIB (optional; the nix-build flm resolves xrt via RPATH),
#      PORT=58731, MODEL=llama3.2:1b. Exits 0 iff no case FAILs.
set -u

FLM=${1:?usage: queued-cancel.sh <flm-binary> <outdir> <label>}
outdir=${2:?usage: queued-cancel.sh <flm-binary> <outdir> <label>}
label=${3:?usage: queued-cancel.sh <flm-binary> <outdir> <label>}
mkdir -p "$outdir" || exit 1
outdir=$(cd "$outdir" && pwd) || exit 1

PORT=${PORT:-58731}
MODEL=${MODEL:-llama3.2:1b}
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

# start_stream <request_id|""> <out.ndjson>
start_stream() {
  local rid=$1 out=$2 body
  body=$(jq -cn --arg m "$MODEL" --arg rid "$rid" '
    {model: $m, stream: true, max_tokens: 768,
     prompt: "Write a long, detailed essay about the history of the printing press."}
    + (if $rid == "" then {} else {request_id: $rid} end)')
  : >"$out"
  curl -sN -X POST "$base/api/generate" -H 'Content-Type: application/json' \
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

queued_count() { grep -c 'request queued.*POST /api/generate' "$log" 2>/dev/null || true; }

wait_queued_after() { # <prior_count> <timeout_s>: a NEW queued /api/generate line
  local target=$(( $1 + 1 )) waited=0
  while (( waited < $2 )); do
    [[ "$(queued_count)" -ge "$target" ]] && return 0
    sleep 1; (( waited++ ))
  done
  return 1
}
cancel() { curl -s -m 10 -X POST "$base/api/cancel" -H 'Content-Type: application/json' \
  -d "{\"request_id\":\"$1\"}" | tee -a "$cancels"; }
done_reason() { jq -r 'select(.done == true) | .done_reason // "none"' "$1" 2>/dev/null | tail -n1; }
content_lines() { jq -c 'select(.response != null and .response != "")' "$1" 2>/dev/null | wc -l; }

case_queued_cancel() {
  local a="$outdir/$label.qc.a.ndjson" b="$outdir/$label.qc.b.ndjson" bid="qc-$RANDOM$RANDOM"
  local resp cancelled reason blines areason qc0
  start_stream "" "$a"; local apid=$stream_pid
  if ! wait_first_content "$a"; then record queued-cancel FAIL "A no content within 60s"; return; fi
  qc0=$(queued_count)
  start_stream "$bid" "$b"; local bpid=$stream_pid
  if ! wait_queued_after "$qc0" 60; then record queued-cancel FAIL "B never appeared in the NPU queue"; return; fi
  # NB: jq's // treats false as a fallback, so read .cancelled directly.
  resp=$(cancel "$bid"); cancelled=$(jq -r '.cancelled' <<<"$resp" 2>/dev/null)
  wait_stream_end "$bpid" 120 || true
  wait_stream_end "$apid" 300 || echo "A stream did not finish within 300s" >&2
  reason=$(done_reason "$b"); reason=${reason:-none}
  blines=$(content_lines "$b")
  areason=$(done_reason "$a"); areason=${areason:-none}
  if [[ "$cancelled" == true && "$reason" == cancel && "$blines" -eq 0 && "$areason" != cancel ]]; then
    record queued-cancel PASS "cancelled=$cancelled B_done_reason=$reason B_content_lines=$blines A_done_reason=$areason"
  else
    record queued-cancel FAIL "cancelled=$cancelled B_done_reason=$reason B_content_lines=$blines A_done_reason=$areason"
  fi
  # registry: the slot must be gone after B answered
  local second
  second=$(jq -r '.cancelled' <<<"$(cancel "$bid")" 2>/dev/null)
  if [[ "$cancelled" == true && "$second" == false ]]; then
    record registry PASS "first cancel cancelled:true, second cancelled:false"
  else
    record registry FAIL "first=$cancelled second=$second"
  fi
}

case_queued_disconnect() {
  local a="$outdir/$label.qd.a.ndjson" b="$outdir/$label.qd.b.ndjson" bid="qd-$RANDOM$RANDOM"
  local before after qc0
  start_stream "" "$a"; local apid=$stream_pid
  if ! wait_first_content "$a"; then record queued-disconnect FAIL "A no content within 60s"; return; fi
  qc0=$(queued_count)
  start_stream "$bid" "$b"; local bpid=$stream_pid
  if ! wait_queued_after "$qc0" 60; then record queued-disconnect FAIL "B never appeared in the NPU queue"; return; fi
  # Either message means the monitor noticed the gone client.
  before=$(grep -c 'cancelling active request' "$log" 2>/dev/null || true)
  kill "$bpid" 2>/dev/null; wait "$bpid" 2>/dev/null
  wait_stream_end "$apid" 300 || echo "A stream did not finish within 300s" >&2
  sleep 3
  after=$(grep -c 'cancelling active request' "$log" 2>/dev/null || true)
  if [[ "$after" -gt "$before" ]]; then
    record queued-disconnect PASS "server saw the disconnect (${before}->${after}) and A finished"
  else
    record queued-disconnect FAIL "no cancelling-active-request line after B's client left (${before}->${after})"
  fi
}

case_queued_normal() {
  local a="$outdir/$label.qn.a.ndjson" b="$outdir/$label.qn.b.ndjson" bid="qn-$RANDOM$RANDOM"
  local reason lines qc0
  start_stream "" "$a"; local apid=$stream_pid
  if ! wait_first_content "$a"; then record queued-normal FAIL "A no content within 60s"; return; fi
  qc0=$(queued_count)
  start_stream "$bid" "$b"; local bpid=$stream_pid
  if ! wait_queued_after "$qc0" 60; then record queued-normal FAIL "B never appeared in the NPU queue"; return; fi
  wait_stream_end "$apid" 300 || echo "A stream did not finish within 300s" >&2
  wait_stream_end "$bpid" 300 || echo "B stream did not finish within 300s" >&2
  reason=$(done_reason "$b"); reason=${reason:-none}
  lines=$(content_lines "$b")
  if [[ "$reason" != cancel && "$reason" != none && "$lines" -gt 0 ]]; then
    record queued-normal PASS "B_done_reason=$reason B_content_lines=$lines"
  else
    record queued-normal FAIL "B_done_reason=$reason B_content_lines=$lines"
  fi
}

if ! start_server; then
  record startup FAIL "$start_err"
  exit 1
fi

echo "queued so far: $(queued_count)" >&2
case_queued_cancel
case_queued_disconnect
case_queued_normal

echo "--- summary ($results)"
cat "$results"
! grep -q $'\tFAIL\t' "$results"
