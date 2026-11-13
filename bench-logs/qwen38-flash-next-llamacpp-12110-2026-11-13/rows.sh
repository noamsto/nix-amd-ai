#!/usr/bin/env bash
# One MTP off/on A/B row (mtp-ab.sh, from the 2026-10-04 bench) behind the gated run.sh exec path.
#
# Usage (repo root): OUT_DIR=<dir> OLD_VULKAN=<store path> NEW_VULKAN=<store path> OLD_ROCM=<store path> \
#     NEW_ROCM=<store path> bench-logs/qwen38-flash-next-llamacpp-12110-2026-11-13/rows.sh <old|new> <vulkan|rocm>
#
# The *_VULKAN / *_ROCM paths are the llama-cpp-vulkan / llama-cpp-rocm outputs of each build. Never run the
# benchmark against the GPU directly: run.sh checks fit, waits for host load, hands lemond's model off and back.
set -euo pipefail

arm=${1:?old|new}
backend=${2:?vulkan|rocm}
: "${OUT_DIR:?}"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
models=${MODELS:-/var/lib/models}
unsloth=$models/hf/hub/models--unsloth--Qwen3.8-Flash-Next-GGUF/snapshots/38bb39ee97821de2c9009abb7e93950eec396e66
draft=$models/hf/hub/models--ggml-org--Qwen3.8-Flash-Next-GGUF/snapshots/052beeaca7bec4a303e59cc7bc630c4f3a1b845d/mtp-Qwen3.8-Flash-Next-Q8_0.gguf
iq4=$unsloth/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf

# mtp-ab.sh wants exactly one models--*--TARGET under HF_HOME/hub and the lexicographically first .gguf in it to be
# the target, so give it a private cache holding only the three IQ4_XS shards (the same files as 2026-10-04).
hf=$OUT_DIR/hf
snap=$hf/hub/models--unsloth--Qwen3.8-Flash-Next-GGUF/snapshots/x
mkdir -p "$snap"
for f in "$unsloth"/UD-IQ4_XS/*.gguf; do ln -sf "$f" "$snap/$(basename "$f")"; done

case $arm-$backend in
old-vulkan) bin=$OLD_VULKAN ;;
new-vulkan) bin=$NEW_VULKAN ;;
old-rocm) bin=$OLD_ROCM ;;
new-rocm) bin=$NEW_ROCM ;;
*) echo "bad row $arm-$backend" >&2; exit 7 ;;
esac
server=$bin/bin/llama-server
"$server" --version 2>&1 | grep -i version | head -1 >"$OUT_DIR/$arm-$backend.version" || true

if [ "$backend" = vulkan ]; then
    export LEMONADE_LLAMACPP_VULKAN_BIN=$server
else
    export LEMONADE_LLAMACPP_ROCM_BIN=$server
fi
# run.sh's own TARGET is the shard it sizes the fit check from; the child's TARGET is mtp-ab.sh's model id.
OUT=$OUT_DIR/$arm-$backend.row.json EXEC_DEV=gpu EXEC_LOG=$OUT_DIR/$arm-$backend.log DRAFT=$draft TARGET=$iq4 \
    "$root/bench-logs/qwen38-flash-next-engine-bakeoff-2026-10-05/run.sh" exec -- \
    env TARGET=Qwen3.8-Flash-Next-GGUF HF_HOME="$hf" MTP_HEAD="$draft" BACKENDS="$backend" \
    "$root/bench-logs/qwen38-flash-next-mtp-2026-10-04/mtp-ab.sh"
