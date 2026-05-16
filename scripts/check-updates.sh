#!/usr/bin/env bash
# Check upstream repos for new versions and output update status.
# Outputs GitHub Actions variables via GITHUB_OUTPUT.
set -euo pipefail

FLM_LATEST=$(gh api repos/FastFlowLM/FastFlowLM/releases/latest --jq '.tag_name' | sed 's/^v//')
LEM_LATEST=$(gh api repos/lemonade-sdk/lemonade/releases/latest --jq '.tag_name' | sed 's/^v//')
XDNA_LATEST=$(gh api "repos/amd/xdna-driver/commits?sha=1.7&per_page=1" --jq '.[0].sha')

FLM_CURRENT=$(grep 'version = ' pkgs/fastflowlm/default.nix | head -1 | sed 's/.*"\(.*\)".*/\1/')
LEM_CURRENT=$(grep 'version = ' pkgs/lemonade/default.nix | head -1 | sed 's/.*"\(.*\)".*/\1/')
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
MTP_CLEANUP=false
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
    # MTP override cleanup nag: drop flake.nix llamaCppMtpOverride once nixpkgs
    # llama-cpp catches up past b9175 (the MTP merge commit preview).
    if [ "$pkg" = "llama-cpp-rocm" ] && [ "$new" != "?" ]; then
      new_num="${new%%-*}"
      if [[ "$new_num" =~ ^[0-9]+$ ]] && [ "$new_num" -ge 9175 ] && grep -q "llamaCppMtpOverride" flake.nix; then
        MTP_CLEANUP=true
      fi
    fi
  done
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
    # Multi-line outputs need the heredoc form (GitHub Actions docs).
    echo "nixpkgs_backend_diffs<<NIXPKGS_EOF"
    printf '%s' "$NIXPKGS_BACKEND_DIFFS"
    echo "NIXPKGS_EOF"
  } >> "$GITHUB_OUTPUT"
fi
