#!/usr/bin/env bash
# Inkling-2-Mini smoke on llama.cpp b12653: one text chat completion and one image prompt per backend, decode t/s
# from the server's own timings. Meant to run as the child of the gated harness, never against the GPU directly:
#
#   LEMOND_MODEL=<resident lemond model> EXEC_DEV=gpu TARGET=<IQ4_NL gguf> NEED_GIB=28 OUT=row.json EXEC_LOG=smoke.log \
#     bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05/run.sh exec -- \
#     env GGUF=<IQ4_NL gguf> MMPROJ=<mmproj gguf> VULKAN_BIN=<llama-cpp-vulkan> ROCM_BIN=<llama-cpp-rocm> \
#     bench-logs/inkling-2-mini-llamacpp-b12653-2026-11-23/smoke.sh
set -euo pipefail
: "${GGUF:?}" "${MMPROJ:?}" "${VULKAN_BIN:?}" "${ROCM_BIN:?}"
port=${PORT:-18080}
work=$(mktemp -d)
srv=
cleanup() { [ -z "$srv" ] || { kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null || true; }; rm -rf -- "$work"; }
trap cleanup EXIT INT TERM

# 64x64 solid red PNG, no image tooling needed.
python3 -I - "$work/red.png" <<'PY'
import struct, sys, zlib
w = h = 64
raw = b"".join(b"\x00" + b"\xff\x00\x00" * w for _ in range(h))
def chunk(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
PY
img=$(base64 -w0 "$work/red.png")

ask() { # name, json body -> prints reply text and decode t/s
    curl -fsS "http://127.0.0.1:$port/v1/chat/completions" -H 'Content-Type: application/json' -d "$2" |
        jq -r --arg n "$1" '"\($n): decode \(.timings.predicted_per_second|.*10|round/10) t/s, prompt \(.timings.prompt_per_second|.*10|round/10) t/s, \(.usage.completion_tokens) tokens\n  reply: \((.choices[0].message.content // "")|gsub("\n";" ")|.[0:300])\n  reasoning: \((.choices[0].message.reasoning_content // "")|gsub("\n";" ")|.[0:200])"'
}

for backend in ${BACKENDS:-vulkan rocm}; do
    bin=$VULKAN_BIN
    [ "$backend" = rocm ] && bin=$ROCM_BIN
    echo "=== $backend: $("$bin/bin/llama-server" --version 2>&1 | grep -i '^version')"
    "$bin/bin/llama-server" -m "$GGUF" --mmproj "$MMPROJ" -ngl 99 -c 8192 --no-webui --port "$port" --jinja >"$work/$backend.log" 2>&1 &
    srv=$!
    for _ in $(seq 1 180); do
        curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break
        kill -0 "$srv" 2>/dev/null || { echo "$backend: server exited"; tail -20 "$work/$backend.log"; break; }
        sleep 5
    done
    if curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
        ask "$backend text" '{"max_tokens":512,"temperature":0,"messages":[{"role":"user","content":"In two sentences, what is the capital of France and why is it famous?"}]}' || true
        ask "$backend image" "{\"max_tokens\":64,\"temperature\":0,\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"What colour is this image? One word.\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,$img\"}}]}]}" || true
    fi
    kill "$srv" 2>/dev/null || true
    wait "$srv" 2>/dev/null || true
    srv=
done
