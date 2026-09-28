#!/usr/bin/env bash
# disconnect.sh <flm> <port> <count> <outdir> <label>
#
# Red/green probe for #194: abort <count> streaming /v1/chat/completions
# requests mid-stream, then check whether a new connection is still accepted.
#
# On a leaking build the 10-connection cap fills after 10 aborts, the server
# logs "Connection limit reached (10)", and the final connection is refused.
# On a fixed build every connection is accepted.
set -u
FLM=${1:?flm path}
port=${2:?port}
count=${3:?count}
out=${4:?outdir}
label=${5:-run}
LIB=${XRT_LIB_DIR:-/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib}
pid=""
rc=0

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
: >"$out/server-$label.log"
pgrep -x flm >/dev/null && { echo "flm already running" >&2; exit 1; }
LD_LIBRARY_PATH=$LIB "$FLM" serve llama3.2:1b --port "$port" >>"$out/server-$label.log" 2>&1 &
pid=$!
for _ in $(seq 300); do
  kill -0 "$pid" 2>/dev/null || { echo "server died during startup" >&2; exit 1; }
  curl -s -o /dev/null "http://127.0.0.1:$port/api/version" && break
  sleep 1
done
curl -s -o /dev/null "http://127.0.0.1:$port/api/version" || { echo "server not ready" >&2; exit 1; }

final=$(python3 - "$port" "$count" "$out/client-$label.log" <<'PY'
import json, socket, struct, sys, time

port = int(sys.argv[1])
count = int(sys.argv[2])
log = open(sys.argv[3], "w")

def abort_once(i):
    s = socket.create_connection(("127.0.0.1", port), timeout=30)
    body = json.dumps({
        "model": "llama3.2:1b",
        "messages": [{"role": "user",
                      "content": "Write a very long, detailed essay about the history of the ocean, at least 2000 words."}],
        "stream": True,
    }).encode()
    req = (
        b"POST /v1/chat/completions HTTP/1.1\r\n"
        b"Host: 127.0.0.1\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: " + str(len(body)).encode() + b"\r\n"
        b"\r\n" + body
    )
    s.sendall(req)
    try:
        got = s.recv(64)
    except Exception as e:
        log.write(f"abort {i}: recv failed: {e}\n")
        got = b""
    # Force an RST so the server's next chunk write fails hard.
    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    s.close()
    log.write(f"abort {i}: read {len(got)} bytes, RST\n")
    log.flush()

for i in range(1, count + 1):
    try:
        abort_once(i)
    except Exception as e:
        log.write(f"abort {i}: connect/send failed: {e}\n")
    time.sleep(1.5)

# Final connection: must still be accepted on a fixed build.
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=15)
except Exception as e:
    log.write(f"final: connect failed: {e}\n")
    print("REFUSED")
    sys.exit(0)
try:
    s.sendall(b"GET /api/version HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
    data = s.recv(64)
    if data:
        log.write(f"final: {data[:40]!r}\n")
        print("ACCEPTED")
    else:
        log.write("final: empty reply\n")
        print("REFUSED")
except Exception as e:
    log.write(f"final: {e}\n")
    print("REFUSED")
finally:
    s.close()
PY
)
echo "disconnect probe ($label): count=$count final_connection=$final"
grep -c "Connection limit reached" "$out/server-$label.log" >"$out/server-$label.limit-count" || true
echo "server 'Connection limit reached' lines: $(cat "$out/server-$label.limit-count")"
[ "$final" = "ACCEPTED" ] || rc=1
stop
exit $rc