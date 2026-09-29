#!/usr/bin/env bash
# reset-before-accept.sh <flm> <port> <cycles> <outdir> <label>
#
# Red/green probe for #202. Each cycle freezes flm serve with SIGSTOP, opens a
# connection and resets it (SO_LINGER {1,0}) while it sits in the accept
# queue, resumes flm with SIGCONT, then asks GET /api/version with a timeout.
#
# On an affected build the HttpSession constructor throws ENOTCONN on the
# reset socket, the accept loop is never re-armed, and the first GET times
# out. On a fixed build every GET answers 200, including past the
# 10-connection cap, which shows each reset connection gave its slot back.
set -u
FLM=${1:?flm path}
port=${2:?port}
cycles=${3:?cycles}
out=${4:?outdir}
label=${5:-run}
LIB=${XRT_LIB_DIR:?set XRT_LIB_DIR to the xrt-combined lib dir}
pid=""
rc=0

# stop -- resume first, so a SIGSTOPped flm can act on TERM; bounded TERM wait,
# then KILL, then reap.
stop() {
  [ -z "$pid" ] && return
  kill -CONT "$pid" 2>/dev/null
  kill "$pid" 2>/dev/null
  local waited=0
  while [ "$waited" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; waited=$((waited + 1)); done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  pid=""
}
# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() { stop; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$out"
log="$out/server-$label.log"
client="$out/client-$label.log"
: >"$log"
: >"$client"
pgrep -x flm >/dev/null && { echo "flm already running" >&2; exit 1; }
LD_LIBRARY_PATH=$LIB "$FLM" serve llama3.2:1b --port "$port" >>"$log" 2>&1 &
pid=$!
for _ in $(seq 300); do
  kill -0 "$pid" 2>/dev/null || { echo "server died during startup" >&2; exit 1; }
  curl -s -o /dev/null "http://127.0.0.1:$port/api/version" && break
  sleep 1
done
curl -s -o /dev/null "http://127.0.0.1:$port/api/version" || { echo "server not ready" >&2; exit 1; }

ok=0
for i in $(seq 1 "$cycles"); do
  kill -STOP "$pid"
  python3 - "$port" <<'PY'
import socket, struct, sys
c = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
c.close()
PY
  sleep 0.2
  kill -CONT "$pid"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$port/api/version")
  echo "cycle $i: reset queued, GET /api/version -> $code" >>"$client"
  if [ "$code" != 200 ]; then
    rc=1
    break
  fi
  ok=$((ok + 1))
done
stop

io_errors=$(grep -c 'Error in WebServer I/O thread' "$log" || true)
unavailable=$(grep -c 'established - Remote endpoint unavailable' "$log" || true)
limit=$(grep -c 'Connection limit reached' "$log" || true)
{
  echo "cycles_requested=$cycles"
  echo "cycles_answered_200=$ok"
  echo "io_thread_errors=$io_errors"
  echo "remote_endpoint_unavailable=$unavailable"
  echo "connection_limit_reached=$limit"
} | tee "$out/summary-$label.txt"
exit "$rc"
