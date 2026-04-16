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

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  cat >> "$GITHUB_OUTPUT" <<EOF
flm_latest=$FLM_LATEST
lem_latest=$LEM_LATEST
xdna_latest=$XDNA_LATEST
flm_current=$FLM_CURRENT
lem_current=$LEM_CURRENT
xdna_current=$XDNA_CURRENT
needs_update=$NEEDS_UPDATE
EOF
fi
