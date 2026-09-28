#!/usr/bin/env bash
# disconnect.sh <flm-binary> <outdir>
#
# Red/green for #191: /api/generate, /api/chat and /v1/completions did not
# pass the request's cancellation predicate to insert()/generate(), so a client
# that disconnected left the server decoding to its token limit with the NPU
# lock held. /v1/chat/completions already cancels; it is the control.
#
# Per model (llama3.2:1b on 58601, gemma4-it:e4b on 58603), for each endpoint
# -- streaming chat, generate, openai, completions, and non-streaming
# generate-ns, completions-ns -- in this order:
#   full     read the reply to the end; record the stop reason, token count,
#            wall time and content (the same order on every build, so the
#            content can be byte-diffed against another build)
#   decode   the same request; close the socket after 5 content chunks
#            (non-streaming: after DECODE_CLOSE_S), mid-decode
#   prefill  streaming only: a ~12k-token prompt, closed PREFILL_CLOSE_S after
#            sending, during the first prefill chunk
#   queued   generate-ns only: sent while a normal /api/chat holds the NPU,
#            closed PREFILL_CLOSE_S later while it waits in the queue; its
#            hold is timed from its dequeue, not from the close
# After each close the probe sends a small non-streaming /api/chat at once.
#
# The server log is stamped per line with wall-clock time, so the time from
# the close to the first line showing the work over is the NPU hold after the
# disconnect. The contract, on every probed endpoint: mid-decode, that hold is
# under HOLD_BOUND_S; mid-prefill, no further prefill chunk starts after the
# chunk already running (one 4096-token chunk takes ~1.8s on llama and ~8.5s
# on gemma4 here). Non-streaming /api/chat is not probed.
# ENDPOINTS="<ep> ..." limits the run to those endpoints.
set -u

FLM=${1:?usage: disconnect.sh <flm-binary> <outdir>}
outdir=${2:?usage: disconnect.sh <flm-binary> <outdir>}
mkdir -p "$outdir" || exit 1
outdir=$(cd "$outdir" && pwd) || exit 1

libpath=/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib
health_url=http://127.0.0.1:13305/api/v1/health
export PROMPT="Write a detailed essay of at least 2000 words on the history of the printing press."
export NUM_PREDICT=512
export HOLD_BOUND_S=2
# About 12k tokens: three 4096-token prefill chunks on both models, so a close
# during the first chunk is seen at the next chunk boundary.
PREFILL_PROMPT="$(printf 'The quick brown fox jumps over the lazy dog. %.0s' $(seq 1200))Summarise the text above."
export PREFILL_PROMPT
export PREFILL_CLOSE_S=0.3
export DECODE_CLOSE_S=2

pass_count=0
fail_count=0
results=()

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

# stamp -- prefix each line with wall-clock seconds, flushed per line.
stamp() {
  python3 -u -c '
import sys, time
for line in sys.stdin:
    sys.stdout.write(f"{time.time():.3f}\t{line}")
    sys.stdout.flush()
'
}

start_server() { # <model> <port> <label>
  local model=$1 port=$2 label=$3
  wait_for_npu || { echo "ABORT: NPU never became free for $label" >&2; exit 1; }
  pgrep -x flm >/dev/null && { echo "ABORT: flm already running before $label" >&2; exit 1; }
  LD_LIBRARY_PATH="$libpath" stdbuf -oL -eL "$FLM" serve "$model" --port "$port" \
    > >(stamp >"$outdir/server-$label.log") 2>&1 &
  server_pid=$!
  local waited=0
  while (( waited < 300 )); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "server for $label died before ready" >&2
      server_pid=""; return 1
    fi
    curl -s -o /dev/null "http://127.0.0.1:$port/api/version" && return 0
    sleep 1; (( waited++ ))
  done
  echo "server for $label not ready within 300s" >&2
  return 1
}

record() {
  local id=$1 status=$2 reason=${3:-}
  if [[ "$status" == PASS ]]; then
    echo "PASS $id"; results+=("PASS $id"); (( pass_count++ ))
  else
    echo "FAIL $id: $reason"; results+=("FAIL $id: $reason"); (( fail_count++ ))
  fi
}

# probe <port> <model> <endpoint> <mode> <prefix> -- one request; prints a JSON
# summary line and writes <prefix>.transcript (arrival-stamped lines) and
# <prefix>.content. Modes: full (read to the end), decode (close after 5
# content chunks, or after DECODE_CLOSE_S on a non-streaming endpoint), prefill
# (send PREFILL_PROMPT, close after PREFILL_CLOSE_S, before any output).
probe() {
  python3 - "$@" <<'PY'
import http.client, json, os, socket, sys, threading, time
port, model, endpoint, mode, prefix = sys.argv[1:6]
n = int(os.environ["NUM_PREDICT"])
prompt = os.environ["PREFILL_PROMPT"] if mode == "prefill" else os.environ["PROMPT"]
msgs = [{"role": "user", "content": prompt}]
stream = not endpoint.endswith("-ns")
kind = endpoint.removesuffix("-ns")
if kind == "chat":
    path, body = "/api/chat", {"model": model, "messages": msgs, "top_k": 1, "options": {"num_predict": n}}
elif kind == "generate":
    # handle_generate reads its limit from top-level max_tokens, not options.num_predict
    path, body = "/api/generate", {"model": model, "prompt": prompt, "max_tokens": n, "options": {"num_predict": n}}
elif kind == "openai":
    path, body = "/v1/chat/completions", {"model": model, "messages": msgs, "top_k": 1, "max_tokens": n}
else:
    path, body = "/v1/completions", {"model": model, "prompt": prompt, "top_k": 1, "max_tokens": n}
body["stream"] = stream

def text_of(j):
    if kind == "chat":
        return j.get("message", {}).get("content")
    if kind == "generate":
        return j.get("response")
    ch = (j.get("choices") or [{}])[0]
    return (ch.get("delta") or {}).get("content") if kind == "openai" else ch.get("text")

def reason_of(j):
    if kind in ("chat", "generate"):
        return {k: j.get(k) for k in ("done", "done_reason", "eval_count", "prompt_eval_count")}
    return {"finish_reason": (j.get("choices") or [{}])[0].get("finish_reason"),
            "completion_tokens": (j.get("usage") or {}).get("completion_tokens")}

blocker = None
if mode == "queued":
    # Hold the NPU with a normal request so the probed one waits in the queue.
    def block():
        b = http.client.HTTPConnection("127.0.0.1", int(port), timeout=600)
        b.request("POST", "/api/chat", json.dumps({"model": model, "messages": msgs, "stream": False,
                                                  "top_k": 1, "options": {"num_predict": n}}),
                  {"Content-Type": "application/json"})
        b.getresponse().read()
    blocker = threading.Thread(target=block)
    blocker.start()
    time.sleep(0.5)

conn = http.client.HTTPConnection("127.0.0.1", int(port), timeout=600)
t0 = time.time()
conn.request("POST", path, json.dumps(body), {"Content-Type": "application/json"})

def close():
    # close() alone leaves the fd open while a makefile still references it;
    # shutdown() sends the FIN now.
    conn.sock.shutdown(socket.SHUT_RDWR)
    t = time.time()
    conn.close()
    return t

content, chunks, last, t_close, status = "", 0, None, None, None
if mode in ("prefill", "queued") or (mode == "decode" and not stream):
    time.sleep(float(os.environ["DECODE_CLOSE_S" if mode == "decode" else "PREFILL_CLOSE_S"]))
    t_close = close()
elif not stream:
    resp = conn.getresponse()
    status, raw = resp.status, resp.read()
    with open(prefix + ".transcript", "w") as out:
        out.write(f"{time.time() - t0:8.3f}\t{raw.decode('utf-8', 'replace')}\n")
    last = json.loads(raw)
    content = text_of(last) or ""
    chunks = 1 if content else 0
else:
    resp = conn.getresponse()
    status = resp.status
    with open(prefix + ".transcript", "w") as out:
        while True:
            raw = resp.fp.readline()
            if not raw:
                break
            line = raw.decode("utf-8", "replace").strip()
            if not line or all(c in "0123456789abcdefABCDEF" for c in line):
                continue  # blank line or chunked-encoding size line
            out.write(f"{time.time() - t0:8.3f}\t{line}\n")
            if line.startswith("data: "):
                if line == "data: [DONE]":
                    continue
                line = line[6:]
            j = json.loads(line)
            last = j
            text = text_of(j)
            if text:
                content += text
                chunks += 1
            if mode == "decode" and chunks >= 5:
                resp.close()
                t_close = close()
                break
with open(prefix + ".content", "w") as f:
    f.write(content)
summary = {"status": status, "content_chunks": chunks, "wall_s": round(time.time() - t0, 3)}
if t_close is None:
    summary.update(reason_of(last or {}))
    print(json.dumps(summary))
    sys.exit(0)

summary["t_close"] = t_close
if kind == "completions":
    # /v1/completions never takes the NPU lock (requires_npu_access() omits
    # it), so a follow-up would run on the NPU concurrently with it; the log
    # alone times this one.
    print(json.dumps(summary))
    sys.exit(0)

# Disconnected: time a small follow-up; it cannot start until the NPU is free.
f = http.client.HTTPConnection("127.0.0.1", int(port), timeout=600)
f.request("POST", "/api/chat", json.dumps({"model": model, "messages": [{"role": "user", "content": "Say hi."}],
                                             "stream": False, "top_k": 1, "options": {"num_predict": 4}}),
          {"Content-Type": "application/json"})
fr = f.getresponse()
fj = json.loads(fr.read())
summary["followup_status"] = fr.status
summary["followup_wall_s"] = round(time.time() - t_close, 3)
summary["followup_server_total_s"] = round(fj.get("total_duration", 0) / 1e9, 3)
if blocker:
    blocker.join()
print(json.dumps(summary))
PY
}

# npu_hold <log> <t_close> <endpoint> <mode> -- polls the log (up to
# 180s) for the first line after t_close showing the request's work over, and
# prints the seconds to it. On the locked routes that is the NPU coming free:
# "NPU Lock Released!" (nothing queued), "Dequeuing NPU request" (handed to the
# follow-up) or "NPU Locked!" (the follow-up found it free). /v1/completions
# takes no lock, so there it is generate() logging its raw output on return,
# or the patched build logging a cancelled prefill. Also prints when the server logged
# the disconnect, and how many further prefill chunks started after the close.
npu_hold() {
  python3 - "$@" <<'PY'
import json, sys, time
log, t_close, endpoint, mode = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
if endpoint.startswith("completions"):
    ends = ("Model RAW Output", "Prefill Cancelled!")
else:
    ends = ("NPU Lock Released", "Dequeuing NPU request", "NPU Locked!")
deadline = time.time() + 180
while True:
    end = disc = start = None
    chunks = 0
    for line in open(log, errors="replace"):
        ts, _, text = line.partition("\t")
        try:
            t = float(ts)
        except ValueError:
            continue
        if t < t_close - 0.5:
            continue
        if disc is None and ("Client disconnected" in text or "Client socket wait failed" in text):
            disc = round(t - t_close, 3)
        if t < t_close:
            continue
        if mode == "queued" and start is None:
            # The blocker hands the NPU to the probed request.
            if "Dequeuing NPU request" in text:
                start = t
            continue
        if "Prefill chunk" in text and "Prefill chunk 1/" not in text:
            chunks += 1
        if any(m in text for m in ends):
            end = round(t - (start if mode == "queued" else t_close), 3)
            break
    if end is not None or time.time() > deadline:
        break
    time.sleep(1)
print(json.dumps({"npu_hold_s": end, "disconnect_logged_s": disc, "prefill_chunks_after_close": chunks}))
PY
}

# check_disconnect <label> <endpoint> <mode> <port> <model>
check_disconnect() {
  local label=$1 ep=$2 mode=$3 port=$4 model=$5 bound=$HOLD_BOUND_S disc hold hold_s
  disc=$(probe "$port" "$model" "$ep" "$mode" "$outdir/$label.$ep.$mode")
  sleep 1
  hold=$(npu_hold "$outdir/server-$label.$ep.log" "$(jq -r .t_close <<<"$disc")" "$ep" "$mode")
  echo "$ep $mode: $disc $hold"
  hold_s=$(jq -r .npu_hold_s <<<"$hold")
  if [[ "$mode" == prefill ]]; then
    # One chunk already on the NPU cannot be interrupted; none may follow it.
    if [[ "$hold_s" != null ]] && jq -e '.prefill_chunks_after_close == 0' <<<"$hold" >/dev/null; then
      record "$label/$ep/$mode" PASS
    else
      record "$label/$ep/$mode" FAIL "$(jq -r .prefill_chunks_after_close <<<"$hold") more prefill chunk(s) ran after the client closed; work ended ${hold_s}s after it"
    fi
  elif [[ "$hold_s" != null ]] && jq -e --argjson b "$bound" '.npu_hold_s < $b' <<<"$hold" >/dev/null; then
    record "$label/$ep/$mode" PASS
  else
    record "$label/$ep/$mode" FAIL "work continued ${hold_s}s after the client closed (bound ${bound}s)"
  fi
}

probe_model() { # <model> <port> <label>
  local model=$1 port=$2 label=$3 ep full

  echo "== $label ($model) =="
  # A fresh server per endpoint: flm serve never returns the connection slot
  # of a streaming client that disconnected (send_chunk_data's write-error
  # path skips the decrement), and it refuses every connection after 10.
  for ep in ${ENDPOINTS:-chat generate openai completions generate-ns completions-ns}; do
    if ! start_server "$model" "$port" "$label.$ep"; then
      record "$label/$ep/startup" FAIL "server did not become ready"
      continue
    fi
    full=$(probe "$port" "$model" "$ep" full "$outdir/$label.$ep.full")
    echo "$ep full: $full"
    if jq -e '.status == 200 and .content_chunks > 0' <<<"$full" >/dev/null; then
      record "$label/$ep/full" PASS
    else
      record "$label/$ep/full" FAIL "$full"
    fi
    check_disconnect "$label" "$ep" decode "$port" "$model"
    [[ "$ep" == *-ns ]] || check_disconnect "$label" "$ep" prefill "$port" "$model"
    # /v1/completions takes no NPU lock (#192), so it never queues.
    [[ "$ep" == generate-ns ]] && check_disconnect "$label" "$ep" queued "$port" "$model"
    if kill -0 "$server_pid" 2>/dev/null; then
      record "$label/$ep/server-alive" PASS
    else
      record "$label/$ep/server-alive" FAIL "flm serve exited (see server-$label.$ep.log)"
    fi
    stop_server
  done
}

probe_model llama3.2:1b 58601 llama
probe_model gemma4-it:e4b 58603 gemma4

echo "== summary =="
for r in "${results[@]}"; do echo "$r"; done
echo "$pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
