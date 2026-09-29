#!/usr/bin/env bash
# debug-slots.sh <flm> <port> <outdir>
#
# Counter evidence for #194, run against a scratch build that adds
#   header_print("DBG", "accept -> " + active_connections_)
#   header_print("DBG", "release -> " + active_connections_)
#   header_print("DBG", "chunk write failed")
# to connection-slot-release.patch. The scratch instrumentation is not in any
# committed patch; see README.md.
#
# Runs N normal (keep-alive-shaped, non-streaming) requests, then N streaming
# aborts mid-stream, and summarises the DBG lines: accepts == releases, the
# release counter ends at 0, and chunk-write failures outnumber releases
# (proving later chunks re-entered the error branch without a second release).
set -u
FLM=${1:?flm path}
port=${2:?port}
out=${3:?outdir}
N=12
LIB=${XRT_LIB_DIR:?set XRT_LIB_DIR to the xrt-combined lib dir}
pid=""

stop() {
  [ -z "$pid" ] && return
  kill "$pid" 2>/dev/null
  local waited=0
  while [ "$waited" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; waited=$((waited + 1)); done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  pid=""
}
cleanup() { stop; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$out"
log="$out/server-debug.log"
: >"$log"
pgrep -x flm >/dev/null && { echo "flm already running" >&2; exit 1; }
LD_LIBRARY_PATH=$LIB "$FLM" serve llama3.2:1b --port "$port" >>"$log" 2>&1 &
pid=$!
for _ in $(seq 300); do
  kill -0 "$pid" 2>/dev/null || { echo "server died during startup" >&2; exit 1; }
  curl -s -o /dev/null "http://127.0.0.1:$port/api/version" && break
  sleep 1
done
curl -s -o /dev/null "http://127.0.0.1:$port/api/version" || { echo "server not ready" >&2; exit 1; }

echo "-- $N normal keep-alive /api/version requests"
for _ in $(seq 1 "$N"); do
  curl -s -o /dev/null --max-time 60 "http://127.0.0.1:$port/api/version"
done
echo "-- 1 normal non-streaming /v1/chat/completions"
curl -s -o /dev/null --max-time 180 -X POST -H 'Content-Type: application/json' \
  -d '{"model":"llama3.2:1b","messages":[{"role":"user","content":"Say hi in one word."}],"stream":false}' \
  "http://127.0.0.1:$port/v1/chat/completions"

echo "-- $N streaming aborts (RST mid-stream)"
python3 - "$port" "$N" <<'PY'
import json, socket, struct, sys, time
port = int(sys.argv[1]); count = int(sys.argv[2])
for i in range(1, count + 1):
    s = socket.create_connection(("127.0.0.1", port), timeout=30)
    body = json.dumps({
        "model": "llama3.2:1b",
        "messages": [{"role": "user",
                      "content": "Write a very long, detailed essay about the history of the ocean, at least 2000 words."}],
        "stream": True,
    }).encode()
    s.sendall(b"POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: "
              + str(len(body)).encode() + b"\r\n\r\n" + body)
    try:
        s.recv(64)
    except Exception:
        pass
    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    s.close()
    time.sleep(1.5)
PY

stop
grep 'DBG' "$log" >"$out/debug-slots.log" || true
accepts=$(grep -c 'DBG.*accept ->' "$out/debug-slots.log" || true)
releases=$(grep -c 'DBG.*release ->' "$out/debug-slots.log" || true)
failures=$(grep -c 'DBG.*chunk write failed' "$out/debug-slots.log" || true)
final=$(grep 'DBG.*release ->' "$out/debug-slots.log" | tail -1 | sed 's/.*release -> //')
echo "accepts=$accepts releases=$releases chunk_write_failures=$failures final_counter=$final"
{
  echo "accepts=$accepts"
  echo "releases=$releases"
  echo "chunk_write_failures=$failures"
  echo "final_counter=$final"
} >"$out/debug-slots.summary"
[ "$accepts" = "$releases" ] && [ "$final" = "0" ] && [ "$failures" -gt "$releases" ]