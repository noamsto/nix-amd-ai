#!/usr/bin/env bash
# Export a LoRA adapter trained by lora.sh to a Q4_K_M GGUF through Studio's CLI export path,
# then serve the result with the flake's llama-server for one chat completion on loopback.
# Run under the gate:  ../unsloth-studio-trial-2026-11-23/gpu-gate.sh unsloth-export ./export.sh <unsloth-studio> <llama-server> <adapter dir under outputs/>
# Needs UNSLOTH_STUDIO_HOME set to a scratch install. Export dir lands under its exports/; exactly
# one GGUF there, newer than a marker touched before the export, is served.
set -u -o pipefail
bin=$1
server=$2
adapter=$3
port=${PORT:-8896}
dest=gguf_q4km
curl -s "localhost:$port/health" >/dev/null && { echo "export: port $port already answers" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
touch "$work/marker"
"$bin" export "$UNSLOTH_STUDIO_HOME/outputs/$adapter" "$dest" --format gguf --quantization q4_k_m --max-seq-length 512 || { echo "export: failed" >&2; exit 1; }
mapfile -t ggufs < <(find "$UNSLOTH_STUDIO_HOME/exports/$dest" -name '*.gguf' -newer "$work/marker")
[ "${#ggufs[@]}" -eq 1 ] || { echo "export: expected one new gguf, found ${#ggufs[@]}" >&2; exit 1; }
gguf=${ggufs[0]}
echo "gguf_bytes=$(stat -c %s "$gguf")"

"$server" -m "$gguf" -c 512 -ngl 0 --host 127.0.0.1 --port "$port" >"$work/server.log" 2>&1 &
srv=$!
trap 'kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null; rm -rf -- "$work"' EXIT
up=
for _ in $(seq 1 60); do
    kill -0 "$srv" 2>/dev/null || { echo "export: llama-server exited" >&2; tail -n 20 "$work/server.log" >&2; exit 1; }
    curl -sf "localhost:$port/health" >/dev/null && { up=1; break; }
    sleep 2
done
[ -n "$up" ] || { echo "export: llama-server did not come up" >&2; tail -n 20 "$work/server.log" >&2; exit 1; }
jq -n '{messages:[{role:"user",content:"Name the capital of France in one short sentence."}],max_tokens:48}' |
    curl -s "localhost:$port/v1/chat/completions" -H 'content-type: application/json' -d @- | jq -r '.choices[0].message.content // .'
