#!/usr/bin/env bash
# accept-error-backoff.sh <flm> <port> <outdir> <label>
#
# Red/green probe for #207: does flm serve busy-spin when async_accept fails
# persistently (EMFILE)?
#
# The probe starts flm serve with no model tag, so it never touches the NPU.
# It samples the process's CPU ticks while idle (baseline), lowers the process's
# RLIMIT_NOFILE soft limit to its current open-fd count so accept4 has no fd to
# allocate and fails EMFILE, holds one pending connection so the listener stays
# readable, samples CPU again (exhausted), then restores the limit and checks
# the server accepts again (recovery).
#
# On an affected build the error handler re-arms immediately, so the exhausted
# figure is far above baseline. On a fixed build it is near baseline.
#
# The probe fails closed: if it cannot lower the limit it exits non-zero rather
# than reporting a near-baseline "green" that was never under exhaustion.
set -uo pipefail
FLM=${1:?flm path}
port=${2:?port}
out=${3:?outdir}
label=${4:-run}
LIB=${XRT_LIB_DIR:?set XRT_LIB_DIR to the xrt-combined lib dir}
pid=""
rc=0

# A SIGSTOPped flm (not used here, but symmetric with #202's probe) must be
# resumed before TERM; bounded TERM wait, then KILL, then reap.
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
meas="$out/cpu-$label.txt"
: >"$log"
: >"$meas"

# Wait for any other worker's or the system's flm to finish; never touch it.
waited=0
while pgrep -x flm >/dev/null; do
  [ "$waited" -ge 60 ] && { echo "another flm still running after 60s" >&2; exit 1; }
  sleep 2
  waited=$((waited + 2))
done

LD_LIBRARY_PATH="$LIB" "$FLM" serve -p "$port" >>"$log" 2>&1 &
pid=$!
for _ in $(seq 300); do
  kill -0 "$pid" 2>/dev/null || { echo "server died during startup" >&2; tail -5 "$log" >&2; exit 1; }
  curl -s -o /dev/null "http://127.0.0.1:$port/api/version" && break
  sleep 1
done
curl -s -o /dev/null "http://127.0.0.1:$port/api/version" || { echo "server not ready" >&2; exit 1; }
sleep 2

hz=$(getconf CLK_TCK)
cpu_ticks() { awk '{print $14+$15}' "/proc/$pid/stat"; }
sample() { # seconds -> percent of one core over the window
  local b a
  b=$(cpu_ticks); sleep "$1"; a=$(cpu_ticks)
  awk -v a="$b" -v b="$a" -v hz="$hz" -v s="$1" 'BEGIN{printf "%.1f", (b-a)/hz/s*100}'
}

baseline=$(sample 3)

if ! limits=$(prlimit --pid "$pid" --nofile); then
  echo "prlimit read failed" >&2
  exit 1
fi
read -r soft hard < <(printf '%s\n' "$limits" | awk 'NR==2{print $(NF-2), $(NF-1)}')
open_fds=$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 | wc -l)

# Set the soft limit to the lowest free fd number: every slot below it is in
# use and every slot at or above it is forbidden, so the next accept4 has no fd
# to allocate. Counting open fds would miss a hole below the count.
no_file=0
while [ -e "/proc/$pid/fd/$no_file" ]; do no_file=$((no_file + 1)); done

# No free descriptor slot: the next accept4 fails EMFILE.
if ! prlimit --pid "$pid" --nofile="$no_file:$hard" >/dev/null; then
  echo "prlimit set failed" >&2
  exit 1
fi
# Confirm the limit actually took effect before measuring, or a green result is
# meaningless.
applied=$(awk '/Max open files/{print $4}' "/proc/$pid/limits")
if [ "$applied" != "$no_file" ]; then
  echo "prlimit did not take effect: soft=$applied want=$no_file" >&2
  exit 1
fi
# One pending connection keeps the listener readable for as long as the error
# persists; held client-side for 20 s.
python3 - "$port" <<'PY' &
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 5)
time.sleep(20)
PY
hold=$!
sleep 1
exhausted=$(sample 3)

# Free descriptors again: restore the soft limit.
if ! prlimit --pid "$pid" --nofile="$soft:$hard" >/dev/null; then
  echo "prlimit restore failed" >&2
  rc=1
fi
kill "$hold" 2>/dev/null || true
wait "$hold" 2>/dev/null || true
sleep 1
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$port/api/version" || true)
io_errors=$(grep -c 'Error in WebServer I/O thread' "$log" || true)

{
  echo "pid=$pid"
  echo "soft=$soft hard=$hard open_fds=$open_fds no_file=$no_file"
  echo "baseline_cpu_pct=$baseline"
  echo "exhausted_cpu_pct=$exhausted"
  echo "recovered_api_version=$code"
  echo "io_thread_errors=$io_errors"
} | tee "$meas"
[ "$code" = 200 ] || rc=1
stop
exit "$rc"
