#!/usr/bin/env bash
# Export a LoRA adapter trained by lora.sh to a Q4_K_M GGUF through Studio's CLI export path,
# then serve the result with the flake's llama-server for one chat completion on loopback.
# Run under the gate:  ../unsloth-studio-trial-2026-11-23/gpu-gate.sh unsloth-export ./export.sh <unsloth-studio> <llama-server> <adapter dir under outputs/>
# Needs UNSLOTH_STUDIO_HOME set to a scratch install. Export dir lands under its exports/.
set -u -o pipefail
bin=$1
server=$2
adapter=$3
port=${PORT:-8896}
dest=gguf_q4km
"$bin" export "$UNSLOTH_STUDIO_HOME/outputs/$adapter" "$dest" --format gguf --quantization q4_k_m --max-seq-length 512 || { echo "export: failed" >&2; exit 1; }
gguf=$(find "$UNSLOTH_STUDIO_HOME/exports" -name '*.gguf' | head -1)
[ -n "$gguf" ] || { echo "export: no gguf produced" >&2; exit 1; }
echo "gguf_bytes=$(stat -c %s "$gguf")"

"$server" -m "$gguf" -c 512 -ngl 0 --host 127.0.0.1 --port "$port" >/dev/null 2>&1 &
srv=$!
trap 'kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null' EXIT
for _ in $(seq 1 60); do
    curl -sf "localhost:$port/health" >/dev/null && break
    sleep 2
done
jq -n '{messages:[{role:"user",content:"Name the capital of France in one short sentence."}],max_tokens:48}' |
    curl -s "localhost:$port/v1/chat/completions" -H 'content-type: application/json' -d @- | jq -r '.choices[0].message.content // .'
