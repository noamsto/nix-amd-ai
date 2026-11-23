#!/usr/bin/env bash
# Run a command under the halo GPU bench signal-file protocol:
# wait for a live holder (poll 30 s, max 20 min) and for 1-minute loadavg < 4 (cap 15 min),
# (GATE_ALLOW_LOAD=1 skips the load wait when the dispatcher accepts a loaded run), claim the signal file atomically, remove it on exit. Exit 2 on either timeout (caller must not proceed).
set -u
SIGNAL_FILE=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/halo-gpu-bench.active
label=$1
shift
waited=0
while [ -z "${GATE_ALLOW_LOAD:-}" ] && [ "$(cut -d. -f1 /proc/loadavg)" -ge 4 ]; do
    [ "$waited" -ge 900 ] && { echo "gate: loadavg stayed >= 4 for 15 min" >&2; exit 2; }
    sleep 10
    waited=$((waited + 10))
done
waited=0
while :; do
    if (set -o noclobber; printf '%s\n%s\n' "$$" "$label" >"$SIGNAL_FILE") 2>/dev/null; then break; fi
    holder=$(sed -n 1p "$SIGNAL_FILE" 2>/dev/null)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
        rm -f "$SIGNAL_FILE"
        continue
    fi
    [ "$waited" -ge 1200 ] && { echo "gate: signal file held for 20 min" >&2; exit 2; }
    sleep 30
    waited=$((waited + 30))
done
trap 'rm -f "$SIGNAL_FILE"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
"$@"
