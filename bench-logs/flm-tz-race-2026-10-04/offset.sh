#!/usr/bin/env bash
# offset.sh <flm> [port]
#
# Serve llama3.2:1b under TZ=Asia/Jerusalem and check GET /api/ps
# expires_at. The response is a fixed-offset ISO-8601 instant
# (YYYY-MM-DDThh:mm:ss.fffff+HH:MM). The probe re-derives, with GNU date
# under the same TZ, the local offset and wall clock at the instant the
# string denotes. Both must equal what the server printed. The unpatched
# server printed the UTC wall clock with +00:00 -- the same instant as local,
# but the wrong offset and representation -- so both comparisons fail there;
# a suffix naming a different instant would fail the same way.
#
# Exit 0 on match, 1 on mismatch, 2 on setup failure. The server is always
# stopped by its own PID; a pre-existing flm is waited for, never killed.
set -u

FLM=${1:?usage: offset.sh <flm> [port]}
PORT=${2:-58605}
PROBE_TZ=Asia/Jerusalem
# A nix-built flm (unlike the system wrapper) has no xrt-combined on its
# RPATH, so point it at one exactly as race.sh does.
LIB=${XRT_LIB_DIR:?set XRT_LIB_DIR to the xrt-combined lib dir}
export LD_LIBRARY_PATH="$LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
LOG=${OFFSET_LOG:-$(mktemp)}

pid=""
cleanup() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM

waited=0
while pgrep -x flm >/dev/null; do
  if [ "$waited" -ge 600 ]; then echo "ABORT: flm already running" >&2; exit 2; fi
  echo "flm already running; retrying in 30s (${waited}s so far)" >&2
  sleep 30; waited=$((waited + 30))
done

TZ="$PROBE_TZ" "$FLM" serve llama3.2:1b --port "$PORT" >"$LOG" 2>&1 &
pid=$!

ready=0
for _ in $(seq 1 300); do
  kill -0 "$pid" 2>/dev/null || { echo "server died during startup" >&2; exit 2; }
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/api/version"; then ready=1; break; fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "server not ready within 300s" >&2; exit 2; }

ps=$(curl -s --max-time 60 "http://127.0.0.1:$PORT/api/ps")
expires=$(printf '%s' "$ps" | python3 -c 'import sys,json; print(json.load(sys.stdin)["models"][0]["expires_at"])') || {
  echo "no expires_at in /api/ps reply: $ps" >&2; exit 2; }

wall=${expires%[+-]*}
suffix=${expires:${#wall}}
# date's %H:%M:%S has no fractional part; compare through the seconds.
wall_sec=${wall%%.*}
expect_suffix=$(TZ="$PROBE_TZ" date -d "$expires" +%:z)
expect_wall=$(TZ="$PROBE_TZ" date -d "$expires" +%Y-%m-%dT%H:%M:%S)

echo "expires_at=$expires"
echo "suffix=$suffix expected=$expect_suffix"
echo "wall=$wall expected=$expect_wall"

rc=0
if [ "$suffix" != "$expect_suffix" ]; then echo "MISMATCH: offset suffix"; rc=1; fi
if [ "$wall_sec" != "$expect_wall" ]; then echo "MISMATCH: wall clock"; rc=1; fi
if [ "$rc" = 0 ]; then
  echo "PASS expires_at offset matches TZ=$PROBE_TZ"
else
  echo "FAIL expires_at under TZ=$PROBE_TZ"
fi
exit "$rc"
