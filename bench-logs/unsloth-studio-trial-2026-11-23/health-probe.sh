#!/usr/bin/env bash
# Start Studio on a scratch port, complete the first-login password change, then ask
# /api/health to detect hardware. Prints chat_only and the torch/GPU lines from `doctor`.
# Credentials are never printed and never put on a command line.
# This CHANGES the admin password of the instance in UNSLOTH_STUDIO_HOME, so that variable must be
# set explicitly, to a scratch install (exit 2 otherwise).
# Usage: UNSLOTH_STUDIO_HOME=<scratch dir> health-probe.sh <unsloth-studio> [port]
set -u -o pipefail
bin=$1
port=${2:-8899}
[ -n "${UNSLOTH_STUDIO_HOME:-}" ] || { echo "health-probe: set UNSLOTH_STUDIO_HOME to a scratch install" >&2; exit 2; }
home=$UNSLOTH_STUDIO_HOME
if curl -sf "localhost:$port/api/health" >/dev/null; then
    echo "health-probe: port $port already answers" >&2
    exit 2
fi
studio=
work=$(mktemp -d)
cleanup() {
    if [ -n "$studio" ]; then
        kill "$studio" 2>/dev/null
        wait "$studio" 2>/dev/null
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT

"$bin" doctor 2>&1 | grep -E '^(torch|ROCm|  cuda:)|Verdict'

"$bin" studio -H 127.0.0.1 -p "$port" >"$work/studio.log" 2>&1 &
studio=$!
up=
for _ in $(seq 1 60); do
    curl -sf "localhost:$port/api/health" >/dev/null && { up=1; break; }
    sleep 3
done
[ -n "$up" ] || { echo "health-probe: Studio did not come up" >&2; exit 1; }

boot=$(cat "$home/auth/.bootstrap_password") || { echo "health-probe: bootstrap file unreadable" >&2; exit 1; }
new=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')

# Bodies go to curl on stdin and the bearer header via a 0600 file, never argv.
hdr=$work/hdr
(
    umask 077
    : >"$hdr"
)
set_token() { printf 'authorization: Bearer %s\n' "$1" >"$hdr"; }

tok=$(jq -n --arg p "$boot" '{username:"unsloth",password:$p}' |
    curl -s -X POST "localhost:$port/api/auth/login" -H 'content-type: application/json' -d @- | jq -r .access_token)
[ -n "$tok" ] && [ "$tok" != null ] || { echo "health-probe: login returned no token" >&2; exit 1; }
set_token "$tok"
tok=$(jq -n --arg c "$boot" --arg n "$new" '{current_password:$c,new_password:$n}' |
    curl -s -X POST "localhost:$port/api/auth/change-password" -H @"$hdr" -H 'content-type: application/json' -d @- | jq -r .access_token)
[ -n "$tok" ] && [ "$tok" != null ] || { echo "health-probe: password change returned no token" >&2; exit 1; }
set_token "$tok"

for _ in 1 2 3 4 5 6; do
    curl -sf "localhost:$port/api/health?detect_hardware=true" -H @"$hdr" |
        jq -c '{chat_only,hardware_detecting,version}' || { echo "health-probe: health poll failed" >&2; exit 1; }
    sleep 4
done
