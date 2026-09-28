#!/usr/bin/env bash
# disconnect.sh <flm> <outdir> <label>
#
# Reproduces the crash sequence measured for #192: requires_npu_access() in
# src/server/server.cpp omits POST /v1/completions and POST /api/embeddings,
# so a /v1/completions request never takes the NPU lock or joins the NPU
# queue -- it keeps decoding on the NPU after its client disconnects. This
# fires a streaming /v1/completions request, closes it abruptly after 5 SSE
# chunks, then immediately fires a non-streaming /api/chat (which finds the
# lock free and races the still-decoding /v1/completions on the NPU) and a
# second streaming /v1/completions. On the base build that second request has
# crashed flm serve with a heap-corruption abort; a fixed build should serve
# all three untouched. Tolerates the server dying partway through -- it
# always exits 0 unless a stray flm process is left behind; the caller reads
# the PASS/FAIL lines in the result file to tell red from green.
set -u

FLM=${1:?usage: disconnect.sh <flm> <outdir> <label>}
outdir=${2:?usage: disconnect.sh <flm> <outdir> <label>}
label=${3:?usage: disconnect.sh <flm> <outdir> <label>}
mkdir -p "$outdir"

LIB=/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib
PORT=58607
server_log="$outdir/server-disconnect-$label.log"
step1_file="$outdir/disconnect-$label.step1.txt"
step2_file="$outdir/disconnect-$label.step2.txt"
step3_file="$outdir/disconnect-$label.step3.txt"
result_file="$outdir/disconnect-$label.txt"
# Reset now, not just on the happy path: a failed up() (or an ABORT in
# wait_for_no_flm, below) must not leave a previous run's output behind for
# the caller to misread.
: >"$step1_file"
: >"$step2_file"
: >"$step3_file"
: >"$result_file"

pid=""
tmpdir=""
rc=0

# stop -- bounded: TERM, wait up to 30s, then KILL, then reap. $pid is flm's
# pid (see up(), below); the stamper it pipes into exits on its own once
# flm's stdout/stderr fd closes, so it never needs stopping here.
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
# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() {
  stop
  [ -n "$tmpdir" ] && rm -rf "$tmpdir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

# stamp -- prefix each line with wall-clock seconds, flushed per line.
stamp() {
  python3 -u -c '
import sys, time
for line in sys.stdin:
    sys.stdout.write(f"{time.time():.3f}\t{line}")
    sys.stdout.flush()
'
}

up() {
  LD_LIBRARY_PATH=$LIB stdbuf -oL -eL "$FLM" serve llama3.2:1b --port "$PORT" \
    > >(stamp >"$server_log") 2>&1 &
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

wait_for_no_flm
tmpdir=$(mktemp -d) || exit 1

log() { echo "$1" | tee -a "$result_file"; }

disconnect_json=""
chat_code=""
chat_time=""
completions2_code=""
completions2_done=false
server_alive=false

if ! up; then
  log "FAIL server-up: never became ready"
else
  # Step 1 (disconnect): stream /v1/completions, read exactly 5 SSE data
  # chunks, then close the socket abruptly -- shutdown() sends the FIN
  # immediately, unlike a plain close() that leaves the fd open while a
  # makefile still references it.
  disconnect_json=$(python3 - "$PORT" <<'PY'
import http.client, json, socket, sys, time
port = int(sys.argv[1])
body = {
    "model": "llama3.2:1b",
    "prompt": "Count from 1 to 1000, separated by commas.",
    "max_tokens": 512,
    "stream": True,
    "temperature": 0,
}
status, chunks, elapsed, err = None, 0, None, None
t0 = time.time()
try:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=600)
    conn.request("POST", "/v1/completions", json.dumps(body), {"Content-Type": "application/json"})
    resp = conn.getresponse()
    status = resp.status
    while chunks < 5:
        raw = resp.fp.readline()
        if not raw:
            break
        line = raw.decode("utf-8", "replace").strip()
        if not line or all(c in "0123456789abcdefABCDEF" for c in line):
            continue  # blank line or chunked-encoding size line
        if line.startswith("data: "):
            if line == "data: [DONE]":
                continue
            chunks += 1
    elapsed = time.time() - t0
    conn.sock.shutdown(socket.SHUT_RDWR)
    conn.close()
except Exception as e:
    elapsed = time.time() - t0
    err = str(e)
print(json.dumps({"status": status, "chunks": chunks,
                   "elapsed_s": round(elapsed, 3) if elapsed is not None else None,
                   "error": err}))
PY
)
  [ -n "$disconnect_json" ] || disconnect_json='{"status":null,"chunks":0,"elapsed_s":null,"error":"probe produced no output"}'
  echo "INFO $disconnect_json" >"$step1_file"

  # Step 2 (chat): immediately after, a small non-streaming /api/chat. On the
  # base build it finds the NPU lock free (the still-decoding /v1/completions
  # never took it) and races it.
  chat_body='{"model":"llama3.2:1b","messages":[{"role":"user","content":"Say hi."}],"stream":false,"options":{"num_predict":4,"top_k":1}}'
  chat_out="$tmpdir/chat.out"
  chat_meta=$(curl -s --max-time 600 -o "$chat_out" -w '%{http_code} %{time_total}' -X POST "http://127.0.0.1:$PORT/api/chat" \
    -H 'Content-Type: application/json' -d "$chat_body")
  chat_code=${chat_meta%% *}
  chat_time=${chat_meta#* }
  {
    echo "INFO code=$chat_code time_total=$chat_time"
    echo "BODY (first 500 bytes):"
    head -c 500 "$chat_out" 2>/dev/null
    echo
  } >"$step2_file"

  # Step 3 (completions-again): a second streaming /v1/completions, read to
  # the end.
  completions2_body='{"model":"llama3.2:1b","prompt":"Say hi.","max_tokens":8,"stream":true,"temperature":0}'
  completions2_out="$tmpdir/completions2.out"
  completions2_code=$(curl -s --max-time 600 -o "$completions2_out" -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/v1/completions" \
    -H 'Content-Type: application/json' -d "$completions2_body")
  # curl writes no file when the server is already gone.
  completions2_bytes=0
  [ -f "$completions2_out" ] && completions2_bytes=$(wc -c <"$completions2_out")
  grep -qF 'data: [DONE]' "$completions2_out" 2>/dev/null && completions2_done=true
  {
    echo "INFO code=$completions2_code done=$completions2_done bytes=$completions2_bytes"
  } >"$step3_file"

  sleep 2
  kill -0 "$pid" 2>/dev/null && server_alive=true

  stop
fi

log "INFO disconnect=$disconnect_json chat_code=$chat_code chat_time_total=$chat_time completions_again_code=$completions2_code completions_again_done=$completions2_done server_alive=$server_alive"

if [ "$chat_code" = 200 ]; then
  log "PASS chat-200"
else
  log "FAIL chat-200"
fi

if [ "$completions2_code" = 200 ] && [ "$completions2_done" = true ]; then
  log "PASS completions-again-done"
else
  log "FAIL completions-again-done"
fi

if $server_alive; then
  log "PASS server-alive"
else
  log "FAIL server-alive"
fi

if grep -qE 'double free|malloc_consolidate|corrupted|free\(\):' "$server_log" 2>/dev/null; then
  log "FAIL no-heap-corruption"
else
  log "PASS no-heap-corruption"
fi

if grep -qF 'runlist is submitted' "$server_log" 2>/dev/null; then
  log "FAIL no-runlist-error"
else
  log "PASS no-runlist-error"
fi

npu_locked_count=$(grep -cF 'NPU Locked!' "$server_log" 2>/dev/null)
queued_count=$(grep -cF 'request queued' "$server_log" 2>/dev/null)
log "INFO npu-locked-count=${npu_locked_count:-0} request-queued-count=${queued_count:-0}"

error_lines=$(grep -n 'ERROR' "$server_log" 2>/dev/null | head -5)
if [ -n "$error_lines" ]; then
  while IFS= read -r l; do
    log "INFO error: $l"
  done <<<"$error_lines"
else
  log "INFO error: none"
fi

if pgrep -x flm >/dev/null; then
  echo "stray flm!" >&2
  rc=1
fi

exit "$rc"
