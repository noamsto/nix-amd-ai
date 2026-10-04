#!/usr/bin/env bash
# cancel-guess.sh <flm-binary> <outdir> <label>
#
# Can another client cancel a request by guessing its default request id?
#   guess:  a streaming /api/generate with no request_id runs while we POST
#           /api/cancel for req_0..req_$GUESS_MAX. Green: every guess answers
#           cancelled:false and the victim completes (a done line, not "cancel").
#   own-id: cancelling a request by the id it supplied still works.
# Env: XRT_LIB (required), PORT=58721, MODEL=llama3.2:1b, GUESS_MAX=255.
# Exits 0 if every case passes, 1 otherwise.
set -u

FLM=${1:?usage: cancel-guess.sh <flm-binary> <outdir> <label>}
outdir=${2:?usage: cancel-guess.sh <flm-binary> <outdir> <label>}
label=${3:?usage: cancel-guess.sh <flm-binary> <outdir> <label>}
mkdir -p "$outdir" || exit 1
outdir=$(cd "$outdir" && pwd) || exit 1

libpath=${XRT_LIB:?set XRT_LIB to the xrt-combined lib dir}
[[ -d "$libpath" ]] || { echo "libpath not found: $libpath" >&2; exit 1; }
PORT=${PORT:-58721}
MODEL=${MODEL:-llama3.2:1b}
GUESS_MAX=${GUESS_MAX:-255}
base=http://127.0.0.1:$PORT
results="$outdir/$label.results"
: >"$results"

server_pid=""
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
  while (( waited < 10 )) && kill -0 "$server_pid" 2>/dev/null; do
    sleep 1
    (( waited++ ))
  done
  kill -0 "$server_pid" 2>/dev/null && kill -KILL "$server_pid" 2>/dev/null
  wait "$server_pid" 2>/dev/null
  server_pid=""
}

stamp() {
  python3 -u -c '
import sys, time
for line in sys.stdin:
    sys.stdout.write(f"{time.time():.3f}\t{line}")
    sys.stdout.flush()
'
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
  LD_LIBRARY_PATH="$libpath" stdbuf -oL -eL "$FLM" serve "$MODEL" --port "$PORT" \
    > >(stamp >"$outdir/server-$label.log") 2>&1 &
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

# start_stream <request_id|""> <out.ndjson>: background streaming generate
start_stream() {
  local rid=$1 out=$2 body
  body=$(jq -cn --arg m "$MODEL" --arg rid "$rid" '
    {model: $m, stream: true, options: {num_predict: 512},
     prompt: "Write a long, detailed essay about the history of the printing press."}
    + (if $rid == "" then {} else {request_id: $rid} end)')
  : >"$out"
  curl -sN -X POST "$base/api/generate" -H 'Content-Type: application/json' \
    -d "$body" >"$out" 2>/dev/null &
  stream_pid=$!
}

wait_first_content() { # <ndjson> -> 0 once a non-empty response line arrives
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

done_reason() { jq -r 'select(.done == true) | .done_reason // "none"' "$1" 2>/dev/null | tail -n1; }
content_lines() { jq -c 'select(.response != null and .response != "")' "$1" 2>/dev/null | wc -l; }

case_guess() {
  local victim="$outdir/$label.guess.victim.ndjson"
  local cancels="$outdir/$label.guess.cancels.jsonl"
  : >"$cancels"
  start_stream "" "$victim"
  local vpid=$stream_pid
  if ! wait_first_content "$victim"; then
    record guess/victim FAIL "no content within 60s"
    return
  fi
  local n resp hits=0 errors=0
  for n in $(seq 0 "$GUESS_MAX"); do
    resp=$(curl -s -m 10 -X POST "$base/api/cancel" -H 'Content-Type: application/json' \
      -d "{\"request_id\":\"req_$n\"}")
    jq -cn --argjson n "$n" --arg r "$resp" '{n: $n, resp: ($r | fromjson? // $r)}' >>"$cancels"
    if ! jq -e 'has("cancelled")' <<<"$resp" >/dev/null 2>&1; then
      errors=$((errors + 1))
    elif [[ $(jq -r '.cancelled' <<<"$resp") == true ]]; then
      echo "hit: req_$n"
      hits=$((hits + 1))
    fi
  done
  wait_stream_end "$vpid" 180 || echo "victim stream did not finish within 180s" >&2
  local reason lines
  reason=$(done_reason "$victim"); reason=${reason:-none}
  lines=$(content_lines "$victim")
  record guess/hits "$([[ $hits -eq 0 && $errors -eq 0 ]] && echo PASS || echo FAIL)" "$hits of $((GUESS_MAX + 1)) guesses returned cancelled:true, $errors errors"
  record guess/victim_done_reason "$([[ $reason != cancel && $reason != none ]] && echo PASS || echo FAIL)" "done_reason=$reason content_lines=$lines"
}

case_own_id() {
  local out="$outdir/$label.ownid.ndjson" rid="own-$RANDOM$RANDOM"
  start_stream "$rid" "$out"
  local vpid=$stream_pid
  if ! wait_first_content "$out"; then
    record own-id FAIL "no content within 60s"
    return
  fi
  local resp cancelled
  resp=$(curl -s -m 10 -X POST "$base/api/cancel" -H 'Content-Type: application/json' \
    -d "{\"request_id\":\"$rid\"}")
  cancelled=$(jq -r '.cancelled' <<<"$resp" 2>/dev/null)
  wait_stream_end "$vpid" 30 || echo "own-id stream did not finish within 30s" >&2
  local reason
  reason=$(done_reason "$out"); reason=${reason:-none}
  if [[ "$cancelled" == true && "$reason" == cancel ]]; then
    record own-id PASS "cancelled=$cancelled done_reason=$reason"
  else
    record own-id FAIL "cancelled=$cancelled done_reason=$reason"
  fi
}

if ! start_server; then
  record startup FAIL "$start_err"
  exit 1
fi

case_guess
case_own_id

echo "--- summary ($results)"
cat "$results"
! grep -q $'\tFAIL\t' "$results"
