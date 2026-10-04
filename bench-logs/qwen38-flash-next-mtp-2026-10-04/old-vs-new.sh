#!/usr/bin/env bash
# Old-vs-new llama-bench throughput matrix for the llama.cpp pin bump.
#
# Env:
#   OLD_VULKAN_BIN OLD_ROCM_BIN NEW_VULKAN_BIN NEW_ROCM_BIN  llama-bench paths
#   M27B FLASH GPTOSS                                        GGUF paths
#   R   repeats (default 3)
set -uo pipefail

: "${OLD_VULKAN_BIN:?}"; : "${OLD_ROCM_BIN:?}"; : "${NEW_VULKAN_BIN:?}"; : "${NEW_ROCM_BIN:?}"
: "${M27B:?}"; : "${FLASH:?}"; : "${GPTOSS:?}"
R="${R:-3}"

run() { # label bin model
  echo "=== $1 ==="
  "$2" --model "$3" -ngl 99 -r "$R" -p 512 -n 128 2>&1 | grep -E '^\|.*(pp512|tg128)'
}

# old first, new second, for each model/backend; interleave when chasing noise
run old-27b-vulkan  "$OLD_VULKAN_BIN" "$M27B"
run new-27b-vulkan  "$NEW_VULKAN_BIN" "$M27B"
run old-27b-rocm    "$OLD_ROCM_BIN"   "$M27B"
run new-27b-rocm    "$NEW_ROCM_BIN"   "$M27B"
run old-flash-vulkan "$OLD_VULKAN_BIN" "$FLASH"
run new-flash-vulkan "$NEW_VULKAN_BIN" "$FLASH"
run old-flash-rocm   "$OLD_ROCM_BIN"   "$FLASH"
run new-flash-rocm   "$NEW_ROCM_BIN"   "$FLASH"
run old-gptoss-vulkan "$OLD_VULKAN_BIN" "$GPTOSS"
run new-gptoss-vulkan "$NEW_VULKAN_BIN" "$GPTOSS"
