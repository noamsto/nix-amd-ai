#!/usr/bin/env bash
# halfclose.sh <flm-binary> <outdir> <label>
#
# Characterisation, not pass/fail: does a TCP half-close (shutdown(SHUT_WR)
# right after sending the request, socket left open for reading) change how
# a streaming request ends, versus a normal full-duplex socket (control)?
# Runs against llama3.2:1b on /api/chat and /v1/chat/completions, N=5 each
# way, and records the terminal done/finish_reason and chunk count per run.
# Exits 0 unless the server itself fails to start.
set -u

FLM=${1:?usage: halfclose.sh <flm-binary> <outdir> <label>}
outdir=${2:?usage: halfclose.sh <flm-binary> <outdir> <label>}
label=${3:?usage: halfclose.sh <flm-binary> <outdir> <label>}
mkdir -p "$outdir" || exit 1
outdir=$(cd "$outdir" && pwd) || exit 1

libpath=/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib
[[ -d "$libpath" ]] || { echo "libpath not found: $libpath" >&2; exit 1; }
health_url=http://127.0.0.1:13305/api/v1/health
model=llama3.2:1b
port=58621
N=5

server_pid=""
cleanup() { [[ -n "$server_pid" ]] && stop_server; return 0; }
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

wait_for_npu() {
  local waited=0
  while :; do
    local loaded
    loaded=$(curl -s "$health_url" | jq -c '.all_models_loaded' 2>/dev/null)
    if ! pgrep -x flm >/dev/null && [[ "$loaded" == "[]" ]]; then
      return 0
    fi
    if (( waited >= 1800 )); then
      echo "NPU still busy after ${waited}s, giving up" >&2
      return 1
    fi
    echo "NPU busy (pgrep flm or all_models_loaded=$loaded); waiting 30s..." >&2
    sleep 30
    (( waited += 30 ))
  done
}

stop_server() {
  [[ -z "$server_pid" ]] && return 0
  kill -TERM "$server_pid" 2>/dev/null
  local waited=0
  while (( waited < 30 )) && kill -0 "$server_pid" 2>/dev/null; do
    sleep 1
    (( waited++ ))
  done
  kill -0 "$server_pid" 2>/dev/null && kill -KILL "$server_pid" 2>/dev/null
  wait "$server_pid" 2>/dev/null
  server_pid=""
  pgrep -x flm >/dev/null && { echo "WARN: flm still running after stop" >&2; return 1; }
  return 0
}

stamp() {
  python3 -u -c '
import sys, time
for line in sys.stdin:
    sys.stdout.write(f"{time.time():.3f}\t{line}")
    sys.stdout.flush()
'
}

start_server() { # <model> <port> <run_label>
  local m=$1 p=$2 run_label=$3
  wait_for_npu || { echo "ABORT: NPU never became free for $run_label" >&2; exit 1; }
  pgrep -x flm >/dev/null && { echo "ABORT: flm already running before $run_label" >&2; exit 1; }
  LD_LIBRARY_PATH="$libpath" stdbuf -oL -eL "$FLM" serve "$m" --port "$p" \
    > >(stamp >"$outdir/server-halfclose-$run_label.log") 2>&1 &
  server_pid=$!
  local waited=0
  while (( waited < 300 )); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "server for $run_label died before ready" >&2
      server_pid=""; return 1
    fi
    curl -s -o /dev/null "http://127.0.0.1:$p/api/version" && return 0
    sleep 1; (( waited++ ))
  done
  echo "server for $run_label not ready within 300s" >&2
  return 1
}

# one_run <port> <endpoint> <halfclose 0|1> -- sends a raw HTTP/1.1 request
# over a socket, optionally half-closes the write side right after sending,
# reads to EOF (120s timeout), and prints a JSON summary of the terminal
# reason and chunk count.
one_run() {
  python3 - "$@" <<'PY'
import http.client, json, socket, sys
port, endpoint, halfclose = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

msgs = [{"role": "user", "content": "Count from 1 to 20."}]
if endpoint == "chat":
    path = "/api/chat"
    body = {"model": "llama3.2:1b", "messages": msgs, "top_k": 1, "stream": True,
            "options": {"num_predict": 64}}
else:
    path = "/v1/chat/completions"
    body = {"model": "llama3.2:1b", "messages": msgs, "top_k": 1, "stream": True, "max_tokens": 64}

payload = json.dumps(body).encode()
req = (f"POST {path} HTTP/1.1\r\n"
       f"Host: 127.0.0.1:{port}\r\n"
       f"Content-Type: application/json\r\n"
       f"Content-Length: {len(payload)}\r\n"
       f"Connection: close\r\n\r\n").encode() + payload

sock = socket.create_connection(("127.0.0.1", int(port)), timeout=120)
sock.sendall(req)
if halfclose:
    sock.shutdown(socket.SHUT_WR)
sock.settimeout(120)
chunks_raw = []
while True:
    try:
        data = sock.recv(65536)
    except socket.timeout:
        break
    if not data:
        break
    chunks_raw.append(data)
sock.close()
raw = b"".join(chunks_raw).decode("utf-8", "replace")
body_start = raw.find("\r\n\r\n")
text = raw[body_start + 4:] if body_start >= 0 else raw

reason, content_chunks = None, 0
if endpoint == "chat":
    for line in text.splitlines():
        line = line.strip()
        if not line or all(c in "0123456789abcdefABCDEF" for c in line):
            continue
        try:
            j = json.loads(line)
        except ValueError:
            continue
        if (j.get("message") or {}).get("content"):
            content_chunks += 1
        if j.get("done_reason") is not None:
            reason = j["done_reason"]
else:
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("data: ") or line == "data: [DONE]":
            continue
        try:
            j = json.loads(line[6:])
        except ValueError:
            continue
        ch = (j.get("choices") or [{}])[0]
        if (ch.get("delta") or {}).get("content"):
            content_chunks += 1
        if ch.get("finish_reason") is not None:
            reason = ch["finish_reason"]

print(json.dumps({"reason": reason, "content_chunks": content_chunks}))
PY
}

summary="$outdir/halfclose-$label.txt"
: >"$summary"
printf '%-24s %-9s %-4s %-16s %s\n' endpoint halfclose run reason chunks | tee -a "$summary"

if ! start_server "$model" "$port" "$label"; then
  echo "server did not start; see server-halfclose-$label.log" | tee -a "$summary"
  exit 1
fi

for endpoint in chat openai; do
  for halfclose in 1 0; do
    for run in $(seq 1 "$N"); do
      result=$(one_run "$port" "$endpoint" "$halfclose")
      reason=$(jq -r .reason <<<"$result")
      chunks=$(jq -r .content_chunks <<<"$result")
      hc_label=$([[ "$halfclose" == 1 ]] && echo yes || echo no)
      printf '%-24s %-9s %-4s %-16s %s\n' "$endpoint" "$hc_label" "$run" "$reason" "$chunks" | tee -a "$summary"
    done
  done
done

stop_server
