#!/usr/bin/env bash
# probe.sh <flm> <outdir> <label> <none|FAULT_AFTER> <expect:truncated|error|normal>
#
# Raw-bytes red/green for #199: force a mid-stream decode fault with the
# test-only FLM_INJECT_DECODE_FAULT_AFTER injection, capture the raw client
# bytes for Ollama /api/chat and OpenAI /v1/chat/completions, and check the
# stream's framing and the connection-slot release (#194).
#
#   truncated -> red (fault, no error event, no terminating chunk)
#   error     -> green (fault, error event in-stream, terminating 0\r\n\r\n)
#   normal    -> no injection; the stream still ends cleanly
set -u
FLM=${1:?flm path}
out=${2:?outdir}
label=${3:?label}
fault=${4:?none|FAULT_AFTER}
expect=${5:?truncated|error|normal}
LIB=${XRT_LIB_DIR:?set XRT_LIB_DIR to the xrt-combined lib dir}
here="$(cd "$(dirname "$0")" && pwd)"
port=$(( 58740 + RANDOM % 200 ))
pid=""
rc=0
mkdir -p "$out"

stop() {
  [ -z "$pid" ] && return
  kill "$pid" 2>/dev/null
  local waited=0
  while [ "$waited" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; waited=$((waited + 1)); done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  pid=""
}
trap stop EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pgrep -x flm >/dev/null && { echo "flm already running" >&2; exit 1; }
srvlog="$out/server-$label.log"
: >"$srvlog"
if [ "$fault" = "none" ]; then
  LD_LIBRARY_PATH="$LIB" "$FLM" serve llama3.2:1b --port "$port" >>"$srvlog" 2>&1 &
else
  FLM_INJECT_DECODE_FAULT_AFTER="$fault" LD_LIBRARY_PATH="$LIB" \
    "$FLM" serve llama3.2:1b --port "$port" >>"$srvlog" 2>&1 &
fi
pid=$!
for _ in $(seq 300); do
  kill -0 "$pid" 2>/dev/null || { echo "server died during startup" >&2; exit 1; }
  curl -s -o /dev/null "http://127.0.0.1:$port/api/version" && break
  sleep 1
done
curl -s -o /dev/null "http://127.0.0.1:$port/api/version" || { echo "server not ready" >&2; exit 1; }

echo "== probe $label (fault=$fault expect=$expect) ==" | tee "$out/summary-$label.txt"
for ep in ollama_chat openai_chat; do
  line=$(python3 "$here/capture.py" "$port" "$ep" "$out/$label.$ep.bin" 15)
  echo "$ep $line" | tee -a "$out/summary-$label.txt"
  ok=$(python3 -c '
import json,sys
f=json.loads(sys.argv[1]); e=sys.argv[2]; x=sys.argv[3]
if x=="truncated":
    good = f["http200"] and not f["error_event"] and not f["terminator"] and not f["sse_done"]
elif x=="error":
    good = f["http200"] and f["error_event"] and f["terminator"] and not f["leaked_injection_text"]
elif x=="normal":
    good = f["http200"] and not f["error_event"] and f["terminator"]
else:
    good = False
print("PASS" if good else "FAIL")
' "$line" "$ep" "$expect")
  echo "  -> $ok" | tee -a "$out/summary-$label.txt"
  [ "$ok" = "PASS" ] || rc=1
done

if [ "$fault" != "none" ]; then
  # Force the fault N times, then a fresh connection must still be accepted: the
  # slot is released on red (#194) and on green (send_chunk_data is_final).
  for i in $(seq 1 12); do
    python3 "$here/capture.py" "$port" ollama_chat "$out/$label.slot-$i.bin" 2 >/dev/null
  done
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "http://127.0.0.1:$port/api/version")
  limit=$(grep -c "Connection limit reached" "$srvlog" || true)
  echo "slot-release: final /api/version=$code connection-limit-lines=$limit" | tee -a "$out/summary-$label.txt"
  if [ "$code" = "200" ] && [ "$limit" = "0" ]; then
    echo "  -> PASS" | tee -a "$out/summary-$label.txt"
  else
    echo "  -> FAIL" | tee -a "$out/summary-$label.txt"
    rc=1
  fi
fi

stop
echo "probe $label: $([ "$rc" = 0 ] && echo PASSED || echo FAILED)"
exit $rc
