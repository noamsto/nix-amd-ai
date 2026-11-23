#!/usr/bin/env bash
# Load a local GGUF through Studio's inference API, get one chat completion, and record which
# llama-server binary Studio launched: exe symlink, cmdline, parent, and its listening socket.
# Run under the gate:  ../unsloth-studio-trial-2026-11-23/gpu-gate.sh gguf-chat ./chat.sh <unsloth-studio> <model.gguf> [port]
# Needs UNSLOTH_STUDIO_HOME set to a scratch install; the GGUF must sit under its exports/ dir.
set -u -o pipefail
bin=$1
gguf=$2
port=${3:-8897}
work=$(mktemp -d)
# shellcheck source=studio-session.sh
. "$(dirname "${BASH_SOURCE[0]}")/studio-session.sh"
trap 'session_cleanup; rm -rf -- "$work"' EXIT
studio_login || exit 1

jq -n --arg p "$gguf" '{model_path: $p, max_seq_length: 2048, is_lora: false}' | api POST /api/inference/load >"$work/load.json"
jq -c '{status,model,is_gguf,error,detail}' "$work/load.json"
jq -e '.status == "loaded"' "$work/load.json" >/dev/null || { echo "chat: model load failed" >&2; exit 1; }

# Studio's own child: find llama-server processes below the Studio pid.
echo "studio_pid=$studio_pid"
pids=
for p in $(descendants "$studio_pid"); do
    case $(readlink "/proc/$p/exe" 2>/dev/null) in *llama-server*) pids="$pids $p" ;; esac
done
for p in $pids; do
    echo "pid=$p ppid=$(ps -o ppid= -p "$p" | tr -d ' ')"
    echo "exe=$(readlink "/proc/$p/exe")"
    echo "cmdline=$(tr '\0' ' ' <"/proc/$p/cmdline")"
done
echo "--- ss"
for p in $pids; do
    ss -ltnp | grep "pid=$p," || true
done

jq -n '{messages:[{role:"user",content:"Name the capital of France in one short sentence."}],max_tokens:48,stream:false}' |
    api POST /v1/chat/completions | jq -r '.choices[0].message.content // .'
