#!/usr/bin/env bash
# Check upstream repos for new versions and output update status.
# Outputs GitHub Actions variables via GITHUB_OUTPUT.
set -euo pipefail

FLM_LATEST=$(gh api repos/FastFlowLM/FastFlowLM/releases/latest --jq '.tag_name' | sed 's/^v//')
LEM_LATEST=$(gh api repos/lemonade-sdk/lemonade/releases/latest --jq '.tag_name' | sed 's/^v//')
XDNA_LATEST=$(gh api "repos/amd/xdna-driver/commits?sha=1.7&per_page=1" --jq '.[0].sha')

FLM_CURRENT=$(grep 'version = ' pkgs/fastflowlm/default.nix | head -1 | sed 's/.*"\(.*\)".*/\1/')
LEM_CURRENT=$(sed -n 's/.*"\(.*\)".*/\1/p' pkgs/lemonade/version.nix | head -1)
XDNA_CURRENT=$(grep 'rev = ' pkgs/xrt-plugin-amdxdna/default.nix | head -1 | sed 's/.*"\(.*\)".*/\1/')

NEEDS_UPDATE=false
[ "$FLM_LATEST" != "$FLM_CURRENT" ] && NEEDS_UPDATE=true
[ "$LEM_LATEST" != "$LEM_CURRENT" ] && NEEDS_UPDATE=true
[ "$XDNA_LATEST" != "$XDNA_CURRENT" ] && NEEDS_UPDATE=true

echo "FLM: $FLM_CURRENT -> $FLM_LATEST"
echo "Lemonade: $LEM_CURRENT -> $LEM_LATEST"
echo "XDNA: $XDNA_CURRENT -> $XDNA_LATEST"

# nixpkgs lock vs nixos-unstable HEAD. We surface diffs for the six backend
# packages we consume (Lemonade pins their versions into backend_versions.json
# at build time, so movement here is user-visible).
NIXPKGS_CURRENT_REV=$(jq -r '.nodes.nixpkgs.locked.rev' flake.lock)
NIXPKGS_LATEST_REV=$(gh api repos/NixOS/nixpkgs/branches/nixos-unstable --jq '.commit.sha')
NIXPKGS_NEEDS_UPDATE=false
NIXPKGS_BACKEND_DIFFS=""
if [ "$NIXPKGS_CURRENT_REV" != "$NIXPKGS_LATEST_REV" ]; then
  NIXPKGS_NEEDS_UPDATE=true
  NEEDS_UPDATE=true
  echo "nixpkgs: ${NIXPKGS_CURRENT_REV:0:12} -> ${NIXPKGS_LATEST_REV:0:12}"
  for pkg in llama-cpp-rocm llama-cpp-vulkan whisper-cpp whisper-cpp-vulkan stable-diffusion-cpp stable-diffusion-cpp-rocm; do
    cur=$(nix eval --raw "github:NixOS/nixpkgs/${NIXPKGS_CURRENT_REV}#${pkg}.version" 2>/dev/null || echo "?")
    new=$(nix eval --raw "github:NixOS/nixpkgs/${NIXPKGS_LATEST_REV}#${pkg}.version" 2>/dev/null || echo "?")
    if [ "$cur" != "$new" ]; then
      echo "  $pkg: $cur -> $new"
      NIXPKGS_BACKEND_DIFFS+="- ${pkg}: ${cur} -> ${new}"$'\n'
    fi
  done
fi

# Cross-check llamaCppMtpOverride against Lemonade's backend_versions.json
# (llamacpp.vulkan). Our flake pin must match for MTP to light up; nixpkgs
# catching up to that pin means we can drop the override entirely.
MTP_OVERRIDE_NEEDS_UPDATE=false
MTP_CLEANUP=false
MTP_REQUIRED=""
MTP_CURRENT=""
if grep -q "llamaCppMtpOverride" flake.nix; then
  MTP_CURRENT=$(grep -A1 'LLAMA_BUILD_NUMBER' flake.nix | grep 'version =' | sed 's/.*"\([0-9]*\)".*/\1/')
  MTP_REQUIRED=$(gh api "repos/lemonade-sdk/lemonade/contents/src/cpp/resources/backend_versions.json?ref=v${LEM_LATEST}" \
    -H "Accept: application/vnd.github.v3.raw" \
    --jq '.llamacpp.vulkan' 2>/dev/null | sed 's/^b//')

  if [ -n "$MTP_REQUIRED" ] && [ -n "$MTP_CURRENT" ] && [ "$MTP_REQUIRED" != "$MTP_CURRENT" ]; then
    MTP_OVERRIDE_NEEDS_UPDATE=true
    NEEDS_UPDATE=true
    echo "MTP override: b${MTP_CURRENT} -> b${MTP_REQUIRED} (lemonade v${LEM_LATEST} pins llamacpp.vulkan)"
  fi

  llamacpp_new=$(nix eval --raw "github:NixOS/nixpkgs/${NIXPKGS_LATEST_REV}#llama-cpp-rocm.version" 2>/dev/null || echo "")
  llamacpp_num="${llamacpp_new%%-*}"
  if [ -n "$MTP_REQUIRED" ] && [[ "$llamacpp_num" =~ ^[0-9]+$ ]] && [ "$llamacpp_num" -ge "$MTP_REQUIRED" ]; then
    MTP_CLEANUP=true
  fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "flm_latest=$FLM_LATEST"
    echo "lem_latest=$LEM_LATEST"
    echo "xdna_latest=$XDNA_LATEST"
    echo "flm_current=$FLM_CURRENT"
    echo "lem_current=$LEM_CURRENT"
    echo "xdna_current=$XDNA_CURRENT"
    echo "needs_update=$NEEDS_UPDATE"
    echo "nixpkgs_needs_update=$NIXPKGS_NEEDS_UPDATE"
    echo "mtp_cleanup=$MTP_CLEANUP"
    echo "mtp_override_needs_update=$MTP_OVERRIDE_NEEDS_UPDATE"
    echo "mtp_required=$MTP_REQUIRED"
    echo "mtp_current=$MTP_CURRENT"
    # Multi-line outputs need the heredoc form (GitHub Actions docs).
    echo "nixpkgs_backend_diffs<<NIXPKGS_EOF"
    printf '%s' "$NIXPKGS_BACKEND_DIFFS"
    echo "NIXPKGS_EOF"
  } >> "$GITHUB_OUTPUT"
fi
