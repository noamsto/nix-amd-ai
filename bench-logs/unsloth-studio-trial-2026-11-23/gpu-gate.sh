#!/usr/bin/env bash
# Run a command under the halo GPU bench signal-file protocol:
# wait for 1-minute loadavg < 4 (cap 15 min), then claim the signal file atomically
# (poll 30 s, max 20 min while a live holder has it), and remove it on exit only if it is still ours.
# GATE_ALLOW_LOAD=1 skips the load wait (with a warning) when the dispatcher accepts a loaded run.
# Exit 75 on either timeout (caller must not proceed).
set -u
SIGNAL_FILE=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/halo-gpu-bench.active
# shellcheck source=/dev/null # bench-logs/lib/gpu-signal.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/gpu-signal.sh"
label=$1
shift
[ -w "$(dirname "$SIGNAL_FILE")" ] || { echo "gate: $(dirname "$SIGNAL_FILE") is not writable" >&2; exit 1; }

if [ -n "${GATE_ALLOW_LOAD:-}" ]; then
    echo "gate: GATE_ALLOW_LOAD set, skipping the loadavg wait (loadavg $(cut -d' ' -f1 /proc/loadavg))" >&2
else
    waited=0
    while [ "$(cut -d. -f1 /proc/loadavg)" -ge 4 ]; do
        [ "$waited" -ge 900 ] && { echo "gate: loadavg stayed >= 4 for 15 min" >&2; exit 75; }
        sleep 10
        waited=$((waited + 10))
    done
fi

# Armed before the claim so a signal during it cannot leak the file; removes it only when line 1 is this pid.
# shellcheck disable=SC2329 # invoked by the EXIT trap
release() { [ "$(sed -n 1p "$SIGNAL_FILE" 2>/dev/null)" = "$$" ] && rm -f "$SIGNAL_FILE"; }
trap release EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
waited=0
until signal_claim "$label"; do
    [ "$waited" -ge 1200 ] && { echo "gate: signal file held for 20 min" >&2; exit 75; }
    sleep 30
    waited=$((waited + 30))
done
"$@"
