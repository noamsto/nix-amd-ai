#!/usr/bin/env bash
# MTP off/on A/B for Qwen3.8-Flash-Next on stock llama.cpp, via benchmark-go.
#
# Env:
#   TARGET              lemonade model id, e.g. Qwen3.8-Flash-Next-GGUF
#   MTP_HEAD            path to the self-contained MTP draft GGUF
#   NMAX                --spec-draft-n-max (default 3)
#   BACKENDS            --mtp-ab-backends (default rocm,vulkan)
#   HF_HOME             HF cache root holding exactly one models--<owner>--<TARGET>
#                       (if not default); keep MTP_HEAD outside it
#   LEMONADE_LLAMACPP_VULKAN_BIN / LEMONADE_LLAMACPP_ROCM_BIN  llama-server paths
set -euo pipefail

: "${TARGET:?set TARGET to a lemonade model id}"
: "${MTP_HEAD:?set MTP_HEAD to the MTP draft GGUF path}"
NMAX="${NMAX:-3}"
BACKENDS="${BACKENDS:-rocm,vulkan}"

# ResolveLemonadeGGUF takes the first models--<any-owner>--$TARGET in sort order,
# so a second owner's copy (e.g. ggml-org's MTP head repo) would silently win.
# Keep MTP_HEAD outside the scanned cache.
hub="${HF_HOME:-$HOME/.cache/huggingface}/hub"
n=$(find "$hub" -maxdepth 1 -type d -name "models--*--$TARGET" 2>/dev/null | wc -l)
if [ "$n" -ne 1 ]; then
  echo "expected exactly one models--*--$TARGET under $hub, found $n" >&2
  exit 1
fi

# grammar: one row per backend
exec nix run .#benchmark -- \
  --mtp-ab "$TARGET" \
  --mtp-draft "$MTP_HEAD" \
  --mtp-draft-n-max "$NMAX" \
  --mtp-ab-backends "$BACKENDS" \
  --no-tui
