#!/usr/bin/env bash
# keepalive-nonstream.sh <flm> <port> <outdir>
#
# Acceptance #2's "keep-alive and non-streaming unchanged" leg for #194.
# Against the patched (green) build: N keep-alive-shaped /api/version requests,
# then N non-streaming /v1/chat/completions requests, then N streaming aborts;
# every normal request must be HTTP 200 and the server must still accept a new
# connection afterwards.
set -u
FLM=${1:?flm path}
port=${2:?port}
out=${3:?outdir}
N=12
LIB=${XRT_LIB_DIR:-/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib}
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
log="$out/keepalive-nonstream.log"
: >"$log"
pgrep -x flm >/dev/null && { echo "flm already running" >&2; exit 1; }
LD_LIBRARY_PATH=$LIB "$FLM" serve llama3.2:1b --port "$port" >"$out/server-keepalive.log" 2>&1 &
pid=$!
for _ in $(seq 300); do
  kill -0 "$pid" 2>/dev/null || { echo "server died during startup" >&2; exit 1; }
  curl -s -o /dev/null "http://127.0.0.1:$port/api/version" && break
  sleep 1
done
curl -s -o /dev/null "http://127.0.0.1:$port/api/version" || { echo "server not ready" >&2; exit 1; }

rc=0
codes=""
for _ in $(seq 1 "$N"); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 "http://127.0.0.1:$port/api/version")
  codes="$codes $code"
  [ "$code" = "200" ] || rc=1
done
echo "keep-alive /api/version codes:$codes" >>"$log"

for i in $(seq 1 "$N"); do
  code=$(curl -s -o "$out/nonstream-$i.body" -w '%{http_code}' --max-time 180 -X POST \
    -H 'Content-Type: application/json' \
    -d '{"model":"llama3.2:1b","messages":[{"role":"user","content":"Say hi in one word."}],"stream":false}' \
    "http://127.0.0.1:$port/v1/chat/completions")
  echo "non-streaming /v1/chat/completions #$i: $code" >>"$log"
  [ "$code" = "200" ] || rc=1
done

python3 - "$port" "$N" <<'PY' >>"$log"
import json, socket, struct, sys, time
port = int(sys.argv[1]); count = int(sys.argv[2])
print(f"aborting {count} streaming requests mid-stream")
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

final=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 "http://127.0.0.1:$port/api/version")
echo "final /api/version after $N aborts: $final" >>"$log"
[ "$final" = "200" ] || rc=1
stop
exit $rc