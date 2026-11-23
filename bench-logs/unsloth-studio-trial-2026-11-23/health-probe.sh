#!/usr/bin/env bash
# Start Studio on a scratch port, complete the first-login password change on a throwaway
# instance, then ask /api/health to detect hardware. Prints chat_only and the torch/GPU
# lines from `doctor`. Credentials are never printed.
# Usage: health-probe.sh <unsloth-studio> [port]
set -u
bin=$1
port=${2:-8899}
home=${UNSLOTH_STUDIO_HOME:-$HOME/.unsloth/studio}
work=$(mktemp -d)
trap 'kill "$studio" 2>/dev/null; wait "$studio" 2>/dev/null; rm -rf -- "$work"' EXIT

"$bin" doctor 2>&1 | grep -E '^(torch|ROCm|  cuda:)|Verdict'

"$bin" studio -H 127.0.0.1 -p "$port" >"$work/studio.log" 2>&1 &
studio=$!
for _ in $(seq 1 60); do curl -sf "localhost:$port/api/health" >/dev/null && break; sleep 3; done

boot=$(cat "$home/auth/.bootstrap_password")
new=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
tok=$(curl -s -X POST "localhost:$port/api/auth/login" -H 'content-type: application/json' \
    -d "$(jq -n --arg p "$boot" '{username:"unsloth",password:$p}')" | jq -r .access_token)
tok=$(curl -s -X POST "localhost:$port/api/auth/change-password" -H "authorization: Bearer $tok" \
    -H 'content-type: application/json' \
    -d "$(jq -n --arg c "$boot" --arg n "$new" '{current_password:$c,new_password:$n}')" | jq -r .access_token)

for _ in 1 2 3 4 5 6; do
    curl -s "localhost:$port/api/health?detect_hardware=true" -H "authorization: Bearer $tok" |
        jq -c '{chat_only,hardware_detecting,version}'
    sleep 4
done
