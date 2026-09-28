#!/usr/bin/env bash
# race.sh <flm> <outdir> <label>   (label: red|green)
#
# Red/green evidence for #184: GET /api/ps reads RestHandler state (the
# serving chat tag, the engine pointer) without the NPU lock, while
# ensure_model_loaded tears down and reassigns that same state during a
# model swap -- a data race under ThreadSanitizer. <flm> must be a tsan.nix
# build (see ./tsan.nix): --arg fixed false for label=red (races), --arg
# fixed true for label=green (ps-serving-snapshot.patch applied).
#
# Oracle:
#   red:   ps-pair >= 1 (the race must reproduce) -- the ONLY gate.
#   green: ps-pair == 0 and model-state == 0, and every poll and every
#          chat/completions request answered 200.
set -u

FLM=${1:?usage: race.sh <flm> <outdir> <label>}
outdir=${2:?usage: race.sh <flm> <outdir> <label>}
label=${3:?usage: race.sh <flm> <outdir> <label>}
mkdir -p "$outdir"

LIB=/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib
PORT=58604
POLLERS=${POLLERS:-4}
SWAPS=${SWAPS:-6}
COMPLETIONS=3
CLASSIFY="$(dirname "$0")/tsan-classify.py"

pid=""
poller_pids=()
stop_flag="$outdir/.stop-pollers-$label"
rc=0

# stop -- bounded: TERM, wait up to 30s, then KILL, then reap.
stop() {
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null
  local waited=0
  while [ "$waited" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  pid=""
}

# Pollers finish their in-flight request and exit on the stop flag, so no
# poll is cut off by the server shutting down (curl would record 000).
stop_pollers() {
  local p
  touch "$stop_flag"
  for p in "${poller_pids[@]:-}"; do
    [ -n "$p" ] && wait "$p" 2>/dev/null
  done
  poller_pids=()
  rm -f "$stop_flag"
}

# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() {
  stop_pollers
  stop
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# pre-flight: never touch a flm someone else is running.
wait_for_no_flm() {
  local waited=0
  while pgrep -x flm >/dev/null; do
    if [ "$waited" -ge 600 ]; then
      echo "ABORT: flm already running, still busy after ${waited}s" >&2
      exit 1
    fi
    echo "flm already running; retrying in 30s (${waited}s so far)" >&2
    sleep 30
    waited=$((waited + 30))
  done
}

up() {
  local cmd=("$FLM" serve llama3.2:1b --port "$PORT")
  [ "${SETARCH:-0}" = 1 ] && cmd=(setarch -R "${cmd[@]}")
  LD_LIBRARY_PATH=$LIB \
    TSAN_OPTIONS="halt_on_error=0 report_signal_unsafe=0 history_size=7 log_path=$outdir/tsan-$label" \
    "${cmd[@]}" >"$outdir/server-race-$label.log" 2>&1 &
  pid=$!
  local waited=0
  while [ "$waited" -lt 600 ]; do
    kill -0 "$pid" 2>/dev/null || { echo "server died during startup" >&2; return 1; }
    curl -s -o /dev/null "http://127.0.0.1:$PORT/api/version" && return 0
    sleep 1
    waited=$((waited + 1))
  done
  echo "server not ready within 600s" >&2
  return 1
}

start_pollers() {
  local i
  rm -f "$stop_flag"
  for ((i = 0; i < POLLERS; i++)); do
    (
      while [ ! -e "$stop_flag" ]; do
        curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 "http://127.0.0.1:$PORT/api/ps"
      done
    ) >>"$outdir/ps-codes-$label.$i.txt" &
    poller_pids+=("$!")
  done
}

post() { # <path> <body> -> "http_code time_total"
  curl -s -o /dev/null --max-time 900 -w '%{http_code} %{time_total}' \
    -X POST "http://127.0.0.1:$PORT$1" -H 'Content-Type: application/json' -d "$2"
}

wait_for_no_flm

if ! up; then
  stop
  rc=1
else
  start_pollers

  chat_file="$outdir/chat-$label.txt"
  : >"$chat_file"
  for ((i = 0; i < SWAPS; i++)); do
    model="llama3.2:1b"
    [ $((i % 2)) -eq 0 ] && model="gemma4-it:e4b"
    body=$(printf '{"model":"%s","messages":[{"role":"user","content":"Say hi."}],"stream":false,"options":{"num_predict":1,"top_k":1}}' "$model")
    echo "$label $i $model $(post /api/chat "$body")" >>"$chat_file"
  done

  completions_file="$outdir/completions-$label.txt"
  : >"$completions_file"
  for ((i = 0; i < COMPLETIONS; i++)); do
    model="llama3.2:1b"
    [ $((i % 2)) -eq 0 ] && model="gemma4-it:e4b"
    body=$(printf '{"model":"%s","prompt":"Say hi.","max_tokens":1}' "$model")
    echo "$label $i $model $(post /v1/completions "$body")" >>"$completions_file"
  done

  stop_pollers
  stop
  sleep 2
fi

if pgrep -x flm >/dev/null; then
  echo "stray flm!" >&2
  rc=1
fi

shopt -s nullglob
tsan_logs=("$outdir/tsan-$label".*)
shopt -u nullglob
poll_files=("$outdir/ps-codes-$label".*.txt)

all_poll_codes=$(cat "${poll_files[@]}" 2>/dev/null)
total_polls=$(printf '%s\n' "$all_poll_codes" | grep -c . || true)
poll_hist=$(printf '%s\n' "$all_poll_codes" | sort | uniq -c | tr '\n' ';')

chat_codes=$(awk '{print $4}' "${chat_file:-/dev/null}" "${completions_file:-/dev/null}" 2>/dev/null)
chat_hist=$(printf '%s\n' "$chat_codes" | sort | uniq -c | tr '\n' ';')

all_polls_200=true
[ -n "$all_poll_codes" ] || all_polls_200=false
printf '%s\n' "$all_poll_codes" | grep -qv '^200$' && all_polls_200=false

all_chat_200=true
[ -n "$chat_codes" ] || all_chat_200=false
printf '%s\n' "$chat_codes" | grep -qv '^200$' && all_chat_200=false

result_file="$outdir/race-$label.txt"
: >"$result_file"
log() { echo "$1" | tee -a "$result_file"; }

log "INFO total_polls=$total_polls"
log "INFO poll_code_histogram: $poll_hist"
log "INFO chat_completions_code_histogram: $chat_hist"

ps_pair=0
model_state=0
if [ "${#tsan_logs[@]}" -eq 0 ]; then
  log "FAIL tsan-logs-present: no TSan log files found for label=$label (TSan aborted at startup?)"
  rc=1
else
  summary="$outdir/tsan-$label.summary.txt"
  classify_out=$(python3 "$CLASSIFY" "${tsan_logs[@]}")
  printf '%s\n' "$classify_out" >"$summary"
  buckets_line=$(printf '%s\n' "$classify_out" | grep '^BUCKETS ')
  ps_pair=$(printf '%s\n' "$buckets_line" | grep -oE 'ps-pair=[0-9]+' | cut -d= -f2)
  model_state=$(printf '%s\n' "$buckets_line" | grep -oE 'model-state=[0-9]+' | cut -d= -f2)
  log "INFO $buckets_line"

  case "$label" in
    red)
      if [ "${ps_pair:-0}" -ge 1 ]; then
        log "PASS ps-pair-reproduced (ps-pair=$ps_pair)"
      else
        log "FAIL ps-pair-reproduced (ps-pair=$ps_pair)"
        rc=1
      fi
      ;;
    green)
      if [ "${ps_pair:-1}" -eq 0 ]; then log "PASS no-ps-pair"; else log "FAIL no-ps-pair (ps-pair=$ps_pair)"; rc=1; fi
      if [ "${model_state:-1}" -eq 0 ]; then log "PASS no-model-state"; else log "FAIL no-model-state (model-state=$model_state)"; rc=1; fi
      if $all_polls_200; then log "PASS all-poll-200"; else log "FAIL all-poll-200"; rc=1; fi
      if $all_chat_200; then log "PASS all-chat-completions-200"; else log "FAIL all-chat-completions-200"; rc=1; fi
      ;;
    *)
      log "FAIL unknown label '$label' (want red|green)"
      rc=1
      ;;
  esac
fi

exit "$rc"
