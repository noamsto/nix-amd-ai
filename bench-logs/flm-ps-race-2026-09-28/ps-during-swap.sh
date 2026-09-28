#!/usr/bin/env bash
# ps-during-swap.sh <flm> <outdir> <label>
#
# Evidence for #184: does GET /api/ps answer stale or wrong during a model
# swap? Polls /api/ps every 50ms across a single /api/chat request that
# swaps the served model (llama3.2:1b -> gemma4-it:e4b), then checks that
# no poll during the swap is slow (it must never wait on the NPU lock), and
# that the reported model name never goes stale (no llama3.2:1b answer once
# the first [] appears at/after the request was sent, and gemma4-it:e4b
# shows up at/after the reply).
#
# Exit code reflects the oracle in $out_file (any FAIL line -> nonzero), not
# just process bookkeeping: the base build is expected to FAIL no-stale.
set -u

FLM=${1:?usage: ps-during-swap.sh <flm> <outdir> <label>}
outdir=${2:?usage: ps-during-swap.sh <flm> <outdir> <label>}
label=${3:?usage: ps-during-swap.sh <flm> <outdir> <label>}
mkdir -p "$outdir"

LIB=/nix/store/cvn4bqwv1y6iyk412jzc06bhl01c5kb9-xrt-combined/lib
PORT=58606
tsv="$outdir/ps-swap-$label.tsv"
times_file="$outdir/ps-swap-$label.times"
out_file="$outdir/ps-swap-$label.txt"
stop_flag="$outdir/.stop-poller-$label"
: >"$tsv"
: >"$times_file"
: >"$out_file"
rm -f "$stop_flag"

pid=""
poller_pid=""
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

# The poller finishes its in-flight poll and exits on the stop flag, so no
# poll is cut off mid-request (curl would record 000).
stop_poller() {
  [ -n "$poller_pid" ] || return 0
  touch "$stop_flag"
  wait "$poller_pid" 2>/dev/null
  poller_pid=""
  rm -f "$stop_flag"
}

# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() {
  stop_poller
  stop
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

up() {
  LD_LIBRARY_PATH=$LIB "$FLM" serve llama3.2:1b --port "$PORT" \
    >"$outdir/server-ps-swap-$label.log" 2>&1 &
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

poll_once() {
  local epoch_ms tmp body code time_total names
  epoch_ms=$(date +%s%3N)
  tmp=$(mktemp)
  curl -s --max-time 10 -w '\t%{http_code}\t%{time_total}\n' "http://127.0.0.1:$PORT/api/ps" >"$tmp" 2>/dev/null
  local last_line
  last_line=$(tail -n1 "$tmp")
  code=$(printf '%s' "$last_line" | awk -F'\t' '{print $(NF-1)}')
  time_total=$(printf '%s' "$last_line" | awk -F'\t' '{print $NF}')
  body=$(sed -E 's/\t[0-9]{3}\t[0-9.]+$//' "$tmp")
  names=$(printf '%s' "$body" | jq -r '[.models[]?.name] | join(",")' 2>/dev/null)
  [ -z "$names" ] && names="[]"
  printf '%s\t%s\t%s\t%s\n' "$epoch_ms" "${code:-000}" "${time_total:-0}" "$names" >>"$tsv"
  rm -f "$tmp"
}

poller_loop() {
  while [ ! -e "$stop_flag" ]; do
    poll_once
    sleep 0.05
  done
}

wait_for_no_flm

if ! up; then
  stop
  echo "FAIL server-up" >"$out_file"
  rc=1
else
  poller_loop &
  poller_pid=$!

  sleep 1 # baseline
  t_send=$(date +%s%3N)
  chat_body='{"model":"gemma4-it:e4b","messages":[{"role":"user","content":"Say hi."}],"stream":false,"options":{"num_predict":1}}'
  chat_code=$(curl -s -o /dev/null --max-time 600 -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/chat" \
    -H 'Content-Type: application/json' -d "$chat_body")
  t_reply=$(date +%s%3N)
  sleep 1

  stop_poller
  stop

  {
    echo "t_send $t_send"
    echo "t_reply $t_reply"
    echo "chat_code $chat_code"
  } >"$times_file"

  python3 - "$tsv" "$times_file" "$out_file" <<'PY'
import statistics
import sys

tsv_path, times_path, out_path = sys.argv[1:4]

t_send = t_reply = None
with open(times_path) as f:
    for line in f:
        parts = line.split()
        if len(parts) != 2:
            continue
        key, val = parts
        if key == "t_send":
            t_send = int(val)
        elif key == "t_reply":
            t_reply = int(val)

rows = []
with open(tsv_path) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 4:
            continue
        epoch_ms, code, time_total, names = parts
        try:
            rows.append((int(epoch_ms), code, float(time_total), names))
        except ValueError:
            continue

total = len(rows)
code_hist = {}
for _, code, _, _ in rows:
    code_hist[code] = code_hist.get(code, 0) + 1

window = [r for r in rows if t_send is not None and t_reply is not None and t_send <= r[0] <= t_reply]
window_times = [r[2] for r in window]
max_latency = max(window_times) if window_times else 0.0
p50_latency = statistics.median(window_times) if window_times else 0.0

seq = []
for _, _, _, names in rows:
    if not seq or seq[-1][0] != names:
        seq.append([names, 1])
    else:
        seq[-1][1] += 1
collapsed = " -> ".join(f"{n} x{c}" for n, c in seq)

out_lines = []
out_lines.append(f"INFO total_polls={total}")
out_lines.append("INFO code_histogram: " + ";".join(f"{k}={v}" for k, v in sorted(code_hist.items())))
out_lines.append(
    f"INFO load_window_polls={len(window)} max_time_total={max_latency:.4f} p50_time_total={p50_latency:.4f}"
)
out_lines.append("INFO name_sequence: " + collapsed)

all_200 = total > 0 and all(code == "200" for _, code, _, _ in rows)
out_lines.append(("PASS" if all_200 else "FAIL") + " all-200")

max_lat_ok = bool(window_times) and max_latency < 0.1
out_lines.append(("PASS" if max_lat_ok else "FAIL") + " max-latency<0.1s")

first_empty_idx = None
for i, (epoch_ms, _, _, names) in enumerate(rows):
    if t_send is not None and epoch_ms >= t_send and names == "[]":
        first_empty_idx = i
        break

no_stale = False
if first_empty_idx is not None:
    stale_seen = any(
        "llama3.2:1b" in names.split(",") for _, _, _, names in rows[first_empty_idx + 1 :]
    )
    new_seen_after_reply = any(
        t_reply is not None and epoch_ms >= t_reply and "gemma4-it:e4b" in names.split(",")
        for epoch_ms, _, _, names in rows
    )
    no_stale = (not stale_seen) and new_seen_after_reply
out_lines.append(("PASS" if no_stale else "FAIL") + " no-stale")

with open(out_path, "w") as f:
    for line in out_lines:
        print(line)
        f.write(line + "\n")
PY
  python_rc=$?
  [ "$python_rc" -eq 0 ] || rc=1

  grep -q '^FAIL' "$out_file" && rc=1
  grep -qE '^(PASS|FAIL) no-stale$' "$out_file" || rc=1
fi

if pgrep -x flm >/dev/null; then
  echo "stray flm!" >&2
  rc=1
fi

exit "$rc"
