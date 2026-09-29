#!/usr/bin/env bash
# client-halfclose.sh <flm-binary> <outdir> <scratch-dir>
#
# Proves that real clients of `flm serve` do NOT half-close their socket
# (shutdown(SHUT_WR)) after sending a request. flm's disconnect monitor
# treats read-EOF as a disconnect and logs "Client disconnected; cancelling
# active request" -- if that line ever appears while talking to a real
# client, the client is doing something flm mistakes for a disconnect.
#
# Part A drives flm through an isolated lemond (flm serve's main client in
# this flake). Part B drives a standalone `flm serve` directly
# with three different HTTP client stacks (curl, python requests, httpx).
#
# Pass = every streamed answer completes with finish/done reason "length" or
# "stop", and neither server log has a "Client disconnected" line during a
# POST (lemond's GET /api/tags readiness poll is reported, not gated).
set -u

FLM=${1:?usage: client-halfclose.sh <flm-binary> <outdir> <scratch-dir>}
outdir=${2:?usage: client-halfclose.sh <flm-binary> <outdir> <scratch-dir>}
scratch=${3:?usage: client-halfclose.sh <flm-binary> <outdir> <scratch-dir>}
mkdir -p "$outdir" "$scratch" || exit 1
outdir=$(cd "$outdir" && pwd) || exit 1
scratch=$(cd "$scratch" && pwd) || exit 1

libpath=/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib
[[ -d "$libpath" ]] || { echo "libpath not found: $libpath" >&2; exit 1; }

# Host lemond's NPU gate -- read-only health check, never started/stopped/touched here.
health_url=http://127.0.0.1:13305/api/v1/health

LEMOND=${LEMOND:-/nix/store/ivbbcmadaqqn8gv7500q31rifl2gnla0-lemonade-11.9.0/bin/lemond}
LEMONADE_DEFAULTS_SRC=${LEMONADE_DEFAULTS_SRC:-/nix/store/f0bk2bmdfbich6n2zjfzgs41zpgby8yj-lemonade-defaults.json}

real_home=$HOME
model_lemond="llama3.2-1b-FLM"
model_direct="llama3.2:1b"
port_lemond=13399
port_direct=58631

summary="$outdir/client-halfclose.txt"
: >"$summary"

server_pid=""
# shellcheck disable=SC2329 # invoked indirectly via `trap cleanup EXIT` below
cleanup() {
  [[ -n "$server_pid" ]] && stop_proc "$server_pid"
  reap_lemond_flm
  return 0
}

# reap_lemond_flm -- give lemond's flm child 30s to exit after lemond stops,
# then TERM any flm still running our binary, so no exit path leaves one
# holding the NPU.
reap_lemond_flm() {
  local waited=0 pid
  while pgrep -x flm >/dev/null && (( waited < 30 )); do
    sleep 1
    (( waited++ ))
  done
  for pid in $(pgrep -x flm); do
    if grep -q -- "$FLM" "/proc/$pid/cmdline" 2>/dev/null; then
      echo "WARN: killing stray flm pid $pid" >&2
      kill -TERM "$pid" 2>/dev/null
    fi
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

stop_proc() {
  local pid=$1
  kill -TERM "$pid" 2>/dev/null
  local waited=0
  while (( waited < 30 )) && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    (( waited++ ))
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
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

# --- python helpers, written into the scratch dir ---

cat >"$scratch/reqlib.py" <<'PY'
import json

def parse_ollama(lines):
    reason, chunks = None, 0
    for line in lines:
        line = (line or "").strip()
        if not line:
            continue
        try:
            j = json.loads(line)
        except ValueError:
            continue
        if (j.get("message") or {}).get("content"):
            chunks += 1
        if j.get("done_reason") is not None:
            reason = j["done_reason"]
    return reason, chunks

def parse_openai(lines):
    reason, chunks = None, 0
    for line in lines:
        line = (line or "").strip()
        if not line.startswith("data: ") or line == "data: [DONE]":
            continue
        try:
            j = json.loads(line[6:])
        except ValueError:
            continue
        ch = (j.get("choices") or [{}])[0]
        if (ch.get("delta") or {}).get("content"):
            chunks += 1
        if ch.get("finish_reason") is not None:
            reason = ch["finish_reason"]
    return reason, chunks
PY

# Part A client: http.client against lemond's OpenAI- and Ollama-compatible routes.
cat >"$scratch/lemond_req.py" <<'PY'
import http.client, json, sys

endpoint, stream_flag, port, model = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
stream = stream_flag == "1"
msgs = [{"role": "user", "content": "Count from 1 to 40."}]

if endpoint == "v1":
    path = "/v1/chat/completions"
    body = {"model": model, "messages": msgs, "stream": stream, "max_tokens": 64, "temperature": 0}
else:
    path = "/api/chat"
    body = {"model": model, "messages": msgs, "stream": stream, "options": {"num_predict": 64}}

payload = json.dumps(body).encode()
conn = http.client.HTTPConnection("127.0.0.1", int(port), timeout=600)
conn.request("POST", path, body=payload, headers={"Content-Type": "application/json"})
resp = conn.getresponse()
status = resp.status

if status == 404:
    conn.close()
    print(json.dumps({"status": status, "reason": None, "chunks": 0}))
    sys.exit(0)

if not stream:
    data = json.loads(resp.read())
    conn.close()
    if endpoint == "v1":
        ch = (data.get("choices") or [{}])[0]
        reason = ch.get("finish_reason")
    else:
        reason = data.get("done_reason")
    print(json.dumps({"status": status, "reason": reason, "chunks": None}))
    sys.exit(0)

buf = b""
while True:
    chunk = resp.read(65536)
    if not chunk:
        break
    buf += chunk
conn.close()
text = buf.decode("utf-8", "replace")

import reqlib
if endpoint == "v1":
    reason, chunks = reqlib.parse_openai(text.splitlines())
else:
    reason, chunks = reqlib.parse_ollama(text.splitlines())

print(json.dumps({"status": status, "reason": reason, "chunks": chunks}))
PY

# Part B client: curl's raw streamed body, piped in and parsed here.
cat >"$scratch/curl_parse.py" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[2])
import reqlib

endpoint = sys.argv[1]
raw = sys.stdin.read()
marker = "\n__STATUS__:"
idx = raw.rfind(marker)
if idx >= 0:
    body, status = raw[:idx], raw[idx + len(marker):].strip()
else:
    body, status = raw, ""

lines = body.splitlines()
if endpoint == "ollama":
    reason, chunks = reqlib.parse_ollama(lines)
else:
    reason, chunks = reqlib.parse_openai(lines)
print(json.dumps({"status": status, "reason": reason, "chunks": chunks}))
PY

cat >"$scratch/requests_req.py" <<'PY'
import json, sys
endpoint, port, model, scratch = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
sys.path.insert(0, scratch)
import reqlib
import requests

msgs = [{"role": "user", "content": "Count from 1 to 40."}]
if endpoint == "ollama":
    url = f"http://127.0.0.1:{port}/api/chat"
    body = {"model": model, "messages": msgs, "stream": True, "top_k": 1, "options": {"num_predict": 64}}
else:
    url = f"http://127.0.0.1:{port}/v1/chat/completions"
    body = {"model": model, "messages": msgs, "stream": True, "max_tokens": 64}

r = requests.post(url, json=body, stream=True, timeout=600)
lines = [l.decode("utf-8", "replace") if isinstance(l, bytes) else l for l in r.iter_lines()]
status = r.status_code
r.close()
if endpoint == "ollama":
    reason, chunks = reqlib.parse_ollama(lines)
else:
    reason, chunks = reqlib.parse_openai(lines)
print(json.dumps({"status": status, "reason": reason, "chunks": chunks}))
PY

cat >"$scratch/httpx_req.py" <<'PY'
import json, sys
endpoint, port, model, scratch = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
sys.path.insert(0, scratch)
import reqlib
import httpx

msgs = [{"role": "user", "content": "Count from 1 to 40."}]
if endpoint == "ollama":
    url = f"http://127.0.0.1:{port}/api/chat"
    body = {"model": model, "messages": msgs, "stream": True, "top_k": 1, "options": {"num_predict": 64}}
else:
    url = f"http://127.0.0.1:{port}/v1/chat/completions"
    body = {"model": model, "messages": msgs, "stream": True, "max_tokens": 64}

with httpx.Client(timeout=600) as client:
    with client.stream("POST", url, json=body) as r:
        lines = list(r.iter_lines())
        status = r.status_code

if endpoint == "ollama":
    reason, chunks = reqlib.parse_ollama(lines)
else:
    reason, chunks = reqlib.parse_openai(lines)
print(json.dumps({"status": status, "reason": reason, "chunks": chunks}))
PY

append_result() {
  # append_result <via> <endpoint-path> <stream 0|1> <run> <json-result>
  local via=$1 endpoint=$2 stream=$3 run=$4 result=$5
  local stream_json; stream_json=$([[ "$stream" == 1 ]] && echo true || echo false)
  echo "$result" | jq --arg via "$via" --arg endpoint "$endpoint" \
    --argjson stream "$stream_json" --argjson run "$run" \
    '. + {via:$via, endpoint:$endpoint, stream:$stream, run:$run}' >>"$summary"
}

##############################################################################
# Part A -- through an isolated lemond
##############################################################################

lemond_dir="$scratch/lemond-e2e"
mkdir -p "$lemond_dir/home/.config/flm" "$lemond_dir/cache" "$lemond_dir/config"
ln -sfn "$real_home/.config/flm/models" "$lemond_dir/home/.config/flm/models"

wrapper="$lemond_dir/flm-wrap"
# lemond parses stdout of `flm validate --json` and `flm version`, so only
# `serve` output is redirected to a file; those lines are NOT timestamped.
cat >"$wrapper" <<WRAP
#!/bin/sh
if [ "\$1" = serve ]; then
  exec "$FLM" "\$@" >>"$outdir/server-lemond-e2e.log" 2>&1
fi
exec "$FLM" "\$@"
WRAP
chmod +x "$wrapper"

defaults="$lemond_dir/defaults.json"
jq '.flm.npu_bin = $w | .flm.prefer_system = true' --arg w "$wrapper" \
  "$LEMONADE_DEFAULTS_SRC" >"$defaults" || exit 1

wait_for_npu || { echo "ABORT: NPU never became free before lemond e2e" >&2; exit 1; }
pgrep -x flm >/dev/null && { echo "ABORT: flm already running before lemond e2e" >&2; exit 1; }

HOME="$lemond_dir/home" \
  LEMONADE_DEFAULTS_PATH="$defaults" \
  LEMONADE_CACHE_DIR="$lemond_dir/cache" \
  FLM_DISABLE_UPDATE_CHECK=1 \
  LD_LIBRARY_PATH="$libpath" \
  "$LEMOND" --port "$port_lemond" --no-broadcast --log-file disabled \
    "$lemond_dir/cache" "$lemond_dir/config" \
    > >(stamp >"$outdir/lemond-e2e.log") 2>&1 &
server_pid=$!

waited=0
lemond_ready=0
while (( waited < 120 )); do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "lemond died before ready; see lemond-e2e.log" >&2
    break
  fi
  if curl -s -o /dev/null "http://127.0.0.1:$port_lemond/api/v1/health"; then
    lemond_ready=1
    break
  fi
  sleep 1
  (( waited++ ))
done
(( lemond_ready )) || { echo "lemond not healthy within 120s" >&2; exit 1; }

# Request 1 (streaming /v1/chat/completions) 3x -- the first call also makes
# lemond load the model via flm serve, so allow the 600s client timeout to
# cover load time.
for run in 1 2 3; do
  result=$(python3 "$scratch/lemond_req.py" v1 1 "$port_lemond" "$model_lemond")
  append_result lemond /v1/chat/completions 1 "$run" "$result"
done

result=$(python3 "$scratch/lemond_req.py" v1 0 "$port_lemond" "$model_lemond")
append_result lemond /v1/chat/completions 0 1 "$result"

result=$(python3 "$scratch/lemond_req.py" ollama 1 "$port_lemond" "$model_lemond")
append_result lemond /api/chat 1 1 "$result"

curl -s -X POST "http://127.0.0.1:$port_lemond/api/v1/unload" \
  -H 'Content-Type: application/json' \
  -d "{\"model_name\":\"$model_lemond\"}" -o /dev/null

stop_proc "$server_pid"
server_pid=""

reap_lemond_flm

# Only POSTs (the chat requests) gate: lemond's readiness poll is a GET
# /api/tags that it may abandon while flm is still starting.
disc_lemond=$(awk '/Incoming Request:/ { post = /POST/ } /Client disconnected/ && post { n++ } END { print n + 0 }' "$outdir/server-lemond-e2e.log")
disc_lemond_all=$(grep -c "Client disconnected" "$outdir/server-lemond-e2e.log")
wait_fail_lemond=$(grep -c "Client socket wait failed" "$outdir/server-lemond-e2e.log")
start_gen_lemond=$(grep -c "Start generating" "$outdir/server-lemond-e2e.log")
echo "lemond e2e log: Client disconnected on POST=$disc_lemond (any request: $disc_lemond_all), Client socket wait failed=$wait_fail_lemond, Start generating=$start_gen_lemond"
(( start_gen_lemond > 0 )) || echo "WARN: server-lemond-e2e.log never saw 'Start generating' -- log may not have captured flm's output" >&2

##############################################################################
# Part B -- direct clients against a standalone flm serve
##############################################################################

wait_for_npu || { echo "ABORT: NPU never became free before direct flm serve" >&2; exit 1; }
pgrep -x flm >/dev/null && { echo "ABORT: flm already running before direct flm serve" >&2; exit 1; }

LD_LIBRARY_PATH="$libpath" "$FLM" serve "$model_direct" --port "$port_direct" \
  > >(stamp >"$outdir/server-client-direct.log") 2>&1 &
server_pid=$!

waited=0
direct_ready=0
while (( waited < 300 )); do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "direct flm serve died before ready; see server-client-direct.log" >&2
    break
  fi
  curl -s -o /dev/null "http://127.0.0.1:$port_direct/api/version" && { direct_ready=1; break; }
  sleep 1
  (( waited++ ))
done
(( direct_ready )) || { echo "direct flm serve not ready within 300s" >&2; exit 1; }

# python3 with requests and httpx: the one on PATH if it has both, else a
# nixpkgs python3.withPackages env.
pyclients=python3
if ! python3 -c "import requests, httpx" >/dev/null 2>&1; then
  # shellcheck disable=SC2016 # a Nix expression, not shell
  pyenv=$(nix build --no-link --print-out-paths --impure --expr \
    '(builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem}.python3.withPackages (p: [ p.requests p.httpx ])') \
    || { echo "cannot build a python with requests+httpx" >&2; exit 1; }
  pyclients=$pyenv/bin/python3
fi

call_curl() {
  local endpoint=$1 url body
  if [[ "$endpoint" == ollama ]]; then
    url="http://127.0.0.1:$port_direct/api/chat"
    body=$(jq -n --arg model "$model_direct" \
      '{model:$model, messages:[{role:"user",content:"Count from 1 to 40."}], stream:true, top_k:1, options:{num_predict:64}}')
  else
    url="http://127.0.0.1:$port_direct/v1/chat/completions"
    body=$(jq -n --arg model "$model_direct" \
      '{model:$model, messages:[{role:"user",content:"Count from 1 to 40."}], stream:true, max_tokens:64}')
  fi
  curl -sN -w '\n__STATUS__:%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "$body" "$url" | python3 "$scratch/curl_parse.py" "$endpoint" "$scratch"
}

call_requests() {
  "$pyclients" "$scratch/requests_req.py" "$1" "$port_direct" "$model_direct" "$scratch"
}

call_httpx() {
  "$pyclients" "$scratch/httpx_req.py" "$1" "$port_direct" "$model_direct" "$scratch"
}

for endpoint in ollama openai; do
  ep_path=$([[ "$endpoint" == ollama ]] && echo "/api/chat" || echo "/v1/chat/completions")

  result=$(call_curl "$endpoint")
  append_result curl "$ep_path" 1 1 "$result"

  result=$(call_requests "$endpoint")
  append_result requests "$ep_path" 1 1 "$result"

  result=$(call_httpx "$endpoint")
  append_result httpx "$ep_path" 1 1 "$result"
done

stop_proc "$server_pid"
server_pid=""

disc_direct=$(grep -c "Client disconnected" "$outdir/server-client-direct.log")
echo "direct server log: Client disconnected=$disc_direct"

##############################################################################
# Summary
##############################################################################

echo "=== per via/endpoint reasons ==="
jq -s -r 'group_by(.via + " " + .endpoint) | .[] |
  "\(.[0].via) \(.[0].endpoint): " + ([.[] | (.reason // "null") | tostring] | join(","))' "$summary"

echo "Client disconnected on a POST (lemond e2e): $disc_lemond (any request: $disc_lemond_all)"
echo "Client disconnected (direct clients): $disc_direct"

bad_reasons=$(jq -s '[.[] | select(.reason != "length" and .reason != "stop")] | length' "$summary")
echo "results with an unexpected reason: $bad_reasons"

fail=0
(( disc_lemond > 0 )) && fail=1
(( disc_direct > 0 )) && fail=1
(( bad_reasons > 0 )) && fail=1
exit "$fail"
